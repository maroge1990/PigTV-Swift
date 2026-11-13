import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    // Review of 205 (M3): editing the form starts a new attempt, so the last one's note goes.
    @Published var serverText = UserDefaults.standard.string(forKey: "pigtv.server") ?? "" {
        didSet { if serverText != oldValue { formEdited() } }
    }
    @Published var username = "" { didSet { if username != oldValue { formEdited() } } }
    @Published var password = "" { didSet { if password != oldValue { formEdited() } } }
    @Published var error: String?
    /// #280: why the last sign-in attempt (the server check, a password, pairing or the saved sign-in) did not work, in
    /// plain words; Sign in shows it on the form (never an alert) and keeps what was typed.
    @Published var signInError: SignInFailure? { didSet { if signInError == nil { signInRetry = nil } } }
    /// Review of 205 (M2): what the note's "Try again" retries: the attempt the note is about (the saved sign-in, the
    /// server check, the password or pairing), nil when trying the same again cannot help (a wrong password).
    @Published private(set) var signInRetry: SignInFailure.Step?
    @Published private(set) var authBusy = false
    @Published private(set) var canRestore = false
    /// A saved sign-in exists but the restore could not finish: the Offline screen's title and sentence (the server could
    /// not be reached, or it answered that it could not sign in yet).
    @Published private(set) var unreachable: OfflineNotice?
    @Published private(set) var pairing: PairStart?
    @Published private(set) var user: User?
    @Published private(set) var serverInfo: ServerInfo? {
        // R11: warming is on only while the server both supports and enables it.
        didSet { warmer.setEnabled(serverInfo?.warmingActive == true) }
    }
    @Published private(set) var categories: [Category] = []
    @Published var playback: PlaybackModel?
    @Published var playerPresented = false
    /// #301: recording players on screen (each has its own cover); counted so one closing as another opens cannot clear it.
    @Published private(set) var recordingPlayers = 0
    /// True while any full-screen player (live or a recording) covers the pages: they ask for nothing then (#278, #301).
    var pagesCovered: Bool { playerPresented || recordingPlayers > 0 }
    func recordingPlayer(presented: Bool) { recordingPlayers = max(0, recordingPlayers + (presented ? 1 : -1)) }
    /// C-K: the licence reminder banner (shown by ContentView).
    let providerReminders = ProviderReminderModel()
    /// #49 groundwork (Apple 105): the app-level presentation layer and its Undo toast (hosted by LibraryView and ContentView).
    let presenter = AppPresenter()
    /// Build 31: a tab LibraryView should switch to ("guide" from the iOS
    /// player's TV Guide button, "sport" from a pigtv://home link);
    /// LibraryView applies it and clears it.
    @Published var requestedTab: String?
    /// #280: a Settings page to open with it (the Sport page's empty state, "Choose your sport"); the Settings tab
    /// applies it and clears it.
    @Published var requestedSettingsPage: SettingsPage?

    /// #280: the Settings tab, on `page`.
    func openSettings(_ page: SettingsPage) {
        requestedSettingsPage = page
        requestedTab = "settings"
    }
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
    // C-I: "Watch <channel> when it starts" on an upcoming sport event.
    @Published private(set) var pendingWatch: PendingWatch?
    private var pendingWatchTask: Task<Void, Never>?

    /// R11: predictive channel warming (the policy lives in `ChannelWarmer`).
    private(set) lazy var warmer = ChannelWarmer { [weak self] target in await self?.sendWarm(target) ?? false }

    private var authRetry: (server: String, until: Date)?
    private var client: APIClient?
    private let keychain = KeychainStore()
    private var pairingTask: Task<Void, Never>?
    private var authGeneration = UUID()
    private var currentPlayback: PlaybackModel?

    init() {}
    var loggedIn: Bool { user != nil }

    func restore() async {
        // A link that is not played by this restore is dropped.
        defer { pendingLink = nil }
        guard !authBusy, !serverText.isEmpty, !loggedIn else { return }
        authBusy = true
        defer { authBusy = false }
        // Which words a refusal takes: the server's own check (too old, not a PigTV server) reads as Continue's does.
        var words = SignInFailure.Step.saved
        do {
            let address = try ServerAddress(serverText)
            guard let token = try keychain.token(for: address) else { return }
            canRestore = true
            let candidate = APIClient(address: address, token: token)
            // #55 (Apple 161): who is signed in is asked at the same time as what the server can do (it was one after
            // the other, behind the splash); the categories are no longer waited for (below).
            let userAnswer = Task { () async throws -> User in try await candidate.request("auth/me") }
            defer { userAnswer.cancel() } // nothing left running if info fails first
            let info: ServerInfo = try await candidate.request("info")
            words = .server
            try info.validate()
            words = .saved
            let user = try await userAnswer.value
            let authenticated = APIClient(address: address, token: token, info: info, accountID: user.id)
            self.client = authenticated
            self.serverInfo = info
            browse?.retirePrivateCaches()
            self.browse = BrowseModel(client: authenticated, accountID: user.id)
            self.browse?.presenter = presenter
            self.user = user
            canRestore = false
            unreachable = nil
            signInError = nil // review of 205 (M3): a note about an earlier attempt never outlives this sign-in
            categoriesTask?.cancel()
            categoriesTask = Task { await self.loadCategories() } // #55: the tabs show without waiting for it
            // Apple 163 (161 Codex round 2, medium): a saved category filter needs the categories before the guide draws
            // its rows (else Sport shows none and a category every channel): then the restore still waits for them.
            if Self.guideFilterNeedsCategories(UserDefaults.standard.string(forKey: "pigtv.guide.filter")) { await categoriesTask?.value }
            openPendingLink()
        } catch {
            // A cancelled restore (the app went to the background) is retried
            // on the next launch; it is not "unreachable" and not an alert.
            if UserMessage.isCancellation(error) { return }
            // #54 (Apple 160): the saved sign-in is kept whatever the answer: a 401 at launch can be passing (the
            // server's database restored, a restart); Sign in offers it again, and signing in or pairing replaces it.
            // Only Sign out deletes it.
            if error as? PigTVError == .unauthorised { canRestore = true }
            // Review of 205 (H1): every outcome leaves for the screen that says it. Before, a refusal answered to the
            // Offline screen's retry set the sign-in note while Offline stayed up, retrying every 20 s for ever.
            switch Self.restoreOutcome(error) {
            case .offline(let notice):
                unreachable = notice
            case .signIn:
                unreachable = nil
                noteSignInFailure(error, words: words, retry: .saved)
            }
        }
    }

    /// Where a restore that did not finish goes (pure, `SignInRestoreTests`).
    enum RestoreOutcome: Equatable {
        /// The Offline screen, which retries every 20 s: the server could not be reached, or it answered with a server
        /// error (5xx). Nothing on the sign-in form can help with either; the saved sign-in is probably fine, and the
        /// next attempt finishes once the server is back (it may be starting up or updating).
        case offline(OfflineNotice)
        /// Sign in, with the note saying why (a refused saved sign-in, a server too old or not PigTV, an account
        /// refused, too many attempts): something the person has to do.
        case signIn
    }

    static func restoreOutcome(_ error: Error) -> RestoreOutcome {
        if let url = error as? URLError {
            return .offline(OfflineNotice(title: OfflineNotice.unreachableTitle,
                                          message: url.code == .timedOut ? "PigTV did not answer in time. It may be asleep or busy."
                                              : UserMessage.unreachable))
        }
        if case PigTVError.http(let status) = error, (500..<600).contains(status) { return .offline(.notReady) }
        return .signIn
    }

    /// The note for a sign-in attempt that did not work (`words`: whose wording) and what its "Try again" retries.
    private func noteSignInFailure(_ failure: Error, words: SignInFailure.Step, retry: SignInFailure.Step?) {
        signInError = SignInFailure.of(failure, step: words)
        if signInError != nil { signInRetry = retry }
    }

    /// The person changed the address, the username or the password: the last attempt's note is no longer about this.
    private func formEdited() {
        if signInError != nil { signInError = nil }
    }

    func login() async {
        guard allowAuthAttempt(), !authBusy else { return }
        cancelPairing()
        signInError = nil
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
        } catch { recordAuthFailure(error, step: .password) }
    }

    private func allowAuthAttempt() -> Bool {
        guard let authRetry, authRetry.server == serverText, authRetry.until > Date() else { return true }
        signInError = SignInFailure.of(PigTVError.rateLimited(retryAfterSec: Int(ceil(authRetry.until.timeIntervalSinceNow))),
                                       step: .password)
        return false
    }

    private func recordAuthFailure(_ failure: Error, step: SignInFailure.Step) {
        if case PigTVError.rateLimited(let seconds) = failure {
            authRetry = (serverText, Date().addingTimeInterval(Double(seconds)))
        }
        // #280: on the form, in plain words (was the system's text in an alert); "Try again" only where it can help.
        noteSignInFailure(failure, words: step, retry: SignInFailure.retry(after: failure, step: step))
    }

    private func accept(token: String, address: ServerAddress, info: ServerInfo, user: User? = nil) async throws {
        let probe = APIClient(address: address, token: token, info: info)
        let resolvedUser: User
        if let user { resolvedUser = user }
        else { resolvedUser = try await probe.request("auth/me") }
        let candidate = APIClient(address: address, token: token, info: info, accountID: resolvedUser.id)
        try keychain.save(token: token, for: address)
        UserDefaults.standard.set(address.url.absoluteString, forKey: "pigtv.server")
        serverText = address.url.absoluteString
        self.client = candidate
        self.serverInfo = info
        browse?.retirePrivateCaches()
        self.browse = BrowseModel(client: candidate, accountID: resolvedUser.id)
        self.browse?.presenter = presenter
        self.user = resolvedUser
        password = ""
        pairing = nil
        canRestore = false
        error = nil
        signInError = nil
        await loadCategories()
    }

    func startPairing() {
        guard allowAuthAttempt(), !authBusy else { return }
        cancelPairing()
        signInError = nil
        let generation = authGeneration
        authBusy = true
        pairingTask = Task {
            defer { if generation == authGeneration { authBusy = false; pairing = nil } }
            do {
                let address = try ServerAddress(serverText)
                let candidate = APIClient(address: address)
                let info: ServerInfo = try await candidate.request("info")
                try info.validate()
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
                if generation == authGeneration, !Task.isCancelled { recordAuthFailure(error, step: .pairing) }
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

    /// D-44 batch 6: Sign in starts at its server step (not the two tiles) after "Use a different server".
    @Published var signInAtServer = false
    /// Sign in's step 1: the address this session last reached.
    @Published private(set) var checkedServer: String?

    /// Sign in's Continue: reaches the address's `/api/info` before offering the ways to sign in.
    func checkServer() async -> Bool {
        guard !authBusy else { return false }
        authBusy = true
        signInError = nil
        defer { authBusy = false }
        do {
            let address = try ServerAddress(serverText)
            let info: ServerInfo = try await APIClient(address: address).request("info")
            try info.validate()
            checkedServer = serverText
            signInAtServer = false
            return true
        } catch {
            noteSignInFailure(error, words: .server, retry: SignInFailure.retry(after: error, step: .server))
            return false
        }
    }

    /// `chooseServer`: signed out from "Use a different server", so Sign in asks for the server first.
    func logout(chooseServer: Bool = false) async {
        if let currentPlayback { await endPlayback(currentPlayback) }
        guard !playbackBusy else { return }
        do {
            if let client { try keychain.remove(for: client.address) }
            clearSession()
            if chooseServer { signInAtServer = true }
        } catch { self.error = UserMessage.text(for: error) }
    }

    private func clearSession() {
        categoriesTask?.cancel() // Apple 162: an old session's categories never land in the next one
        categoriesTask = nil
        cancelPairing()
        cancelPendingWatch()
        cancelHandoff()
        pendingLink = nil
        TopShelfExport.clear()
        client = nil
        serverInfo = nil
        browse?.retirePrivateCaches()
        browse = nil
        user = nil
        password = ""
        categories = []
        canRestore = false
        signInError = nil // review of 205 (M3): a note about the last session's sign-in never shows after Sign out
        unreachable = nil
    }

    /// Apple 162 (161 Codex round 1, medium): it runs after the tabs show, so its answer is published only while the
    /// session that asked is still the current one (a sign-out or another server may have come meanwhile).
    private var categoriesTask: Task<Void, Never>?
    private func loadCategories() async {
        guard let client else { return }
        do {
            let answer: [Category] = try await client.request("library/categories")
            guard !Task.isCancelled, self.client === client else { return }
            categories = answer
        } catch {
            guard !Task.isCancelled, self.client === client, !UserMessage.isCancellation(error) else { return }
            self.error = UserMessage.text(for: error)
        }
    }

    /// Apple 163: a guide filter other than All and Favourites names categories (Sport, or one category).
    nonisolated static func guideFilterNeedsCategories(_ filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return false }
        return filter != "all" && filter != "favourites"
    }

    // MARK: Deep links (A4.1 Top Shelf)

    /// A play link that arrived before sign-in was restored (a cold launch
    /// from the Top Shelf can deliver the URL before the launch restore
    /// starts). Only a successful restore plays it, within a minute; any
    /// other outcome drops it (restore's defer), so a later manual sign-in
    /// never starts playback unexpectedly.
    private var pendingLink: (link: PigTVLink.Play, at: Date)?

    /// `pigtv://play?…`: plays that channel when signed in; ignored otherwise.
    func open(_ url: URL) {
        // Build 31: pigtv://home showed Home. #216 (Apple 102): Home is retired; the link (still in older Top Shelf
        // snapshots) opens the opening tab: Sport, or the TV Guide where the server has no sport (LibraryView.tab(for:)).
        if PigTVLink.isHome(url) { requestedTab = LibraryView.homeLinkTab; return }
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
        // #13: a Top Shelf channel zaps through the guide, not whatever list the last play left behind.
        zapList = []
        if currentPlayback != nil {
            if currentPlayback?.channel.id != channel.id { switchPlayback(to: channel) }
        } else {
            playOverCovers { $0.beginPlayback(channel) }
        }
    }

    /// #14: how long open pages get to close before a play started from outside them presents the player, and how
    /// long a started play may wait for its player to appear before it is given up.
    static var coverCloseDelay: Duration = .milliseconds(700)
    /// Off in the unit-test host (PIGTV_SYNTHETIC_TESTS), where plays run with no player screen; tests set it.
    static var playerAppearDeadline: Duration? = ProcessInfo.processInfo.environment["PIGTV_SYNTHETIC_TESTS"] == "1" ? nil : .seconds(6)

    /// #14: a play started from outside the screen (the Top Shelf, a "watch when it starts" timer) closes every open
    /// page first, since the player cannot present over a cover; it starts once they are gone.
    func playOverCovers(_ start: @escaping @MainActor (AppModel) -> Void) {
        // #178: one waiting at a time: a newer link replaces it; backgrounding, signing out and any play the user
        // starts cancel it (cancelHandoff).
        cancelHandoff()
        handoffGeneration &+= 1
        let generation = handoffGeneration
        NotificationCenter.default.post(name: .pigCloseCovers, object: nil)
        pendingHandoff = Task { [weak self] in
            do { try await Task.sleep(for: Self.coverCloseDelay) } catch { return }
            guard let self, self.handoffGeneration == generation, !Task.isCancelled else { return }
            self.pendingHandoff = nil
            start(self)
        }
    }

    private var pendingHandoff: Task<Void, Never>?
    private var handoffGeneration = 0

    /// #178: a play waiting for open pages to close is dropped.
    func cancelHandoff() {
        pendingHandoff?.cancel()
        pendingHandoff = nil
        handoffGeneration &+= 1
    }

    /// #14: the player screen appeared for this play (PlayerScreen.onAppear).
    func playerAppeared(_ model: PlaybackModel) {
        if currentPlayback === model { playerShown = true }
    }

    /// D-39: the origin of the plays started inside `withPlayOrigin` (a page's action that runs once its cover closed).
    private var scopedPlayOrigin: String?

    /// D-39: runs `action` with plays it starts recorded as coming from `origin` (when they name none themselves).
    func withPlayOrigin(_ origin: String?, _ action: () -> Void) {
        let saved = scopedPlayOrigin
        scopedPlayOrigin = origin ?? saved
        defer { scopedPlayOrigin = saved }
        action()
    }

    /// `origin`: the tab the play starts from (D-39), sent with the play-start event.
    func beginPlayback(_ channel: Channel, origin: String? = nil) {
        cancelHandoff() // #178: whatever starts now wins over a play still waiting for pages to close
        guard !playbackBusy, currentPlayback == nil, let client else { return }
        let model = PlaybackModel(channel: channel, client: client, programmes: browse?.programmes(for: channel) ?? [])
        model.origin = origin ?? scopedPlayOrigin
        currentPlayback = model
        playback = model
        playbackBusy = true
        playerPresented = true
        updateWarming(for: model, justSwitched: false)
        // #14: a player that never appears (something still covering the screen) does not leave the app "playing"
        // with no player, refusing every later Watch: the play is ended and the reason shown.
        playerShown = false
        armPlayerWatchdog(model)
    }

    /// #14, #179: watches the play that is waiting for its player screen; a switch before it appears re-arms it for
    /// the replacement, so an unseen play is always ended.
    private func armPlayerWatchdog(_ model: PlaybackModel) {
        guard let deadline = Self.playerAppearDeadline else { return }
        Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self, self.currentPlayback === model, !self.playerShown else { return }
            await self.endPlayback(model)
            self.error = "The player could not open. Try again."
        }
    }

    /// #14: whether the current play's player screen has appeared.
    private(set) var playerShown = false

    // Change channel without leaving the player. The old session is released
    // first (the provider allows one stream), then the new one resolves.
    func switchPlayback(to channel: Channel, origin: String? = nil) {
        cancelHandoff() // #178
        guard let old = currentPlayback, let client, old.channel.id != channel.id else { return }
        previousChannel = old.channel
        let model = PlaybackModel(channel: channel, client: client, programmes: browse?.programmes(for: channel) ?? [])
        // D-39: a zap inside the player keeps the play's origin; a new choice from a page names its own.
        model.origin = origin ?? scopedPlayOrigin ?? old.origin
        model.prerequisite = Task { _ = await old.stop() }
        currentPlayback = model
        playback = model
        updateWarming(for: model, justSwitched: true)
        if !playerShown { armPlayerWatchdog(model) } // #179: still no player: the replacement is watched too
    }

    /// R11: tells the warmer which channel the viewer is likely to go to from
    /// `model`'s: the one they just left (they often flip back), else the next
    /// up. The model's start holds warming off until its resolve answers.
    private func updateWarming(for model: PlaybackModel, justSwitched: Bool) {
        model.warmer = warmer
        warmer.beginStart(model.id)
        let list = zapList.isEmpty ? (browse.map { b in b.guide.map(b.asChannel) } ?? []) : zapList
        let likely = ChannelWarmer.likelyNext(current: model.channel, previous: previousChannel,
                                              justSwitched: justSwitched, list: list)
        warmer.setPlayerTarget(likely?.warmTarget)
    }

    private func sendWarm(_ target: WarmTarget) async -> Bool {
        guard let client else { return false }
        // The same body resolve would send for this channel (the server matches
        // the later resolve on channel and capabilities).
        let body = ResolveBody(sourceId: target.sourceId, channelId: target.channelId,
                               capabilities: PlaybackCapabilities.current(),
                               audioEncode: AudioEncodeMemory.contains(target.identityKey) ? true : nil)
        return (try? await client.warm(body))?.warm == true
    }

    // A1.2: swap back to the channel switchPlayback(to:) last switched away
    // from (the player's "Last channel" action / Select long-press).
    func returnToPreviousChannel() {
        guard let previousChannel else { return }
        switchPlayback(to: previousChannel)
    }

    // C-A (iOS "Go to number"): the channel with this number, looked up in the
    // zap list first, then the whole guide.
    func channel(number: Int) -> Channel? {
        if let hit = zapList.first(where: { $0.number == number }) { return hit }
        guard let browse,
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
    func playSportEvent(_ event: SportEvent, channel: SportEventChannel? = nil, origin: String? = nil) {
        guard let browse else { return }
        let channels = event.channels.map(browse.playable)
        guard let chosen = channel.map(browse.playable) ?? channels.first else { return }
        if pendingWatch?.eventID == event.id { cancelPendingWatch() }
        zapList = channels
        if let currentPlayback {
            if currentPlayback.channel.id != chosen.id { switchPlayback(to: chosen, origin: origin) }
        } else {
            beginPlayback(chosen, origin: origin)
        }
    }

    /// "Watch <channel> when it starts": plays at once when the event starts
    /// within five minutes (or is on), else waits for its start while the
    /// app stays in the foreground (backgrounding or signing out cancels).
    func watchWhenStarts(_ event: SportEvent, channel: SportEventChannel? = nil, now: Date = Date()) {
        guard let chosen = channel ?? event.best else { return }
        // Apple 89 (Codex round 2): an airing that has ended is never waited for (it would tune what follows).
        guard SportRows.channelAction(event, on: chosen, now: now) != .ended else { return }
        cancelPendingWatch()
        // #20: when the chosen channel starts showing it, not the earliest of every channel.
        let start = event.start(on: chosen)
        if start.timeIntervalSince(now) <= SportRows.watchNowWindow {
            playSportEvent(event, channel: chosen)
            return
        }
        let pending = PendingWatch(eventID: event.id, title: event.title, channelName: chosen.name, at: start)
        pendingWatch = pending
        pendingWatchTask = Task { [weak self] in
            let wait = max(0, pending.at.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self, self.pendingWatch == pending else { return }
            self.pendingWatch = nil
            self.pendingWatchTask = nil
            // #14: a page may be open when the time comes.
            if self.currentPlayback == nil {
                self.playOverCovers { $0.playSportEvent(event, channel: chosen) }
            } else {
                self.playSportEvent(event, channel: chosen)
            }
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
            // #13: the next play sets its own list; one that sets none zaps through the guide.
            zapList = []
            warmer.playerClosed()
            if let message { error = message }
        }
    }

    /// C-K: launch, foreground and the end of playback. Never during playback.
    func checkProviderReminders() async {
        guard loggedIn else { return }
        await providerReminders.check(client: client, playing: { [weak self] in self?.playerPresented ?? true })
    }

    func background() async {
        cancelPairing()
        // Returning to the foreground never starts playback by itself.
        cancelPendingWatch()
        cancelHandoff() // #178: nor does a Top Shelf or timer play that was waiting for pages to close
        #if os(iOS)
        // Picture in Picture keeps playing until its window is closed (which
        // ends the playback). Auto-PiP starts as the app is left, a moment
        // before or after the background phase: wait for it, then decide.
        if let currentPlayback, PictureInPictureState.shared.armed || PictureInPictureState.shared.active {
            if !PictureInPictureState.shared.active { try? await Task.sleep(for: .seconds(1.5)) }
            if PictureInPictureState.shared.active { return }
            if let current = self.currentPlayback, current === currentPlayback { await endPlayback(current) }
            return
        }
        #endif
        if let currentPlayback { await endPlayback(currentPlayback) }
    }

    #if DEBUG
    // Test-only seam (A1.2): production code reaches `client` only through
    // login/restore/pairing, which also validate the server and touch the
    // keychain. Channel-switching tests need a client but not a real server.
    func configureClientForTesting(_ client: APIClient, browse: BrowseModel? = nil) {
        self.client = client
        warmer.setEnabled(client.info?.warmingActive == true)
        if let browse { self.browse = browse }
    }

    // Offline Home fixture (PIGTV_UI_TEST_SCREEN=home): the guide fixture
    // plus favourites, recordings, sport events and logos.
    /// `sportFront`: the server also has the Sport front page (C-R; PIGTV_UI_TEST_SCREEN=front).
    /// `cricket`: and the Cricket page (C-S).
    /// `pageLeagues`, `events`: the C-T leagues and the C-V pages (D-43 sport pages, PIGTV_UI_TEST_PAGES_JSON).
    func injectHomeFixture(sportFront: Bool = false, cricket: Bool = false, sportFollows: Bool = false,
                           pageLeagues: [String] = [], events: Bool = false) {
        let leagues = (try? JSONSerialization.data(withJSONObject: pageLeagues)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let front = (sportFront ? #","sportFront":true,"sportPages":true,"sportPageNfl":true"# : "") + (cricket ? #","sportPageCricket":true"# : "")
            + (sportFollows ? #","sportFollows":true"# : "")
            + (pageLeagues.isEmpty ? "" : #","sportPageLeagues":"# + leagues) + (events ? #","sportPageEvents":true"# : "")
        guard let address = try? ServerAddress("http://127.0.0.1:3000"),
              let info = try? JSONDecoder().decode(ServerInfo.self, from: Data((#"{"name":"PigTV","version":"3.9.0","build":"0503","apiVersion":1,"features":{"library":true,"playbackResolve":true,"sportsEvents":true"# + front + "}}").utf8)) else { return }
        let client = APIClient(address: address, token: "fixture", info: info, accountID: 1)
        let model = BrowseModel(client: client, accountID: 1)
        model.isFixture = true
        model.guide = GuideFixtures.enlarged(GuideFixtures.channels(logos: true), to: GuideFixtures.requestedCount)
        model.favourites = GuideFixtures.favourites(from: model.guide).map(model.asChannel)
        model.recordings = GuideFixtures.recordings()
        model.recordingStore.loaded = true // #280: the fixture's answer is in
        model.recordingStore.rulesLoaded = true
        GuideFixtures.preloadLogos()
        let sportFixture: [SportEvent]
        if let countStr = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SPORT_EVENTS"],
           let count = Int(countStr), count > 0 {
            sportFixture = GuideFixtures.largeSportEvents(from: model.guide, count: count)
        } else {
            sportFixture = GuideFixtures.sportEvents(from: model.guide)
        }
        model.sport.setFixture(sportFixture)
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
    /// #280 (`PIGTV_UI_TEST_SIGNIN_ERROR=server|password|pairing|saved`): Sign in showing why an attempt did not work, as
    /// the form draws it (the server's address unreachable, a refused password, a pairing code that expired, a refused
    /// saved sign-in with "Try again").
    func injectSignInError(_ kind: String) {
        func note(_ error: Error, _ step: SignInFailure.Step) {
            noteSignInFailure(error, words: step, retry: step == .saved ? .saved : SignInFailure.retry(after: error, step: step))
        }
        switch kind {
        case "server": note(URLError(.cannotConnectToHost), .server)
        case "password": note(PigTVError.unauthorised, .password)
        case "pairing": note(PigTVError.message("The pairing code expired. Request another code."), .pairing)
        case "saved":
            canRestore = true
            note(PigTVError.unauthorised, .saved)
        default: break
        }
    }

    func injectPairingReview() {
        pairing = PairStart(code: "PIG482", expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970 * 1000, expiresInSec: 600)
    }

    /// A documentation-only address that never answers (TEST-NET-1): the fixtures' unreachable server.
    nonisolated static let unreachableFixtureServer = "http://192.0.2.1:3000"

    func injectPlayerFixture(media: URL?) {
        injectHomeFixture()
        guard let browse, browse.guide.count > 3 else { return }
        if media == nil, let address = try? ServerAddress(Self.unreachableFixtureServer) {
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
        // #257: PIGTV_UI_TEST_WATCH_ON=1: the server has sport events, and one live event is on the first three channels.
        let watchOn = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_WATCH_ON"] == "1"
        let info = watchOn ? try? JSONDecoder().decode(ServerInfo.self, from: Data(
            #"{"name":"PigTV","version":"3.9.0","build":"0494","apiVersion":1,"features":{"library":true,"sportsEvents":true}}"#.utf8)) : nil
        let client = info.map { APIClient(address: address, token: "fixture", info: $0) } ?? APIClient(address: address, token: "fixture")
        let model = BrowseModel(client: client)
        model.guide = GuideFixtures.enlarged(GuideFixtures.channels(), to: GuideFixtures.requestedCount)
        model.recordingStore.loaded = true // #280: the fixture's (empty) answer is in
        model.recordingStore.rulesLoaded = true
        if watchOn {
            let now = Date()
            let carrying = model.guide.filter { $0.programmes.contains { $0.start <= now && now < $0.end } }.prefix(3)
            if let first = carrying.first, let on = first.programmes.first(where: { $0.start <= now && now < $0.end }) {
                let channels = carrying.map { SportEventChannel(sourceId: $0.sourceId, rawID: $0.rawID, stableId: $0.stableId,
                                                                name: $0.name, quality: .hd) }
                model.sport.setFixture([SportEvent(id: "fixture-live", title: on.title, league: "F1", startTime: on.startTime,
                                                   endTime: on.endTime, channels: Array(channels))])
            }
        }
        model.window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        // Build 33: the fixture's synthetic programmes reach `forwardHorizon`
        // past now (well past a single loaded day), so the offline "moves
        // right past 24 h" UI test can exercise the grid's actual loaded
        // width without a real server to extend from.
        model.setGuideLoadedUntilForFixture(Date().addingTimeInterval(GuideFixtures.forwardHorizon))
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

/// What the Offline screen says (review of 205, H1): its title and one sentence. It retries by itself every 20 s.
nonisolated struct OfflineNotice: Equatable, Sendable {
    let title: String
    let message: String

    static let unreachableTitle = "Can’t reach PigTV"
    /// The server could not be reached (the fixtures' Offline screen too).
    static let unreachable = OfflineNotice(title: unreachableTitle, message: UserMessage.unreachable)
    /// The server answered with a server error (5xx): it is up but cannot sign this device in yet. The saved sign-in is
    /// kept and the screen keeps trying; nothing on the sign-in form would help.
    static let notReady = OfflineNotice(title: "Your server isn’t ready yet",
                                        message: "It answered but couldn’t sign this device in. It may be starting up or updating. Your sign-in is kept.")
}

/// Brand 1.8 §8 and upgrade row 2 (maroge1990/PigTV#280): the splash shows only while the app is loading. With no
/// saved sign-in there is nothing to load: the app opens on sign-in, with no splash. With one, the splash shows until
/// the session is restored (the first screen then draws its own page-shaped loading state); no minimum time, never
/// held to finish an animation. Before Apple 206 every launch drew the splash and cross-faded it away.
nonisolated enum LaunchStep: Equatable, Sendable {
    case splash, firstScreen

    /// `savedSignIn`: nil when it could not be read (the restore then says why, behind the splash).
    static func opening(hasServerAddress: Bool, savedSignIn: Bool?) -> LaunchStep {
        hasServerAddress && savedSignIn != false ? .splash : .firstScreen
    }

    /// This launch's step, from the saved server address and the Keychain (read synchronously, before the first frame).
    @MainActor static func current(defaults: UserDefaults = .standard) -> LaunchStep {
        #if DEBUG
        LaunchFixture.applySavedSignIn(defaults: defaults)
        #endif
        guard let text = defaults.string(forKey: "pigtv.server"), !text.isEmpty,
              let address = try? ServerAddress(text) else { return opening(hasServerAddress: false, savedSignIn: false) }
        let saved: Bool?
        do { saved = try KeychainStore().token(for: address) != nil } catch { saved = nil }
        return opening(hasServerAddress: true, savedSignIn: saved)
    }
}

#if DEBUG
/// T3 only, to watch the launch in the simulator: PIGTV_UI_TEST_LAUNCH=saved saves a sign-in to an address that never
/// answers (TEST-NET-1; or PIGTV_UI_TEST_LAUNCH_SERVER, a stub the test runs), =none opens with no saved address, and
/// =clear (a launch that draws nothing) puts back the address there was before and removes the fixture's sign-in.
@MainActor enum LaunchFixture {
    private static let backupKey = "pigtv.server.beforeLaunchFixture"
    private static let fixtureServerKey = "pigtv.server.launchFixture"

    static func applySavedSignIn(defaults: UserDefaults) {
        switch ProcessInfo.processInfo.environment["PIGTV_UI_TEST_LAUNCH"] {
        case "saved":
            // PIGTV_UI_TEST_LAUNCH_SERVER: a stub server the test runs instead (to watch a restore's answers).
            let server = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_LAUNCH_SERVER"] ?? AppModel.unreachableFixtureServer
            guard let address = try? ServerAddress(server) else { return }
            backup(defaults)
            defaults.set(server, forKey: fixtureServerKey)
            defaults.set(server, forKey: "pigtv.server")
            try? KeychainStore().save(token: "fixture", for: address)
        case "none":
            backup(defaults)
            defaults.removeObject(forKey: "pigtv.server")
        default: break
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        if let address = try? ServerAddress(AppModel.unreachableFixtureServer) { try? KeychainStore().remove(for: address) }
        if let server = defaults.string(forKey: fixtureServerKey), let address = try? ServerAddress(server) {
            try? KeychainStore().remove(for: address)
        }
        defaults.removeObject(forKey: fixtureServerKey)
        guard let before = defaults.string(forKey: backupKey) else { return }
        if before.isEmpty { defaults.removeObject(forKey: "pigtv.server") } else { defaults.set(before, forKey: "pigtv.server") }
        defaults.removeObject(forKey: backupKey)
    }

    private static func backup(_ defaults: UserDefaults) {
        guard defaults.object(forKey: backupKey) == nil else { return }
        defaults.set(defaults.string(forKey: "pigtv.server") ?? "", forKey: backupKey)
    }
}
#endif
