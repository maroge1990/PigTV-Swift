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
    /// R11: told while this play is resolving, so no warm request runs then.
    weak var warmer: ChannelWarmer?
    /// R11: the resolve adopted a stream the app warmed earlier.
    private(set) var warmAdopted = false
    @Published private(set) var ready = false
    /// The player screen can remain visible while the server releases its stream.
    @Published private(set) var stopping = false
    @Published private(set) var error: String?
    @Published private(set) var recordingConflict: RecordingConflict?
    @Published private(set) var viewerConflict: String?
    @Published private(set) var reconnecting = false
    @Published private(set) var canRetry = false
    #if os(tvOS)
    // Display mode for the stream (frame rate, SDR/PQ/HLG), built from the
    // resolve decision's `info` (DisplayMode, build 27). Applied to the window by
    // PlayerLayerView, which clears it when the video leaves the screen, so a
    // channel change or exit to the guide drops back to SDR.
    @Published private(set) var displayCriteria: AVDisplayCriteria?
    #endif
    private var eventContext: PlaybackEvent?
    private var resolveBegan = Date()
    private var firstPlayReported = false
    private var playingSince: Date?
    private var watchedSeconds: Double = 0
    private var stalls = 0
    // A4.2 stream info: the resolve decision's route, kept for the overlay
    // after the play-start event has been sent.
    private(set) var routeStrategy: String?
    private(set) var routeVideoMode: String?
    var stallCount: Int { stalls }
    var serverIdentity: String? { client.info?.identity }
    /// The play has shown a picture (the tuning card covers the player until then).
    @Published private(set) var hasPlayed = false
    /// Mid-play, the player has been waiting for data for `bufferingAfter` seconds.
    @Published private(set) var buffering = false
    // #6: nothing on screen for `startTimeout` after the item is installed is a failed start (reported as
    // `start-timeout`); a mid-play wait of `stallTimeout` is a failure that feeds the automatic recovery. Above the
    // 30 s live hold, which can make an ordinary stall last ~30 s (#7).
    var startTimeout: TimeInterval = 20
    var bufferingAfter: TimeInterval = 1.5
    var stallTimeout: TimeInterval = 35
    /// The current item has played (hasPlayed covers the whole play, across recoveries).
    private var itemPlayed = false
    private var startTimer: Task<Void, Never>?
    private var stallTimer: Task<Void, Never>?
    // #5: after a play has shown a picture, up to `recoveryDelays.count` automatic re-resolves in any
    // `recoveryWindow`, the n-th after `recoveryDelays[n]` seconds; one more failure in the window is the error.
    // Only failures count (a stall that plays on is not one), and simultaneous signals are one failure.
    // `clock` is injectable for tests.
    var clock: () -> Date = Date.init
    var recoveryWindow: TimeInterval = 600
    var recoveryDelays: [TimeInterval] = [0, 3, 10]
    private(set) var recoveries: [Date] = []
    // C-J: the provider serving the current play (nil on an older server).
    private(set) var provider: ResolveProvider?
    // Build 27 fallbacks: what the current item is playing, and whether its
    // session was resolved with `audioEncode`.
    private var currentURL: URL?
    private var currentStrategy: String?
    private var audioEncodeRequested = false
    private var handlingFailure = false
    private var itemGeneration = UUID()
    private var playbackObservation: NSKeyValueObservation?
    private var failedNotification: NSObjectProtocol?
    private var stallNotification: NSObjectProtocol?
    private var catchUpObserver: Any?
    /// #7 (D-36): this play is still building its hold at `LiveCatchUp.slowRate`.
    private(set) var catchingUp = false
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
        let behind = edge.isFinite && current.isFinite && (edge - current) > PlayerSeekWindow.liveMargin
        if behind != behindLive { behindLive = behind }
    }
    /// A live playlist has no end (indefinite duration); a finite source's does (build 57).
    private static func isLive(_ item: AVPlayerItem) -> Bool { item.duration.isIndefinite }

    /// #7 (D-36): back to 1.0 once the play holds `PlayerSeekWindow.liveOffset` behind the live edge, or at once on a
    /// source that ends. Runs on its own timer, so it never depends on the conflict poll (which stops on an old server).
    func updateCatchUp() {
        guard catchingUp, let item = player.currentItem else { return }
        var behind = Double.nan
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            behind = CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - CMTimeGetSeconds(item.currentTime())
        }
        guard LiveCatchUp.rate(behind: behind, live: Self.isLive(item)) == 1 else { return }
        catchingUp = false
        player.defaultRate = 1
        if player.rate > 0 { player.rate = 1 }
    }

    func goToLive() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        if start.isFinite, end.isFinite {
            // Build 56: back to the held offset, not the very edge, where a provider's pause would stall at once.
            player.seek(to: CMTime(seconds: PlayerSeekWindow.liveTarget(start: start, end: end, live: Self.isLive(item)), preferredTimescale: 600))
        } else {
            player.seek(to: CMTimeRangeGetEnd(range))
        }
        catchingUp = false // the seek lands on the held offset
        player.defaultRate = 1
        player.rate = 1
        behindLive = false
    }

    // Rewind / fast-forward within the seekable buffer (a live HLS window is
    // typically a few minutes). Clamped to the buffer; seeking to the end
    // returns to the live edge.
    func skip(_ seconds: Double) {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        let current = CMTimeGetSeconds(item.currentTime())
        guard start.isFinite, end.isFinite, current.isFinite, end > start else { return }
        let target = min(max(current + seconds, start), PlayerSeekWindow.liveTarget(start: start, end: end, live: Self.isLive(item)))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        behindLive = (end - target) > PlayerSeekWindow.liveMargin
    }

    // Fraction through the seekable buffer, for the scrub indicator (nil when
    // there is no meaningful buffer to scrub).
    func bufferPosition() -> Double? {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        let current = CMTimeGetSeconds(item.currentTime())
        guard start.isFinite, end.isFinite, current.isFinite, end - start > 5 else { return nil }
        return min(1, max(0, (current - start) / (end - start)))
    }

    /// Build 31 (iOS touch scrub bar): the seekable window and position.
    func seekWindow() -> PlayerSeekWindow? {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        return PlayerSeekWindow(start: CMTimeGetSeconds(range.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(range)),
                                current: CMTimeGetSeconds(item.currentTime()), live: Self.isLive(item))
    }

    /// Seeks to a point in the seekable window (the scrub bar's release).
    func seek(toFraction fraction: Double) {
        guard let window = seekWindow() else { return }
        let target = min(window.time(at: fraction), PlayerSeekWindow.liveTarget(start: window.start, end: window.end, live: window.live))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        behindLive = !window.isLive(at: fraction)
    }

    // Distance from the live edge, for the scrub readout (R17).
    func secondsBehindLive() -> Double? {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        let current = CMTimeGetSeconds(item.currentTime())
        guard end.isFinite, current.isFinite else { return nil }
        return max(0, end - current)
    }

    // MARK: Audio and subtitle tracks (R09)

    struct MediaTrack: Identifiable, Equatable {
        let id: String
        let name: String
        let selected: Bool
    }

    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var trackOptions: [String: AVMediaSelectionOption] = [:]
    // A choice worth showing exists only when there is more than one audio
    // option or any subtitles; otherwise the button stays hidden (no dead UI).
    var hasTrackChoice: Bool { audioTracks.count > 1 || !subtitleTracks.isEmpty }
    static let subtitleOffID = "subtitles.off"

    func loadTracks() async {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        rebuildTracks(item: item)
    }

    private func rebuildTracks(item: AVPlayerItem) {
        let selection = item.currentMediaSelection
        trackOptions.removeAll()
        audioTracks = (audioGroup?.options ?? []).map { option in
            let key = "audio." + (option.displayName)
            trackOptions[key] = option
            return MediaTrack(id: key, name: option.displayName,
                              selected: selection.selectedMediaOption(in: audioGroup!) == option)
        }
        var subs: [MediaTrack] = []
        if let group = subtitleGroup, !group.options.isEmpty {
            let current = selection.selectedMediaOption(in: group)
            subs.append(MediaTrack(id: Self.subtitleOffID, name: "Off", selected: current == nil))
            for option in group.options {
                let key = "sub." + option.displayName
                trackOptions[key] = option
                subs.append(MediaTrack(id: key, name: option.displayName, selected: current == option))
            }
        }
        subtitleTracks = subs
    }

    func selectTrack(_ id: String) {
        guard let item = player.currentItem else { return }
        if id == Self.subtitleOffID {
            if let group = subtitleGroup { item.select(nil, in: group) }
        } else if let option = trackOptions[id] {
            if let group = audioGroup, group.options.contains(option) { item.select(option, in: group) }
            else if let group = subtitleGroup { item.select(option, in: group) }
        }
        rebuildTracks(item: item)
    }

    // `externalMetadata` is added to AVPlayerItem by AVKit (a category), not by
    // AVFoundation. Once the tvOS app stopped using any AVKit player (build 21
    // retired the AVPlayerViewController recording player), AVKit was no longer
    // loaded and setting it crashed with "unrecognized selector" as soon as a
    // channel started (Mark, test block 1.9). It only feeds AVKit's own UI,
    // which the custom player does not use, so set it only where it exists.
    static func setExternalMetadata(_ items: [AVMetadataItem], on item: AVPlayerItem) {
        guard item.responds(to: NSSelectorFromString("setExternalMetadata:")) else { return }
        item.setValue(items, forKey: "externalMetadata")
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
            if next != nil {
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
        Self.setExternalMetadata(metadata(), on: item)
    }

    func start(force: Bool = false) {
        guard resolveTask == nil, !ended, !ready, viewerConflict == nil, recordingConflict == nil, error == nil else { return }
        error = nil
        canRetry = false
        handlingFailure = false
        recordingConflict = nil
        viewerConflict = nil
        let generation = UUID()
        itemGeneration = generation
        warmer?.beginStart(id)
        // Never cancel resolve: even a late result may own a session to release.
        resolveTask = Task { [self] in
            defer { resolveTask = nil; warmer?.endStart(id) }
            await prerequisite?.value
            guard !ended else { return }
            do {
                // Recovery releases before resolving; stop() waits for this task.
                if let oldSession = sessionID {
                    do { try await client.release(oldSession) }
                    catch PigTVError.http(404) { /* expired session */ }
                    sessionID = nil
                }
                guard !ended else { return }
                resolveBegan = Date()
                PigTVSignpost.event("LiveResolveRequest")
                // A channel whose copied audio this device could not decode
                // ('fmt?') asks for re-encoded audio straight away.
                let audioEncode = AudioEncodeMemory.contains(channel.identityKey)
                audioEncodeRequested = audioEncode
                let decision: PlaybackDecision = try await client.request("playback/resolve", method: "POST",
                    body: ResolveBody(sourceId: channel.sourceId, channelId: channel.rawID,
                        capabilities: PlaybackCapabilities.current(), force: force,
                        audioEncode: audioEncode ? true : nil))
                PigTVSignpost.event("LiveResolveResponse")
                warmAdopted = decision.warm == true
                if warmAdopted { PigTVSignpost.event("LiveWarmAdopted") }
                sessionID = decision.sessionId
                provider = decision.provider
                guard !ended else { return }
                let url = try client.playbackURL(decision.url)
                var context = PlaybackEvent(event: "play-start")
                context.strategy = ["direct", "transcode"].contains(decision.strategy) ? decision.strategy : "unknown"
                context.container = ["hls", "mp4", "fmp4", "mpegts"].contains(decision.container ?? "") ? decision.container : nil
                context.videoMode = ["copy", "encode"].contains(decision.videoMode ?? "") ? decision.videoMode : nil
                context.warm = warmAdopted ? true : nil
                context.path = url.path // URL query (including token/provider URL) is never sent.
                context.resolveMs = Date().timeIntervalSince(resolveBegan) * 1000
                eventContext = context
                routeStrategy = context.strategy
                routeVideoMode = context.videoMode
                firstPlayReported = false
                watchedSeconds = 0
                stalls = 0
                try await Task.detached(priority: .userInitiated) {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }.value
                guard !ended else { return }
                installItem(url: url, strategy: decision.strategy,
                            mode: DisplayMode.make(videoMode: decision.videoMode, info: decision.info),
                            generation: generation)
            } catch {
                guard !ended else { return }
                let recovering = reconnecting
                reconnecting = false
                var retryAfter: TimeInterval?
                if case PigTVError.recordingConflict(let conflict) = error {
                    recordingConflict = conflict
                } else if case PigTVError.viewerConflict(let message) = error {
                    viewerConflict = message
                } else if hasPlayed, recovering, let wait = Self.retryWait(after: error), let delay = takeRecoverySlot() {
                    // #5: a reconnect's resolve failed for a passing reason (the provider may still be coming back):
                    // try again within the same window; a permanent error is shown at once (#139).
                    reconnecting = true
                    retryAfter = max(delay, wait)
                } else {
                    self.error = hasPlayed ? "The stream ended. \(error.localizedDescription)" : error.localizedDescription
                    canRetry = true
                }
                // Keep the session ID if cleanup fails so Retry/stop can retry release.
                if let sessionID {
                    do { try await client.release(sessionID); self.sessionID = nil }
                    catch PigTVError.http(404) { self.sessionID = nil }
                    catch { coordinationWarning = "The server did not confirm releasing the previous stream." }
                }
                // #140: after the cleanup, so a session it could not release is still checked for a takeover.
                if let retryAfter { scheduleRecovery(after: retryAfter, session: sessionID) }
            }
        }
    }

    /// #139: how long to wait before retrying a reconnect whose resolve failed with `error`, or nil when retrying
    /// cannot help (sign-in, permission, a missing channel, a conflict, a bad answer, the audio session).
    /// #153: C-B's fixed sentences for a channel that is gone (missing at the provider or from the playlist, or with no
    /// stream address), as opposed to one that is "not available right now" or whose provider did not respond.
    nonisolated static func isLastingResolveFailure(_ text: String) -> Bool {
        text.hasPrefix("This channel is not available") && !text.contains("right now")
    }

    nonisolated static func retryWait(after error: Error) -> TimeInterval? {
        if let error = error as? PigTVError {
            switch error {
            case .http(let status): return status >= 500 || status == 408 ? 0 : nil
            // #147: a shown server sentence is as retryable as its status, except C-B's lasting ones (#153: a provider
            // 404 arrives wrapped in HTTP 500).
            case .serverMessage(let text, let status):
                return !isLastingResolveFailure(text) && (status >= 500 || status == 408) ? 0 : nil
            case .rateLimited(let seconds): return seconds <= 30 ? TimeInterval(seconds) : nil
            default: return nil
            }
        }
        if let error = error as? URLError {
            return [.badURL, .unsupportedURL, .cancelled, .userAuthenticationRequired].contains(error.code) ? nil : 0
        }
        return nil
    }

    // Installs the item and starts playing at once. The display mode never
    // delays this (build 27): it comes from the resolve decision, or, when
    // the server sent no usable frame rate, from the asset whenever that
    // load finishes (a stale result is discarded).
    private func installItem(url: URL, strategy: String, mode: DisplayMode?, assetCriteria: Bool = true, generation: UUID) {
        let item = AVPlayerItem(url: url)
        // #7 (D-36, build 72): no fixed hold from the start (build 56 set 30 s, which froze the picture through a new
        // play's first delivery pause); the play builds it at LiveCatchUp.slowRate with the pitch kept (updateCatchUp).
        item.audioTimePitchAlgorithm = .timeDomain
        PigTVSignpost.event("LiveItemCreated")
        currentURL = url
        currentStrategy = strategy
        #if os(tvOS)
        displayCriteria = mode?.criteria()
        if mode == nil, assetCriteria {
            Task { [weak self] in
                let criteria = try? await item.asset.load(.preferredDisplayCriteria)
                guard let self, let criteria, !self.ended, self.itemGeneration == generation else { return }
                self.displayCriteria = criteria
            }
        }
        #endif
        Self.setExternalMetadata(metadata(), on: item)
        metadataProgrammeStart = programme()?.startTime
        // Swift 6: every AVFoundation/KVO/notification callback below is
        // explicitly @Sendable (nonisolated), reads only what it was handed,
        // and hops to the main actor with a Task. A closure left to inherit
        // this method's main-actor isolation would trap if AVFoundation ever
        // delivered the change on another queue (dynamic isolation check).
        observation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            if item.status == .readyToPlay { PigTVSignpost.event("LiveReadyToPlay") }
            guard item.status == .failed else { return }
            let failure = item.error as NSError?
            let diagnostic = Self.failureCodes(failure)
            let chain = Self.errorChain(failure)
            let code = failure?.code
            let domain = failure?.domain
            let safeDomain = ["AVFoundationErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain"].contains(domain ?? "") ? domain : "PlayerError"
            let mediaCodes = item.errorLog()?.events.suffix(3).map { String($0.errorStatusCode) }.joined(separator: ", ")
            let route = ["direct", "transcode"].contains(strategy) ? strategy : "unknown"
            let detail = "Route: \(route). \(diagnostic)" + (mediaCodes.map { " Media codes: \($0)." } ?? "")
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation else { return }
                self.playbackFailed(detail: detail, codeName: safeDomain, code: code, errorCodes: chain)
            }
        }
        failedNotification = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] notification in
            let chain = Self.errorChain(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation else { return }
                self.playbackFailed(detail: "The player could not finish loading the stream.", errorCodes: chain)
            }
        }
        stallNotification = NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, !self.ended else { return }
                self.stalls += 1
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            if status == .playing { PigTVSignpost.event("LivePlaying") }
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, !self.ended else { return }
                self.timeControlChanged(status)
            }
        }
        itemPlayed = false
        armStartTimer(generation: generation)
        catchingUp = true
        player.defaultRate = LiveCatchUp.slowRate
        catchUpObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 1), queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, !self.ended else { return }
                self.updateCatchUp()
            }
        }
        player.replaceCurrentItem(with: item)
        ready = true
        player.play()
        startConflictPolling()
    }

    #if DEBUG
    /// Player fixture only (build 29): plays a local file without a resolve,
    /// so the player's chrome can be checked in the simulator.
    func applyReviewState(_ state: String) {
        if state == "player-viewer-conflict" {
            viewerConflict = "Another household device is using this stream."
        } else if state == "player-recording-conflict" {
            recordingConflict = RecordingConflict(type: "recording", scheduleId: 90, title: "Coastal stories", channelName: "Documentary", endsAt: Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000)
        } else if state == "player-recording-prompt" {
            recordingPrompt = RecordingPrompt(scheduleId: 90, title: "Coastal stories", channelName: "Documentary", startsAt: Date().timeIntervalSince1970 * 1000, programEnd: Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000)
        } else if state == "player-error" {
            error = "The local review stream is unavailable. Try again or return to channels."
            canRetry = true
        } else if state == "player-starting" {
            // #132: an installed player that has not shown a picture yet (the tuning card covers it).
            ready = true
        } else if state == "player-buffering" {
            ready = true
            hasPlayed = true
            buffering = true
        } else if state == "player-reconnecting" {
            reconnecting = true
            player.pause()
        }
    }

    func playFixtureMedia(_ url: URL) {
        installItem(url: url, strategy: "direct", mode: nil, assetCriteria: false, generation: itemGeneration)
    }
    #endif

    /// The player's `timeControlStatus` for the current item: playing ends both timers; a wait after the item has
    /// played shows "Buffering…" after `bufferingAfter` and fails the play after `stallTimeout`; a pause is the
    /// viewer's and times nothing.
    func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard !ended else { return }
        updateWatchTime(playing: status == .playing)
        switch status {
        case .playing:
            cancelWaitTimers()
            playbackStarted()
        case .waitingToPlayAtSpecifiedRate:
            if !itemPlayed {
                // #131: playing again after a pause before the first picture re-arms the start deadline.
                if startTimer == nil { armStartTimer(generation: itemGeneration) }
                return
            }
            guard stallTimer == nil else { return }
            let generation = itemGeneration
            let (hint, limit) = (bufferingAfter, stallTimeout)
            stallTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hint))
                guard !Task.isCancelled, let self, self.itemGeneration == generation else { return }
                self.buffering = true
                try? await Task.sleep(for: .seconds(max(0, limit - hint)))
                guard !Task.isCancelled, self.itemGeneration == generation else { return }
                self.stallTimer = nil
                self.buffering = false
                self.playbackFailed(detail: "The stream stopped for \(Int(limit)) seconds.", codeName: "StallTimeout")
            }
        default:
            // A pause is the viewer's: it times nothing, before the first picture (#131) or after it.
            if !itemPlayed {
                startTimer?.cancel()
                startTimer = nil
            }
            stallTimer?.cancel()
            stallTimer = nil
            buffering = false
        }
    }

    private func armStartTimer(generation: UUID) {
        let startTimeout = startTimeout
        startTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(startTimeout))
            guard !Task.isCancelled, let self, self.itemGeneration == generation else { return }
            self.startTimedOut()
        }
    }

    private func cancelWaitTimers() {
        startTimer?.cancel()
        startTimer = nil
        stallTimer?.cancel()
        stallTimer = nil
        buffering = false
    }

    /// Nothing played within `startTimeout` and the player reported no error: tell the server (channel health), then
    /// fail the start like any other (Retry, or a recovery when this item was itself a reconnect).
    private func startTimedOut() {
        startTimer = nil
        guard !ended, !handlingFailure, !itemPlayed else { return }
        if let context = eventContext {
            var event = PlaybackEvent(event: "start-timeout")
            event.strategy = context.strategy
            event.path = context.path
            event.waitedSec = startTimeout
            report(event)
        }
        playbackFailed(detail: "Nothing played after \(Int(startTimeout)) seconds.", codeName: "StartTimeout", reportsError: false)
    }

    func playbackStarted() {
        guard !ended, !handlingFailure else { return }
        itemPlayed = true
        hasPlayed = true
        reconnecting = false
        if !firstPlayReported, var event = eventContext {
            firstPlayReported = true
            event.totalMs = Date().timeIntervalSince(resolveBegan) * 1000
            report(event)
        }
    }

    func playbackFailed(detail: String, codeName: String? = nil, code: Int? = nil, errorCodes: [PlayerErrorCode] = [],
                        reportsError: Bool = true) {
        guard !ended, !handlingFailure else { return }
        handlingFailure = true
        if reportsError, let context = eventContext {
            var event = PlaybackEvent(event: "media-error")
            event.strategy = context.strategy
            event.path = context.path
            event.codeName = codeName ?? "PlayerError"
            event.code = code
            event.message = String(detail.prefix(200))
            event.currentTime = finite(player.currentTime().seconds)
            if let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
                event.bufferedEnd = finite(CMTimeRangeGetEnd(range).seconds)
            }
            report(event)
        }
        let failedSession = sessionID
        let failedURL = currentURL
        let failedStrategy = currentStrategy
        let failedContext = eventContext
        clearItem()
        // Build 27: two device errors have a known cure, tried once instead of
        // (and counting as) a recovery. Never forced, never repeated.
        if let fallback = PlaybackFallback.for(errorCodes), canRecover {
            switch fallback {
            case .streamPlaylist:
                // -11868: the TV cannot show the master playlist's (HDR)
                // variant. Play the same session's media playlist instead,
                // with no display criteria.
                if let failedURL, let failedStrategy, let url = Self.streamPlaylistURL(for: failedURL) {
                    _ = takeRecoverySlot()
                    handlingFailure = false
                    reconnecting = hasPlayed
                    var context = failedContext ?? PlaybackEvent(event: "play-start")
                    context.path = url.path
                    eventContext = context
                    firstPlayReported = false
                    watchedSeconds = 0
                    stalls = 0
                    let generation = UUID()
                    itemGeneration = generation
                    installItem(url: url, strategy: failedStrategy, mode: nil, assetCriteria: false, generation: generation)
                    return
                }
            case .audioEncode:
                // 'fmt?': the copied audio cannot be decoded here. Resolve
                // again with re-encoded audio, and remember the channel.
                if !audioEncodeRequested {
                    _ = takeRecoverySlot()
                    AudioEncodeMemory.remember(channel.identityKey)
                    reconnecting = hasPlayed
                    scheduleRecovery(after: 0, session: failedSession)
                    return
                }
            }
        }
        if hasPlayed, let delay = takeRecoverySlot() {
            reconnecting = true
            scheduleRecovery(after: delay, session: failedSession)
        } else {
            reconnecting = false
            error = hasPlayed ? "The stream ended. Try again to reconnect." : "Playback could not start. \(detail)"
            canRetry = true
        }
    }

    private var canRecover: Bool {
        let now = clock()
        return recoveries.filter { now.timeIntervalSince($0) < recoveryWindow }.count < recoveryDelays.count
    }

    /// Uses one of the window's recoveries and says how long to wait before it; nil when none is left.
    private func takeRecoverySlot() -> TimeInterval? {
        let now = clock()
        recoveries.removeAll { now.timeIntervalSince($0) >= recoveryWindow }
        guard recoveries.count < recoveryDelays.count else { return nil }
        let delay = recoveryDelays[recoveries.count]
        recoveries.append(now)
        return delay
    }

    /// A callback can arrive while start() is finishing: wait for it (and the spacing), then check dismissal
    /// before issuing exactly one new resolve.
    private func scheduleRecovery(after delay: TimeInterval, session: String?) {
        let pending = resolveTask
        Task { [weak self] in
            await pending?.value
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await self?.recoverAfterFailure(session: session)
        }
    }

    // Kept separate from the AVPlayer callback so takeover/fallback/dismissal
    // can be verified with synthetic sessions and no media connection.
    func recoverAfterFailure(session: String?) async {
        guard !ended else { return }
        let takenOver = if let session { await client.sessionWasTakenOver(session) } else { false }
        guard !ended else { return }
        if takenOver {
            sessionID = nil
            reconnecting = false
            error = "Playback moved to another device."
            canRetry = false
        } else { start() }
    }

    func retry() {
        guard canRetry, resolveTask == nil, !ended else { return }
        recoveries = []
        hasPlayed = false
        error = nil
        clearItem()
        start()
    }

    /// The same session's media playlist: `…/master.m3u8?token=…` →
    /// `…/stream.m3u8?token=…`; nil for any other URL.
    nonisolated static func streamPlaylistURL(for url: URL) -> URL? {
        guard url.lastPathComponent == "master.m3u8",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = (parts.path as NSString).deletingLastPathComponent + "/stream.m3u8"
        return parts.url
    }

    private func clearItem() {
        currentURL = nil
        currentStrategy = nil
        finishMeasurement()
        itemGeneration = UUID()
        observation = nil
        playbackObservation = nil
        if let failedNotification { NotificationCenter.default.removeObserver(failedNotification) }
        failedNotification = nil
        if let stallNotification { NotificationCenter.default.removeObserver(stallNotification) }
        stallNotification = nil
        if let catchUpObserver { player.removeTimeObserver(catchUpObserver) }
        catchUpObserver = nil
        catchingUp = false
        player.defaultRate = 1
        conflictTask?.cancel()
        conflictTask = nil
        cancelWaitTimers()
        itemPlayed = false
        recordingPrompt = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        ready = false
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    private func updateWatchTime(playing: Bool) {
        let now = Date()
        if let playingSince { watchedSeconds += max(0, now.timeIntervalSince(playingSince)) }
        playingSince = playing ? now : nil
    }

    private func finishMeasurement() {
        updateWatchTime(playing: false)
        if firstPlayReported, watchedSeconds >= 10, let context = eventContext {
            var event = PlaybackEvent(event: "play-end")
            event.strategy = context.strategy
            event.container = context.container
            event.videoMode = context.videoMode
            event.watchedSec = watchedSeconds
            event.stalls = stalls
            // A4.2: from the access log, before the item is removed.
            let log = player.currentItem?.accessLog()?.events ?? []
            event.droppedFrames = StreamInfoFormat.droppedFrames(log.map(\.numberOfDroppedVideoFrames))
            event.observedBitrate = log.last.map(\.observedBitrate).flatMap(finite).flatMap { $0 > 0 ? $0 : nil }
            report(event)
        }
        eventContext = nil
        firstPlayReported = false
        watchedSeconds = 0
    }

    private func report(_ event: PlaybackEvent) {
        let client = client
        Task { await client.reportPlaybackEvent(event) }
    }

    nonisolated static func errorChain(_ error: NSError?) -> [PlayerErrorCode] {
        var current = error
        var codes: [PlayerErrorCode] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            codes.append(PlayerErrorCode(domain: value.domain, code: value.code))
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
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
        guard recordingConflict != nil, !ended, resolveTask == nil else { return }
        // Only a deliberate button press enters this path. Never automatically
        // repeat a 409 with force, even if the previous recording has ended.
        recordingConflict = nil
        start(force: true)
    }

    func confirmViewerStop() {
        guard viewerConflict != nil, !ended, resolveTask == nil else { return }
        viewerConflict = nil
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
        stopping = true
        clearItem()
        let task = Task<String?, Never> {
            await resolveTask?.value
            await Task.detached(priority: .utility) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }.value
            if let sessionID {
                do { try await client.release(sessionID) }
                catch PigTVError.http(404) { /* session already expired */ }
                catch { return "Playback stopped on this device, but the server did not confirm releasing its stream. Check PigTV before starting another stream." }
                self.sessionID = nil
            }
            return nil
        }
        stopTask = task
        return await task.value
    }
}
