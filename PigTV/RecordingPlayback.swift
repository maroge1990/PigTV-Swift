import SwiftUI
import AVKit
import Combine

// Server playback contract: authenticated MP4 under /api/recordings/.
// Capable servers prepare asynchronously; APIClient owns bounded polling.
// tvOS plays recordings in RecordingPlayerView (the custom player's parts,
// A4.3); iOS uses PigTV's own touch chrome over an AVPlayerLayer
// (RecordingTouchPlayer): AVPlayerViewController's controls put a full-screen
// button on an embedded player that blanks the screen when tapped, and cannot
// be hidden, so the one close button, Skip break, the scrubber and Picture in
// Picture are all PigTV's.
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
    /// Seconds to offer "Resume from" before anything plays (nil: no question).
    @Published private(set) var resumePrompt: Double?
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
    /// Server 0207: positions are saved to and read from the server.
    private var positionsOn: Bool { client.info?.features.recordingPositions == true }
    private var lastServerSave: Double?

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
        if state == "recording-resume" { resumePrompt = 3909; ready = true }
    }

    func playReviewMedia(_ url: URL) {
        started = true
        // As a real start does (PiP is only "supported" under the playback category).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
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
        resumePrompt = nil
        let client = client, id = recording.id, featureOn = positionsOn
        let positionTask = Task { featureOn ? await client.recordingPosition(id: id) : nil }
        startupTask = Task { [self] in
            defer { preparing = false; startupTask = nil }
            do {
                loadMarkers(generation: generation)
                PigTVSignpost.event("RecordingPlaybackRequest")
                let playback = try await client.recordingPlayback(id: recording.id, preparing: { self.preparing = true })
                try Task.checkCancellation()
                guard !stopped else { return }
                let url = try client.playbackURL(playback.url)
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
                try Task.checkCancellation()
                guard !stopped else { return }
                let item = AVPlayerItem(url: url)
                PigTVSignpost.event("RecordingItemCreated")
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
                    if item.status == .readyToPlay { PigTVSignpost.event("RecordingReadyToPlay") }
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.generation == generation else { return }
                        self.player.pause()
                        self.error = "Playback could not start. The server's recording stream was refused by the player."
                        self.canRetry = true
                    }
                }
                player.replaceCurrentItem(with: item)
                PigTVSignpost.eventWhenPlaying("RecordingPlaying", player)
                // Where to resume: the server's position (0207) or this
                // device's key; the viewer chooses before anything plays.
                let featureOn = positionsOn
                let server = featureOn ? await positionTask.value : nil
                try Task.checkCancellation()
                guard !stopped, error == nil else { return }
                let local = UserDefaults.standard.double(forKey: resumeKey)
                let known = RecordingResume.source(featureOn: featureOn, server: server, local: local)
                if let at = RecordingResume.prompt(position: known.position, watched: known.watched,
                                                   duration: recording.duration_sec, featureOn: featureOn) {
                    resumePrompt = at
                    ready = true
                    return
                }
                await beginPlayback(resumeAt: nil, generation: generation)
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                self.error = error as? PigTVError == .http(404)
                    ? "This recording is no longer available, or this server does not support recording playback."
                    : error.localizedDescription
                canRetry = true
            }
        }
    }

    /// The viewer's answer to the resume question.
    func chooseResume(_ resume: Bool) {
        guard let at = resumePrompt, !stopped else { return }
        resumePrompt = nil
        let generation = generation
        Task { await beginPlayback(resumeAt: resume ? at : nil, generation: generation) }
    }

    /// Seeks (when resuming), watches the clock and the play state, and plays.
    private func beginPlayback(resumeAt: Double?, generation: UUID) async {
        guard !stopped, self.generation == generation, player.currentItem != nil else { return }
        if let resumeAt { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
        guard !stopped, self.generation == generation, error == nil else { return }
        // Delivered on the main queue (queue: .main), so the main
        // actor can be assumed rather than hopped to.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { @Sendable [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.generation == generation else { return }
                self.tick(time.seconds)
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            guard status != .waitingToPlayAtSpecifiedRate else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.generation == generation else { return }
                if status == .playing { self.hasPlayed = true }
                else if self.hasPlayed { self.savePositionNow() } // paused
            }
        }
        ready = true
        player.play()
    }

    /// Saves the current time (local key and, with 0207, the server). Never 0.
    private func savePositionNow() {
        guard let seconds = player.currentItem?.currentTime().seconds, RecordingResume.shouldSave(seconds) else { return }
        UserDefaults.standard.set(seconds, forKey: resumeKey)
        lastServerSave = seconds
        guard positionsOn else { return }
        let client = client, id = recording.id
        Task { await client.saveRecordingPosition(id: id, seconds: seconds) }
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
        if let final = clearPlayer(), positionsOn {
            let client = client, id = recording.id
            Task { await client.saveRecordingPosition(id: id, seconds: final) }
        }
        started = false
        lastSkipped = nil
        start()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if Int(seconds) % 5 == 0 { UserDefaults.standard.set(seconds, forKey: resumeKey) }
        if positionsOn, RecordingResume.dueForPeriodicSave(now: seconds, lastSaved: lastServerSave) {
            lastServerSave = seconds
            let client = client, id = recording.id
            Task { await client.saveRecordingPosition(id: id, seconds: seconds) }
        }
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

    /// Position and seekable end.
    func timeline() -> RecordingTimeline? {
        guard let item = player.currentItem else { return nil }
        let current = CMTimeGetSeconds(item.currentTime())
        let end = item.seekableTimeRanges.last.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            ?? CMTimeGetSeconds(item.duration)
        return RecordingTimeline(current: current, end: end)
    }

    func seek(toFraction fraction: Double) {
        guard let timeline = timeline() else { return }
        player.seek(to: CMTime(seconds: timeline.end * min(1, max(0, fraction)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
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

    /// Releases the item. Returns the position it was at (never 0 or junk),
    /// which is also saved to the local key.
    @discardableResult
    private func clearPlayer() -> Double? {
        generation = UUID()
        resumePrompt = nil
        lastServerSave = nil
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
        var final: Double?
        if let time = player.currentItem?.currentTime().seconds, RecordingResume.shouldSave(time) {
            UserDefaults.standard.set(time, forKey: resumeKey)
            final = time
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        return final
    }

    func stop() async {
        stopped = true
        let pending = startupTask
        pending?.cancel()
        let final = clearPlayer()
        await pending?.value
        if positionsOn, let final { await client.saveRecordingPosition(id: recording.id, seconds: final) }
        await Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }.value
    }
}

struct RecordingPlayerScreen: View {
    @StateObject private var model: RecordingPlayerModel
    @Environment(\.dismiss) private var dismiss
    /// Runs after the player has stopped and saved its position (the caller
    /// refreshes its recordings list so tiles show the new progress).
    private let onClose: (() -> Void)?
    @FocusState private var resumeFocused: Bool

    init(recording: Recording, client: APIClient, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: RecordingPlayerModel(recording: recording, client: client))
        self.onClose = onClose
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
            } else if let position = model.resumePrompt {
                VStack(spacing: 24) {
                    Text(model.recording.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Button("Resume from \(RecordingResume.clock(position))", systemImage: "play.fill") { model.chooseResume(true) }
                        .pigPrimaryButton()
                        .focused($resumeFocused)
                    Button("Start over", systemImage: "arrow.counterclockwise") { model.chooseResume(false) }
                    Button("Cancel") { dismiss() }
                }
                .padding(48).foregroundStyle(.white)
                .tvFocusSection()
                .defaultFocus($resumeFocused, true)
                .onAppear { resumeFocused = true }
            } else if model.ready {
                #if os(tvOS)
                RecordingPlayerView(model: model) { dismiss() }
                #else
                RecordingTouchPlayer(model: model, close: { dismiss() })
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
            if model.ready, model.error == nil, !model.hasPlayed, model.resumePrompt == nil {
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
                      ["recording-loading", "recording-preparing", "recording-error", "recording-resume"].contains(screen) {
                model.showReviewStatus(screen)
            } else { model.start() }
            #else
            model.start()
            #endif
        }
        .onDisappear { Task { await model.stop(); onClose?() } }
        .forcesLandscapeOnPhone()
        #if os(tvOS)
        // While playing, the player handles Back itself (hide chrome first).
        .onExitCommand(perform: model.ready && model.error == nil && model.resumePrompt == nil ? nil : { dismiss() })
        #endif
    }
}
