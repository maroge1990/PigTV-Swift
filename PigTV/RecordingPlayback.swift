import SwiftUI
import AVKit
import Combine

// Server playback contract: authenticated MP4 under /api/recordings/.
// Capable servers prepare asynchronously; APIClient owns bounded polling.
// C-E (`recordingHls`): the answer may instead be an HLS playlist, played
// directly (a 200 needs no polling); `inProgress` = a growing EVENT playlist.
// tvOS plays recordings in RecordingPlayerView (the custom player's parts,
// A4.3); iOS keeps AVKit (RecordingNativePlayer) for touch scrubbing.
@MainActor
final class RecordingPlayerModel: ObservableObject {
    let recording: Recording
    let player = AVPlayer()
    /// The item is installed and the player view can replace the spinner.
    @Published private(set) var ready = false
    /// The player has really begun playing (`timeControlStatus == .playing`
    /// once). Stays true through pauses and stalls; `ready` only means the
    /// item was handed to the player, so the spinner waits for this.
    @Published private(set) var hasPlayed = false
    @Published private(set) var error: String?
    @Published private(set) var preparing = false
    @Published private(set) var canRetry = false
    @Published private(set) var inBreak: CommercialBreak?
    @Published private(set) var breaks: [CommercialBreak] = []
    /// C-E: an in-progress HLS recording (EVENT playlist) that still grows.
    @Published private(set) var inProgress = false
    #if os(tvOS)
    @Published private(set) var displayCriteria: AVDisplayCriteria?
    #endif
    @Published var autoSkip = UserDefaults.standard.bool(forKey: "pigtv.recordings.autoSkip") {
        didSet { UserDefaults.standard.set(autoSkip, forKey: "pigtv.recordings.autoSkip") }
    }
    private let client: APIClient
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?
    private var started = false
    private var stopped = false
    private var startupTask: Task<Void, Never>?
    private var markersTask: Task<Void, Never>?
    private var rateObservation: NSKeyValueObservation?
    /// Break markers are a nicety: past this they are simply not offered.
    var markersBudget: Duration = .seconds(3)
    private var lastSkipped: Int?
    private var generation = UUID()

    init(recording: Recording, client: APIClient) {
        self.recording = recording
        self.client = client
        player.allowsExternalPlayback = false
    }

    private var resumeKey: String { "pigtv.resume.\(recording.id)" }

    #if DEBUG
    func showReviewStatus(_ state: String) {
        started = true
        if state == "recording-error" { error = "The recording could not be loaded. Try again or return to your library."; canRetry = true }
        if state == "recording-preparing" { preparing = true }
    }

    func playReviewMedia(_ url: URL) {
        started = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        breaks = (try? JSONDecoder().decode(RecordingMarkers.self, from: Data(#"{"status":"completed","markers":[{"id":1,"startMs":10000,"endMs":20000,"type":"ad"}]}"#.utf8)))?.markers ?? []
        autoSkip = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 100), queue: .main) { @Sendable [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        ready = true
        hasPlayed = true
        player.play()
    }
    #endif

    func start() {
        guard !started, !stopped else { return }
        started = true
        error = nil
        canRetry = false
        let generation = UUID()
        self.generation = generation
        startupTask = Task { [self] in
            defer { preparing = false; startupTask = nil }
            do {
                loadMarkers(generation: generation)
                let playback = try await client.recordingPlayback(id: recording.id, preparing: { self.preparing = true })
                try Task.checkCancellation()
                guard !stopped else { return }
                let url = try client.playbackURL(playback.url)
                inProgress = playback.isGrowing
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
                try Task.checkCancellation()
                guard !stopped else { return }
                let item = AVPlayerItem(url: url)
                #if os(tvOS)
                // The custom player's bare layer does not switch the TV to
                // HDR/frame rate itself (AVPlayerViewController did). Applied
                // whenever the asset answers; playback never waits for it
                // (build 27: that wait delayed every start by up to 3 s).
                Task { [weak self] in
                    let criteria = try? await item.asset.load(.preferredDisplayCriteria)
                    guard let self, let criteria, !self.stopped, self.generation == generation else { return }
                    self.displayCriteria = criteria
                }
                #endif
                // Swift 6: KVO may arrive on any queue; the handler is
                // nonisolated (@Sendable) and hops to the main actor.
                statusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.generation == generation else { return }
                        self.player.pause()
                        self.error = "Playback could not start. The server's recording stream was refused by the player."
                        self.canRetry = true
                    }
                }
                player.replaceCurrentItem(with: item)
                // "Watch from start (still recording)" starts at the start.
                let resume = UserDefaults.standard.double(forKey: resumeKey)
                if !inProgress, resume > 10, let duration = recording.duration_sec, resume < duration - 30 {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                try Task.checkCancellation()
                guard !stopped, error == nil else { return }
                // Delivered on the main queue (queue: .main), so the main
                // actor can be assumed rather than hopped to.
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { @Sendable [weak self] time in
                    MainActor.assumeIsolated {
                        guard let self, !self.stopped, self.generation == generation else { return }
                        self.tick(time.seconds)
                    }
                }
                rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
                    guard player.timeControlStatus == .playing else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.generation == generation else { return }
                        self.hasPlayed = true
                    }
                }
                ready = true
                player.play()
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                self.error = error as? PigTVError == .http(404)
                    ? "This recording is no longer available, or this server does not support recording playback."
                    : error.localizedDescription
                canRetry = true
            }
        }
    }

