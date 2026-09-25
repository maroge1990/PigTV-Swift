import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var serverText = UserDefaults.standard.string(forKey: "pigtv.server") ?? ""
    @Published var username = ""
    @Published var password = ""
    @Published var error: String?
    @Published private(set) var authBusy = false
    @Published private(set) var canRestore = false
    // Saved sign-in exists but the server could not be reached.
    @Published private(set) var unreachable: String?
    @Published private(set) var pairing: PairStart?
    @Published private(set) var user: User?
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var categories: [Category] = []
    @Published var playback: PlaybackModel?
    @Published var playerPresented = false
    /// Build 31: a tab LibraryView should switch to ("guide" from the iOS
    /// player's TV Guide button, "home" from the Siri "Open PigTV" shortcut);
    /// LibraryView applies it and clears it.
    @Published var requestedTab: String?
    // The tvOS player presents these over native AVKit controls. Keeping the
    // state here lets transport-bar actions open them without resolving media.
    @Published private(set) var browse: BrowseModel?
    @Published private(set) var playbackBusy = false
    // Channels the guide was showing when playback started: the order used
    // for channel up/down inside the player. Falls back to the whole guide.
    @Published var zapList: [Channel] = []
    // Set by the player's transport-bar menu; the player screen presents the
    // channel list sheet and clears it.
    // A1.2: the channel switchPlayback(to:) most recently switched away from,
    // for "Last channel". Cleared implicitly by never being set to the current
    // channel; not touched by beginPlayback, so leaving and reopening the
    // player on the same channel keeps the previous memory.
    @Published private(set) var previousChannel: Channel?
    // Home (build 28): the last channel played on this device, kept across
    // launches for the "Continue watching" hero.
    @Published private(set) var lastWatched: LastWatched? = LastWatched.load()
    // C-I: "Watch <channel> when it starts" on an upcoming sport event.
    @Published private(set) var pendingWatch: PendingWatch?
    private var pendingWatchTask: Task<Void, Never>?

    private var authRetry: (server: String, until: Date)?
    private var client: APIClient?
    private let keychain = KeychainStore()
    private var pairingTask: Task<Void, Never>?
    private var authGeneration = UUID()
    private var currentPlayback: PlaybackModel?
    var loggedIn: Bool { user != nil }

    func restore() async {
        // A link that is not played by this restore is dropped.
        defer { pendingLink = nil }
        guard !authBusy, !serverText.isEmpty, !loggedIn else { return }
        authBusy = true
        defer { authBusy = false }
        do {
            let address = try ServerAddress(serverText)
            guard let token = try keychain.token(for: address) else { return }
            canRestore = true
            let candidate = APIClient(address: address, token: token)
            let info: ServerInfo = try await candidate.request("info")
            try info.validate()
            let user: User = try await candidate.request("auth/me")
            let authenticated = APIClient(address: address, token: token, info: info)
            self.client = authenticated
            self.serverInfo = info
            self.browse = BrowseModel(client: authenticated)
            self.user = user
            canRestore = false
            unreachable = nil
            await loadCategories()
            openPendingLink()
        } catch {
            if error as? PigTVError == .unauthorised {
                if let address = try? ServerAddress(serverText) { try? keychain.remove(for: address) }
                canRestore = false
                self.error = error.localizedDescription
            } else if let urlError = error as? URLError {
                // Server asleep, wrong network or Tailscale down: show a
                // dedicated screen rather than a generic alert.
                unreachable = Self.describe(urlError)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "PigTV did not answer in time. It may be asleep or busy."
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return "This device cannot reach the server. Check that you are on the home network or that Tailscale is connected."
        default: return error.localizedDescription
        }
    }

    func login() async {
        guard allowAuthAttempt(), !authBusy else { return }
        cancelPairing()
        authBusy = true
        defer { authBusy = false }
        do {
            let address = try ServerAddress(serverText)
            let candidate = APIClient(address: address)
            let info: ServerInfo = try await candidate.request("info")
            try info.validate()
            let response: LoginResponse = try await candidate.request("auth/login", method: "POST",
                body: LoginBody(username: username, password: password))
            try await accept(token: response.token, address: address, info: info, user: response.user)
        } catch { recordAuthFailure(error) }
    }

    private func allowAuthAttempt() -> Bool {
        guard let authRetry, authRetry.server == serverText, authRetry.until > Date() else { return true }
        error = PigTVError.rateLimited(retryAfterSec: Int(ceil(authRetry.until.timeIntervalSinceNow))).localizedDescription
        return false
    }

    private func recordAuthFailure(_ failure: Error) {
        if case PigTVError.rateLimited(let seconds) = failure {
            authRetry = (serverText, Date().addingTimeInterval(Double(seconds)))
        }
        error = failure.localizedDescription
    }

    private func accept(token: String, address: ServerAddress, info: ServerInfo, user: User? = nil) async throws {
        let candidate = APIClient(address: address, token: token, info: info)
        let resolvedUser: User
        if let user { resolvedUser = user }
        else { resolvedUser = try await candidate.request("auth/me") }
        try keychain.save(token: token, for: address)
        UserDefaults.standard.set(address.url.absoluteString, forKey: "pigtv.server")
        serverText = address.url.absoluteString
        self.client = candidate
        self.serverInfo = info
        self.browse = BrowseModel(client: candidate)
        self.user = resolvedUser
        password = ""
        pairing = nil
        canRestore = false
        error = nil
        await loadCategories()
    }

    func startPairing() {
        guard allowAuthAttempt(), !authBusy else { return }
        cancelPairing()
        let generation = authGeneration
        authBusy = true
        pairingTask = Task {
            defer { if generation == authGeneration { authBusy = false; pairing = nil } }
            do {
                let address = try ServerAddress(serverText)
                let candidate = APIClient(address: address)
                let info: ServerInfo = try await candidate.request("info")
                try info.validate()
                guard info.features.devicePairing == true else {
                    throw PigTVError.message("This server does not support device pairing. Use your username and password.")
                }
                #if os(tvOS)
                let platform = "tvOS"
                #else
                let platform = "iOS"
                #endif
                let pair: PairStart = try await candidate.request("devices/pair/start", method: "POST",
                    body: PairBody(name: "PigTV \(platform)", platform: platform))
                try Task.checkCancellation()
                guard generation == authGeneration else { return }
                pairing = pair
                while Date() < pair.expiry {
                    try await Task.sleep(for: .seconds(2))
                    let poll: PairPoll = try await candidate.request("devices/pair/poll",
                        query: [URLQueryItem(name: "code", value: pair.code)])
                    try Task.checkCancellation()
                    guard generation == authGeneration else { return }
                    switch poll.status {
                    case "pending": continue
                    case "approved":
                        guard let token = poll.token, !token.isEmpty else { throw PigTVError.decoding }
                        try await accept(token: token, address: address, info: info)
                        return
                    case "expired", "claimed":
                        throw PigTVError.message("This pairing code is no longer available. Request another code.")
                    default: throw PigTVError.decoding
                    }
                }
                throw PigTVError.message("The pairing code expired. Request another code.")
            } catch {
                if generation == authGeneration, !Task.isCancelled { recordAuthFailure(error) }
            }
        }
    }

    func cancelPairing() {
        authGeneration = UUID()
        pairingTask?.cancel()
        pairingTask = nil
        pairing = nil
        authBusy = false
    }

    func logout() async {
        if let currentPlayback { await endPlayback(currentPlayback) }
        guard !playbackBusy else { return }
        do {
            if let client { try keychain.remove(for: client.address) }
            clearSession()
        } catch { self.error = error.localizedDescription }
    }

    private func clearSession() {
        cancelPairing()
        cancelPendingWatch()
        pendingLink = nil
        TopShelfExport.clear()
        LastWatched.clear()
        lastWatched = nil
        client = nil
        serverInfo = nil
        browse = nil
        user = nil
        password = ""
        categories = []
        canRestore = false
    }

    private func loadCategories() async {
        guard let client else { return }
        do { categories = try await client.request("library/categories") }
        catch { self.error = error.localizedDescription }
    }

    // MARK: Deep links (A4.1 Top Shelf, A4.5 Siri)

    /// A play link that arrived before sign-in was restored (a cold launch
    /// from the Top Shelf can deliver the URL before the launch restore
    /// starts). Only a successful restore plays it, within a minute; any
    /// other outcome drops it (restore's defer), so a later manual sign-in
    /// never starts playback unexpectedly.
    private var pendingLink: (link: PigTVLink.Play, at: Date)?

    /// `pigtv://play?…`: plays that channel when signed in; ignored otherwise.
    func open(_ url: URL) {
        // Build 31: pigtv://home (the Siri "Open PigTV" shortcut) shows Home.
        if PigTVLink.isHome(url) { requestedTab = "home"; return }
        guard let link = PigTVLink.parse(url) else { return }
        if loggedIn { play(link) } else { pendingLink = (link, Date()) }
    }

    private func openPendingLink() {
        guard let pending = pendingLink, Date().timeIntervalSince(pending.at) < 60 else { return }
        pendingLink = nil
        play(pending.link)
    }

    /// The channel a link names: the guide's row when loaded, else one built
    /// from the link's own fields.
    func channel(for link: PigTVLink.Play) -> Channel {
        if let row = browse?.guideChannel(id: link.channelKey), let browse { return browse.asChannel(row) }
        if let favourite = browse?.favourites.first(where: { $0.id == link.channelKey }) { return favourite }
        return Channel(rawID: link.id, sourceId: link.sourceId, name: link.name ?? "Channel", logo: nil,
                       category: nil, now: nil, next: nil, number: link.number)
    }

    private func play(_ link: PigTVLink.Play) {
        let channel = channel(for: link)
        if currentPlayback != nil {
            if currentPlayback?.channel.id != channel.id { switchPlayback(to: channel) }
        } else {
            beginPlayback(channel)
        }
    }

    func beginPlayback(_ channel: Channel) {
        guard !playbackBusy, currentPlayback == nil, let client else { return }
        let model = PlaybackModel(channel: channel, client: client, programmes: browse?.programmes(for: channel) ?? [])
        currentPlayback = model
        playback = model
        remember(channel)
        playbackBusy = true
        playerPresented = true
    }

    // Change channel without leaving the player. The old session is released
    // first (the provider allows one stream), then the new one resolves.
    func switchPlayback(to channel: Channel) {
        guard let old = currentPlayback, let client, old.channel.id != channel.id else { return }
        previousChannel = old.channel
        let model = PlaybackModel(channel: channel, client: client, programmes: browse?.programmes(for: channel) ?? [])
        model.prerequisite = Task { _ = await old.stop() }
        currentPlayback = model
        playback = model
        remember(channel)
    }

    private func remember(_ channel: Channel) {
        let entry = LastWatched(sourceId: channel.sourceId, rawID: channel.rawID, name: channel.name,
                                number: channel.number, logo: channel.logo, category: channel.category,
                                stableId: channel.stableId)
        entry.save()
        lastWatched = entry
    }

    // A1.2: swap back to the channel switchPlayback(to:) last switched away
    // from (the player's "Last channel" action / Select long-press).
    func returnToPreviousChannel() {
        guard let previousChannel else { return }
        switchPlayback(to: previousChannel)
    }

    // C-A (iOS "Go to number"): the channel with this number, looked up in the
    // zap list first, then the whole guide. Only with `channelNumbers`.
    func channel(number: Int) -> Channel? {
        if let hit = zapList.first(where: { $0.number == number }) { return hit }
        guard let browse, browse.showsChannelNumbers,
              let row = browse.guide.first(where: { $0.number == number }) else { return nil }
        return browse.asChannel(row)
    }

    /// Parses typed digits and switches to that channel. False when the text
    /// is not a positive number or no channel has it.
    @discardableResult
    func goToChannel(numberText: String) -> Bool {
        guard let number = Int(numberText.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
              let channel = channel(number: number) else { return false }
        if channel.id != currentPlayback?.channel.id { switchPlayback(to: channel) }
        return true
    }

    func zap(_ step: Int) {
        guard let current = currentPlayback?.channel else { return }
        let list = zapList.isEmpty ? (browse.map { model in model.guide.map(model.asChannel) } ?? []) : zapList
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == current.id } ?? -1
        let next = list[((index + step) % list.count + list.count) % list.count]
        switchPlayback(to: next)
    }

    // MARK: Sport (C-I)

    /// Plays one of an event's channels (the best, first, by default) with
    /// the event's channels as the zap list. Switches when already playing.
    func playSportEvent(_ event: SportEvent, channel: SportEventChannel? = nil) {
        guard let browse else { return }
        let channels = event.channels.map(browse.playable)
        guard let chosen = channel.map(browse.playable) ?? channels.first else { return }
        if pendingWatch?.eventID == event.id { cancelPendingWatch() }
        zapList = channels
        if let currentPlayback {
            if currentPlayback.channel.id != chosen.id { switchPlayback(to: chosen) }
        } else {
            beginPlayback(chosen)
        }
    }

    /// "Watch <channel> when it starts": plays at once when the event starts
    /// within five minutes (or is on), else waits for its start while the
    /// app stays in the foreground (backgrounding or signing out cancels).
    func watchWhenStarts(_ event: SportEvent, channel: SportEventChannel? = nil, now: Date = Date()) {
        guard let chosen = channel ?? event.best else { return }
        cancelPendingWatch()
        if event.start.timeIntervalSince(now) <= SportRows.watchNowWindow {
            playSportEvent(event, channel: chosen)
            return
        }
        let pending = PendingWatch(eventID: event.id, title: event.title, channelName: chosen.name, at: event.start)
        pendingWatch = pending
        pendingWatchTask = Task { [weak self] in
            let wait = max(0, pending.at.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self, self.pendingWatch == pending else { return }
            self.pendingWatch = nil
            self.pendingWatchTask = nil
            self.playSportEvent(event, channel: chosen)
        }
    }

    func cancelPendingWatch() {
        pendingWatchTask?.cancel()
        pendingWatchTask = nil
        pendingWatch = nil
    }

    func endPlayback(_ model: PlaybackModel) async {
        let message = await model.stop()
        if currentPlayback === model {
            currentPlayback = nil
            playback = nil
            playbackBusy = false
            playerPresented = false
            if let message { error = message }
        }
    }

    func background() async {
        cancelPairing()
        // Returning to the foreground never starts playback by itself.
        cancelPendingWatch()
        if let currentPlayback { await endPlayback(currentPlayback) }
    }

    #if DEBUG
    // Test-only seam (A1.2): production code reaches `client` only through
    // login/restore/pairing, which also validate the server and touch the
    // keychain. Channel-switching tests need a client but not a real server.
    func configureClientForTesting(_ client: APIClient, browse: BrowseModel? = nil) {
        self.client = client
        if let browse { self.browse = browse }
    }

    // Offline Home fixture (PIGTV_UI_TEST_SCREEN=home): the guide fixture
    // plus favourites, history, recordings, sport events and logos.
    func injectHomeFixture(firstRun: Bool = false) {
        guard let address = try? ServerAddress("http://127.0.0.1:3000"),
              let info = try? JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9.0","build":"0146","apiVersion":1,"features":{"library":true,"playbackResolve":true,"channelNumbers":true,"sportsEvents":true,"recordingHls":true}}"#.utf8)) else { return }
        let client = APIClient(address: address, token: "fixture", info: info)
        let model = BrowseModel(client: client)
        model.isFixture = true
        model.guide = GuideFixtures.enlarged(GuideFixtures.channels(logos: true), to: GuideFixtures.requestedCount)
        if !firstRun {
            model.favourites = GuideFixtures.favourites(from: model.guide).map(model.asChannel)
            model.recent = GuideFixtures.recent(from: model.guide).map(model.asChannel)
            model.recordings = GuideFixtures.recordings()
            lastWatched = GuideFixtures.lastWatched(from: model.guide)
        } else {
            lastWatched = nil
        }
        GuideFixtures.preloadLogos()
        model.sport.setFixture(firstRun ? [] : GuideFixtures.sportEvents(from: model.guide))
        browse = model
        categories = GuideFixtures.categories()
        serverInfo = info
        user = GuideFixtures.user()
    }

    // Offline player fixture (build 29, PIGTV_UI_TEST_SCREEN=player |
    // player-channels | player-tuning): the Home fixture's guide, playing its
    // third channel with a remembered last channel. `media` (a local movie
    // file) makes it ready at once; without it the player stays on the
    // tuning card (the resolve goes to a non-routable TEST-NET address).
    func injectPlayerFixture(media: URL?) {
        injectHomeFixture()
        guard let browse, browse.guide.count > 3 else { return }
        if media == nil, let address = try? ServerAddress("http://192.0.2.1:3000") {
            let client = APIClient(address: address, token: "fixture", info: serverInfo)
            self.client = client
        } else {
            self.client = browse.client
        }
        guard let client else { return }
        zapList = browse.guide.map(browse.asChannel)
        let channel = browse.asChannel(browse.guide[2])
        previousChannel = browse.asChannel(browse.guide[0])
        let model = PlaybackModel(channel: channel, client: client, programmes: browse.guide[2].programmes)
        if let media { model.playFixtureMedia(media) }
        currentPlayback = model
        playback = model
        playbackBusy = true
        playerPresented = true
    }

    // Offline guide fixture for UI iteration (PIGTV_UI_TEST_SCREEN=guide).
    func injectGuideFixture() {
        guard let address = try? ServerAddress("http://127.0.0.1:3000") else { return }
        let client = APIClient(address: address, token: "fixture")
        let model = BrowseModel(client: client)
        model.guide = GuideFixtures.enlarged(GuideFixtures.channels(), to: GuideFixtures.requestedCount)
        browse = model
        categories = GuideFixtures.categories()
        user = GuideFixtures.user()
    }
    #endif
}

/// An upcoming event the user asked to watch when it starts.
nonisolated struct PendingWatch: Equatable, Sendable {
    let eventID: String
    let title: String
    let channelName: String
    let at: Date
}
