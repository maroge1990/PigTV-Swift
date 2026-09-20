import Foundation
import AVKit
import Combine

@MainActor
final class PlaybackModel: ObservableObject, Identifiable {
    let id = UUID()
    let channel: Channel
    let programmes: [GuideProgramme]
    let player = AVPlayer()
    // Awaited before resolving: used when switching channels so the previous
    // provider stream is released first.
    var prerequisite: Task<Void, Never>?
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var recordingConflict: RecordingConflict?
    @Published var recordingPrompt: RecordingPrompt?
    @Published private(set) var coordinationWarning: String?
    private var conflictTask: Task<Void, Never>?
    private var seenPrompts = Set<Int>()
    private var pendingDeclines = Set<Int>()
    private let client: APIClient
    private var sessionID: String?
    private var ended = false
    private var resolveTask: Task<Void, Never>?
    private var stopTask: Task<String?, Never>?
    private var observation: NSKeyValueObservation?

    init(channel: Channel, client: APIClient, programmes: [GuideProgramme] = []) {
        self.channel = channel
        self.client = client
        self.programmes = programmes
        player.allowsExternalPlayback = false
    }

    func programme(at date: Date = Date()) -> GuideProgramme? {
        GuideNavigation.programme(in: programmes, at: date)
    }
    func nextProgramme(after date: Date = Date()) -> GuideProgramme? {
        programmes.filter { $0.start > date }.min { $0.start < $1.start }
    }
    func upcoming(after date: Date = Date(), limit: Int = 3) -> [GuideProgramme] {
        Array(programmes.filter { $0.start > date && $0.end > $0.start }.sorted { $0.start < $1.start }.prefix(limit))
    }

