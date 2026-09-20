import SwiftUI
import AVKit
import Combine

// Server contract (proposed, see HANDOVER "Recording playback"): the server
// answers GET /api/recordings/{id}/playback with an Apple-compatible media
// URL under /api/recordings/. Older servers return 404 and the UI says so.
nonisolated struct RecordingPlayback: Decodable, Sendable {
    let url: String
    let container: String?
    let durationSec: Double?
}

@MainActor
final class RecordingPlayerModel: ObservableObject {
    let recording: Recording
    let player = AVPlayer()
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var unsupported = false
    @Published private(set) var inBreak: CommercialBreak?
    @Published private(set) var breaks: [CommercialBreak] = []
    @Published var autoSkip = UserDefaults.standard.bool(forKey: "pigtv.recordings.autoSkip") {
        didSet { UserDefaults.standard.set(autoSkip, forKey: "pigtv.recordings.autoSkip") }
    }
    private let client: APIClient
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?
    private var started = false
    private var lastSkipped: Int?

    init(recording: Recording, client: APIClient) {
        self.recording = recording
        self.client = client
        player.allowsExternalPlayback = false
    }

    private var resumeKey: String { "pigtv.resume.\(recording.id)" }

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                let markers: RecordingMarkers? = try? await client.request("recordings/\(recording.id)/markers")
                breaks = (markers?.markers ?? []).filter { $0.valid && $0.type == "ad" }.sorted { $0.startMs < $1.startMs }
                let playback: RecordingPlayback
                do { playback = try await client.request("recordings/\(recording.id)/playback") }
                catch PigTVError.http(404) { unsupported = true; return }
                let url = try client.playbackURL(playback.url)
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
                let item = AVPlayerItem(url: url)
                statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in self?.error = "Playback could not start. The server's recording stream was refused by the player." }
                }
                player.replaceCurrentItem(with: item)
                let resume = UserDefaults.standard.double(forKey: resumeKey)
                if resume > 10, let duration = recording.duration_sec, resume < duration - 30 {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { [weak self] time in
                    Task { @MainActor in self?.tick(time.seconds) }
                }
                ready = true
                player.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
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

    func stop() async {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        statusObservation = nil
        if let time = player.currentItem?.currentTime().seconds, time.isFinite, time > 0 {
            UserDefaults.standard.set(time, forKey: resumeKey)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
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
            if model.unsupported {
                VStack(spacing: 20) {
                    Text("Recording playback is not available on this server yet").font(.title2.bold())
                    Text("The server needs the recording playback endpoint described in the handover. Until then, recordings play in the web app.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 700)
                    Button("Back") { dismiss() }
                }.padding(48).foregroundStyle(.white)
            } else if let error = model.error {
                VStack(spacing: 20) {
                    Text("Unable to play \(model.recording.title)").font(.title2)
                    Text(error)
                    Button("Back") { dismiss() }
                }.padding(48).foregroundStyle(.white)
            } else if model.ready {
                RecordingNativePlayer(model: model).ignoresSafeArea()
                    #if os(iOS)
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
                    ProgressView("Loading recording…")
                    Button("Cancel") { dismiss() }
                }.foregroundStyle(.white)
            }
        }
        .onAppear { model.start() }
        .onDisappear { Task { await model.stop() } }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}

struct RecordingNativePlayer: UIViewControllerRepresentable {
    @ObservedObject var model: RecordingPlayerModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        #if os(tvOS)
        // "Skip break" appears as the system's contextual action (like Skip Intro).
        if model.inBreak != nil {
            controller.contextualActions = [UIAction(title: "Skip break", image: UIImage(systemName: "forward.end.fill")) { _ in
                model.skipBreak()
            }]
        } else {
            controller.contextualActions = []
        }
        let toggle = UIAction(title: model.autoSkip ? "Auto-skip breaks: On" : "Auto-skip breaks: Off",
                              image: UIImage(systemName: model.autoSkip ? "checkmark.circle" : "circle")) { _ in
            model.autoSkip.toggle()
        }
        controller.transportBarCustomMenuItems = [toggle]
        #endif
    }
}