    /// Markers load beside the playback request and never delay it: a hung
    /// request costs `markersBudget`, then there are simply no breaks. An
    /// answer after a cancel, back or retry (new `generation`) is dropped.
    private func loadMarkers(generation: UUID) {
        markersTask?.cancel()
        let client = client, id = recording.id, budget = markersBudget
        markersTask = Task { [weak self] in
            let markers: RecordingMarkers? = await withTaskGroup(of: RecordingMarkers?.self) { group in
                group.addTask { try? await client.request("recordings/\(id)/markers") }
                group.addTask { try? await Task.sleep(for: budget); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, !Task.isCancelled, !self.stopped, self.generation == generation, let markers else { return }
            self.breaks = markers.markers.filter { $0.valid && $0.type == "ad" }.sorted { $0.startMs < $1.startMs }
        }
    }

    func retry() {
        guard canRetry, !stopped, startupTask == nil else { return }
        clearPlayer()
        started = false
        lastSkipped = nil
        start()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if Int(seconds) % 5 == 0 { UserDefaults.standard.set(seconds, forKey: resumeKey) }
        let milliseconds = seconds * 1000
        let current = breaks.first { $0.startMs <= milliseconds && milliseconds < $0.endMs }
        if current?.id != inBreak?.id { inBreak = current }
        if autoSkip, let current, lastSkipped != current.id { skipBreak(current) }
    }

    func skipBreak(_ marker: CommercialBreak? = nil) {
        guard let marker = marker ?? inBreak else { return }
        lastSkipped = marker.id
        player.seek(to: CMTime(seconds: marker.endMs / 1000, preferredTimescale: 600))
        inBreak = nil
    }

    // MARK: Transport (tvOS recording player)

    /// Position and seekable end. A growing recording's end moves on as
    /// segments arrive; it is "live" while its duration is indefinite.
    func timeline() -> RecordingTimeline? {
        guard let item = player.currentItem else { return nil }
        let current = CMTimeGetSeconds(item.currentTime())
        let end = item.seekableTimeRanges.last.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            ?? CMTimeGetSeconds(item.duration)
        return RecordingTimeline(current: current, end: end, growing: inProgress && item.duration.isIndefinite)
    }

    func skip(_ seconds: Double) {
        guard let timeline = timeline() else { return }
        let target = RecordingTimeline.skipTarget(current: timeline.elapsed, by: seconds, end: timeline.end)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var paused: Bool { player.rate == 0 }

    func togglePause() {
        if player.rate == 0 { player.play() } else { player.pause() }
        objectWillChange.send()
    }

    private func clearPlayer() {
        generation = UUID()
        inBreak = nil
        ready = false
        hasPlayed = false
        breaks = []
        markersTask?.cancel()
        markersTask = nil
        rateObservation = nil
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        statusObservation = nil
        if let time = player.currentItem?.currentTime().seconds, time.isFinite, time > 0 {
            UserDefaults.standard.set(time, forKey: resumeKey)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func stop() async {
        stopped = true
        let pending = startupTask
        pending?.cancel()
        clearPlayer()
        await pending?.value
        await Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }.value
    }
}

struct RecordingPlayerScreen: View {
    @StateObject private var model: RecordingPlayerModel
    @Environment(\.dismiss) private var dismiss

    init(recording: Recording, client: APIClient) {
        _model = StateObject(wrappedValue: RecordingPlayerModel(recording: recording, client: client))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = model.error {
                VStack(spacing: 20) {
                    Text("Unable to play \(model.recording.title)").font(.title2)
                    Text(error)
                    if model.canRetry { Button("Retry") { model.retry() }.pigPrimaryButton() }
                    Button("Back") { dismiss() }
                }.padding(48).foregroundStyle(.white)
            } else if model.ready {
                #if os(tvOS)
                RecordingPlayerView(model: model) { dismiss() }
                #else
                RecordingNativePlayer(model: model).ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        HStack {
                            if model.inBreak != nil {
                                Button("Skip break", systemImage: "forward.end.fill") { model.skipBreak() }
                                    .buttonStyle(.borderedProminent)
                            }
                            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle) }
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }.padding()
                    }
                #endif
            } else {
                VStack(spacing: 24) {
                    ProgressView(model.preparing ? "Preparing recording…" : "Loading recording…")
                    Button("Cancel") { dismiss() }
                }.foregroundStyle(.white)
            }
        }
        .overlay {
            // The player is installed but no picture yet (`ready` alone used
            // to hide the spinner while the screen was still black).
            if model.ready, model.error == nil, !model.hasPlayed {
                ProgressView("Loading recording…").foregroundStyle(.white).allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "recording-player",
               let path = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_MEDIA"] {
                model.playReviewMedia(URL(fileURLWithPath: path))
            } else if let screen = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"],
                      ["recording-loading", "recording-preparing", "recording-error"].contains(screen) {
                model.showReviewStatus(screen)
            } else { model.start() }
            #else
            model.start()
            #endif
        }
        .onDisappear { Task { await model.stop() } }
        #if os(tvOS)
        // While playing, the player handles Back itself (hide chrome first).
        .onExitCommand(perform: model.ready && model.error == nil ? nil : { dismiss() })
        #endif
    }
}

#if os(iOS)
// iOS keeps AVKit for recordings: touch scrubbing is its strength.
struct RecordingNativePlayer: UIViewControllerRepresentable {
    @ObservedObject var model: RecordingPlayerModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
#endif