    // True once playback sits more than 20 s behind the live edge (after a
    // pause or rewind), polled from the conflict loop so the UI can offer
    // "Go to live".
    @Published private(set) var behindLive = false
    func updateLiveEdge() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else {
            behindLive = false; return
        }
        let edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        let current = CMTimeGetSeconds(item.currentTime())
        let behind = edge.isFinite && current.isFinite && (edge - current) > 20
        if behind != behindLive { behindLive = behind }
    }
    func goToLive() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: CMTimeRangeGetEnd(range))
        player.rate = 1
        behindLive = false
    }

    // Title metadata shown by the system player UI and Now Playing.
    private func metadata() -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        // Title line: what is on. Subtitle: channel, times and what follows —
        // this is the text the system shows on swipe-up.
        let now = programme()
        let next = nextProgramme()
        var items: [AVMetadataItem] = []
        if let now {
            items.append(item(.commonIdentifierTitle, now.title))
            var subtitle = "\(channel.name) • \(now.start.formatted(date: .omitted, time: .shortened)) – \(now.end.formatted(date: .omitted, time: .shortened))"
            if let next { subtitle += "  •  Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))" }
            items.append(item(.iTunesMetadataTrackSubTitle, subtitle))
            var description = now.description ?? ""
            if let next {
                let upcoming = upcoming(limit: 3).map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" }.joined(separator: "\n")
                description += (description.isEmpty ? "" : "\n\n") + "Coming up on \(channel.name):\n" + upcoming
            }
            if !description.isEmpty { items.append(item(.commonIdentifierDescription, description)) }
        } else {
            items.append(item(.commonIdentifierTitle, channel.name))
            if let next {
                items.append(item(.iTunesMetadataTrackSubTitle, "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))"))
            }
        }
        return items
    }
    private var metadataProgrammeStart: Double?
    // Re-issue the metadata when the programme changes so swipe-up stays current.
    func refreshMetadata() {
        let start = programme()?.startTime
        guard start != metadataProgrammeStart, let item = player.currentItem else { return }
        metadataProgrammeStart = start
        item.externalMetadata = metadata()
    }

    func start(force: Bool = false) {
        guard resolveTask == nil, !ended else { return }
        // Do not cancel the request when the view closes. Its eventual response
        // contains the session ID that stop() needs to release on the server.
        resolveTask = Task { [self] in
            await prerequisite?.value
            guard !ended else { return }
            do {
                let decision: PlaybackDecision = try await client.request("playback/resolve", method: "POST",
                    body: ResolveBody(sourceId: channel.sourceId, channelId: channel.rawID,
                        capabilities: PlaybackCapabilities.current(), force: force))
                sessionID = decision.sessionId
                guard !ended else { return }
                let url = try client.playbackURL(decision.url)
                // Audio session activation blocks; keep it off the main thread.
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
                let item = AVPlayerItem(url: url)
                item.externalMetadata = metadata()
                metadataProgrammeStart = programme()?.startTime
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    // Never include localized errors or media URLs: they can
                    // contain the provider credentials or the playback token.
                    let diagnostic = Self.failureCodes(item.error as NSError?)
                    let mediaCodes = item.errorLog()?.events.suffix(3).map {
                        String($0.errorStatusCode)
                    }.joined(separator: ", ")
                    let route = ["direct", "remux", "transcode"].contains(decision.strategy)
                        ? decision.strategy : "unknown"
                    let detail = "Route: \(route). \(diagnostic)" +
                        (mediaCodes.map { " Media codes: \($0)." } ?? "")
                    Task { @MainActor [weak self] in
                        if failed, self?.ended == false {
                            self?.error = "Playback could not start. \(detail)"
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                ready = true
                player.play()
                startConflictPolling()
            } catch {
                if case PigTVError.recordingConflict(let conflict) = error, !ended {
                    recordingConflict = conflict
                } else if !ended {
                    self.error = error.localizedDescription
                }
                if let sessionID { try? await client.release(sessionID); self.sessionID = nil }
            }
        }
    }

    nonisolated private static func failureCodes(_ error: NSError?) -> String {
        var current = error
        var codes: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            let domain: String
            switch value.domain {
            case "AVFoundationErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain":
                domain = value.domain
            default:
                domain = "PlayerError"
            }
            codes.append("\(domain) \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes.isEmpty ? "No player error code supplied." : codes.joined(separator: " → ")
    }

    func confirmRecordingStop() {
        guard recordingConflict != nil, !ended else { return }
        // Only a deliberate button press enters this path. Never automatically
        // repeat a 409 with force, even if the previous recording has ended.
        recordingConflict = nil
        resolveTask = nil
        start(force: true)
    }

    func keepWatching(_ prompt: RecordingPrompt) {
        pendingDeclines.insert(prompt.scheduleId)
        recordingPrompt = nil
        // The poll loop retries transient failures quietly, without asking again.
        Task { await sendPendingDeclines() }
    }

    private func sendPendingDeclines() async {
        for id in pendingDeclines {
            do {
                let _: ActionResult = try await client.request("playback/conflict/decline", method: "POST",
                    body: DeclineBody(scheduleId: id))
                pendingDeclines.remove(id)
                coordinationWarning = nil
            } catch {
                if !ended { coordinationWarning = "Could not confirm your choice with the server. Retrying…" }
            }
        }
    }

    private func startConflictPolling() {
        guard conflictTask == nil else { return }
        conflictTask = Task {
            while !Task.isCancelled && !ended {
                updateLiveEdge()
                refreshMetadata()
                await sendPendingDeclines()
                do {
                    let prompt: RecordingPrompt? = try await client.request("playback/conflict")
                    guard !ended, !Task.isCancelled else { return }
                    if pendingDeclines.isEmpty { coordinationWarning = nil }
                    if let current = recordingPrompt, current.programEnd <= Date().timeIntervalSince1970 * 1000 {
                        recordingPrompt = nil
                    }
                    if let prompt, prompt.programEnd > Date().timeIntervalSince1970 * 1000,
                       !seenPrompts.contains(prompt.id), recordingPrompt == nil {
                        seenPrompts.insert(prompt.id)
                        recordingPrompt = prompt
                    } else if prompt == nil || recordingPrompt?.id != prompt?.id {
                        recordingPrompt = nil
                    }
                } catch {
                    if Task.isCancelled || ended { return }
                    if error as? PigTVError == .http(404) { return } // older server
                    coordinationWarning = "Recording notifications are temporarily unavailable."
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    func stop() async -> String? {
        if let stopTask { return await stopTask.value }
        ended = true
        conflictTask?.cancel()
        conflictTask = nil
        recordingPrompt = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        observation = nil
        ready = false
        let task = Task<String?, Never> {
            await resolveTask?.value
            await Task.detached(priority: .utility) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }.value
            if let sessionID {
                do { try await client.release(sessionID) }
                catch { return "Playback stopped on this device, but the server did not confirm releasing its stream. Check PigTV before starting another stream." }
                self.sessionID = nil
            }
            return nil
        }
        stopTask = task
        return await task.value
    }
}
