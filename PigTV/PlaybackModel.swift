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
    private var hasPlayed = false
    private var recoveryUsed = false
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

    // Rewind / fast-forward within the seekable buffer (a live HLS window is
    // typically a few minutes). Clamped to the buffer; seeking to the end
    // returns to the live edge.
    func skip(_ seconds: Double) {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        let current = CMTimeGetSeconds(item.currentTime())
        guard start.isFinite, end.isFinite, current.isFinite, end > start else { return }
        let target = min(max(current + seconds, start), end)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        behindLive = (end - target) > 20
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
                                current: CMTimeGetSeconds(item.currentTime()))
    }

    /// Seeks to a point in the seekable window (the scrub bar's release).
    func seek(toFraction fraction: Double) {
        guard let window = seekWindow() else { return }
        let target = window.time(at: fraction)
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

    // MARK: Timeshift (C-E)

    /// The server keeps an hours-long window with program dates. Without
    /// the flag none of the date-based UI appears.
    var timeshift: Bool { client.info?.features.timeshift == true }

    /// Wall-clock dates at the ends of the seekable window (nil without
    /// timeshift or program dates).
    func seekableDates() -> ClosedRange<Date>? {
        guard timeshift, let item = player.currentItem, let date = item.currentDate(),
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        return TimeshiftMath.rangeDates(currentDate: date, currentTime: CMTimeGetSeconds(item.currentTime()),
                                        rangeStart: CMTimeGetSeconds(range.start),
                                        rangeEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(range)))
    }

    /// Wall-clock time of the picture on screen (nil without timeshift).
    func playbackDate() -> Date? {
        guard timeshift else { return nil }
        return player.currentItem?.currentDate()
    }

    /// The programme Start over would restart: the one being watched, when
    /// its start is still inside the window.
    func startOverProgramme(now: Date = Date()) -> GuideProgramme? {
        guard let window = seekableDates(), let programme = programme(at: playbackDate() ?? now),
              TimeshiftMath.canStartOver(programmeStart: programme.start, window: window) else { return nil }
        return programme
    }

    func startOver() {
        guard let item = player.currentItem, let programme = startOverProgramme() else { return }
        let generation = itemGeneration
        // AVFoundation calls completion handlers on its own queue: the
        // closure is nonisolated (@Sendable) and hops to the main actor.
        _ = item.seek(to: programme.start) { @Sendable [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, self.itemGeneration == generation, !self.ended else { return }
                self.player.rate = 1
                self.updateLiveEdge()
            }
        }
        behindLive = true
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
        // Never cancel resolve: even a late result may own a session to release.
        resolveTask = Task { [self] in
            defer { resolveTask = nil }
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
                // A channel whose copied audio this device could not decode
                // ('fmt?') asks for re-encoded audio straight away.
                let audioEncode = AudioEncodeMemory.contains(channel.identityKey)
                audioEncodeRequested = audioEncode
                let decision: PlaybackDecision = try await client.request("playback/resolve", method: "POST",
                    body: ResolveBody(sourceId: channel.sourceId, channelId: channel.rawID,
                        capabilities: PlaybackCapabilities.current(), force: force,
                        audioEncode: audioEncode ? true : nil))
                sessionID = decision.sessionId
                guard !ended else { return }
                let url = try client.playbackURL(decision.url)
                var context = PlaybackEvent(event: "play-start")
                context.strategy = ["direct", "transcode"].contains(decision.strategy) ? decision.strategy : "unknown"
                context.container = ["hls", "mp4", "fmp4", "mpegts"].contains(decision.container ?? "") ? decision.container : nil
                context.videoMode = ["copy", "encode"].contains(decision.videoMode ?? "") ? decision.videoMode : nil
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
                reconnecting = false
                if case PigTVError.recordingConflict(let conflict) = error {
                    recordingConflict = conflict
                } else if case PigTVError.viewerConflict(let message) = error {
                    viewerConflict = message
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
            }
        }
    }

    // Installs the item and starts playing at once. The display mode never
    // delays this (build 27): it comes from the resolve decision, or, when
    // the server sent no usable frame rate, from the asset whenever that
    // load finishes (a stale result is discarded).
    private func installItem(url: URL, strategy: String, mode: DisplayMode?, assetCriteria: Bool = true, generation: UUID) {
        let item = AVPlayerItem(url: url)
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
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == generation, !self.ended else { return }
                self.updateWatchTime(playing: playing)
                if playing { self.playbackStarted() }
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
    func playFixtureMedia(_ url: URL) {
        installItem(url: url, strategy: "direct", mode: nil, assetCriteria: false, generation: itemGeneration)
    }
    #endif

    func playbackStarted() {
        guard !ended, !handlingFailure else { return }
        hasPlayed = true
        reconnecting = false
        if !firstPlayReported, var event = eventContext {
            firstPlayReported = true
            event.totalMs = Date().timeIntervalSince(resolveBegan) * 1000
            report(event)
        }
    }

    func playbackFailed(detail: String, codeName: String? = nil, code: Int? = nil, errorCodes: [PlayerErrorCode] = []) {
        guard !ended, !handlingFailure else { return }
        handlingFailure = true
        if let context = eventContext {
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
        // (and counting as) the C2 recovery. Never forced, never repeated.
        if !recoveryUsed, let fallback = PlaybackFallback.for(errorCodes) {
            switch fallback {
            case .streamPlaylist:
                // -11868: the TV cannot show the master playlist's (HDR)
                // variant. Play the same session's media playlist instead,
                // with no display criteria.
                if let failedURL, let failedStrategy, let url = Self.streamPlaylistURL(for: failedURL) {
                    recoveryUsed = true
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
                    recoveryUsed = true
                    AudioEncodeMemory.remember(channel.identityKey)
                    reconnecting = hasPlayed
                    let pending = resolveTask
                    Task { [weak self] in
                        await pending?.value
                        await self?.recoverAfterFailure(session: failedSession)
                    }
                    return
                }
            }
        }
        if hasPlayed && !recoveryUsed {
            recoveryUsed = true
            reconnecting = true
            // A callback can arrive while start() is finishing. Wait for it,
            // then check dismissal before issuing exactly one new resolve.
            let pending = resolveTask
            Task { [weak self] in
                await pending?.value
                await self?.recoverAfterFailure(session: failedSession)
            }
        } else {
            reconnecting = false
            error = hasPlayed ? "The stream ended. Try again to reconnect." : "Playback could not start. \(detail)"
            canRetry = true
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
        recoveryUsed = false
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
        conflictTask?.cancel()
        conflictTask = nil
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

/// One level of a player error (the error and its underlying errors).
nonisolated struct PlayerErrorCode: Equatable, Sendable {
    let domain: String
    let code: Int
}

/// Build 27: device errors with a one-off cure (Mark's log, test block 26).
nonisolated enum PlaybackFallback: Equatable, Sendable {
    /// AVErrorNoCompatibleAlternatesForExternalDisplay (-11868): the HDR
    /// master playlist on a TV that cannot show it.
    case streamPlaylist
    /// kAudioFormatUnsupportedDataFormatError ('fmt?' = 1718449215): copied
    /// audio the device cannot decode.
    case audioEncode

    static let noCompatibleAlternates = -11868
    static let unsupportedAudioFormat = 1718449215

    static func `for`(_ codes: [PlayerErrorCode]) -> PlaybackFallback? {
        if codes.contains(where: { $0.domain == AVFoundationErrorDomain && $0.code == noCompatibleAlternates }) {
            return .streamPlaylist
        }
        if codes.contains(where: { $0.code == unsupportedAudioFormat }) { return .audioEncode }
        return nil
    }
}

/// Channels (by `identityKey`) that play only with re-encoded audio on this
/// device, so later plays request `audioEncode` from the first resolve.
nonisolated enum AudioEncodeMemory {
    static let key = "pigtv.audioEncode.channels"

    static func contains(_ channel: String, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(channel)
    }

    static func remember(_ channel: String, in defaults: UserDefaults = .standard) {
        var channels = defaults.stringArray(forKey: key) ?? []
        guard !channels.contains(channel) else { return }
        channels.append(channel)
        defaults.set(Array(channels.suffix(200)), forKey: key)
    }
}
