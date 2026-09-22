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
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var libraryBusy = false
    @Published private(set) var hasMore = false
    @Published var search = ""
    @Published var selectedCategory: Category?
    @Published var playback: PlaybackModel?
    @Published var playerPresented = false
    // The tvOS player presents these over native AVKit controls. Keeping the
    // state here lets transport-bar actions open them without resolving media.
    @Published private(set) var browse: BrowseModel?
    @Published private(set) var playbackBusy = false
    // Channels the guide was showing when playback started: the order used
    // for channel up/down inside the player. Falls back to the whole guide.
    @Published var zapList: [Channel] = []
    @Published private(set) var previousChannel: Channel?
    // Set by the player's transport-bar menu; the player screen presents the
    // channel list sheet and clears it.

    private var authRetry: (server: String, until: Date)?
    private var client: APIClient?
    private let keychain = KeychainStore()
    private var pairingTask: Task<Void, Never>?
    private var authGeneration = UUID()
    private var libraryGeneration = UUID()
    private var offset = 0
    private var currentPlayback: PlaybackModel?
    var loggedIn: Bool { user != nil }

    func restore() async {
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
            await loadLibrary()
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
        await loadLibrary()
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
        libraryGeneration = UUID()
        client = nil
        serverInfo = nil
        browse = nil
        user = nil
        password = ""
        channels = []
        categories = []
        selectedCategory = nil
        search = ""
        libraryBusy = false
        hasMore = false
        canRestore = false
    }

    private func loadCategories() async {
        guard let client else { return }
        do { categories = try await client.request("library/categories") }
        catch { self.error = error.localizedDescription }
    }

    func loadLibrary(reset: Bool = true) async {
        guard let client else { return }
        if !reset && (libraryBusy || !hasMore) { return }
        if reset {
            libraryGeneration = UUID()
            offset = 0
            channels = []
            hasMore = false
        }
        let generation = libraryGeneration
        let pageOffset = offset
        let category = selectedCategory
        libraryBusy = true
        defer { if generation == libraryGeneration { libraryBusy = false } }
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(pageOffset))]
        if let category { query.append(URLQueryItem(name: "category", value: category.rawID)) }
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        do {
            let page: ChannelPage = try await client.request("library/channels", query: query)
            guard generation == libraryGeneration else { return }
            // Server filters category ID but not source ID. Offset tracks all received rows.
            let visible = page.channels.filter { category == nil || $0.sourceId == category?.sourceId }
            var seen = Set(channels.map(\.id))
            channels.append(contentsOf: visible.filter { seen.insert($0.id).inserted })
            offset = pageOffset + page.channels.count
            hasMore = !page.channels.isEmpty && offset < page.total
        } catch {
            guard generation == libraryGeneration else { return }
            if error as? PigTVError == .unauthorised {
                try? keychain.remove(for: client.address)
                clearSession()
            }
            self.error = error.localizedDescription
        }
    }

    func beginPlayback(_ channel: Channel) {
        guard !playbackBusy, currentPlayback == nil, let client else { return }
        let model = PlaybackModel(channel: channel, client: client, programmes: browse?.programmes(for: channel) ?? [])
        currentPlayback = model
        playback = model
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
    }

    func zap(_ step: Int) {
        guard let current = currentPlayback?.channel else { return }
        let list = zapList.isEmpty ? (browse.map { model in model.guide.map(model.asChannel) } ?? []) : zapList
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == current.id } ?? -1
        let next = list[((index + step) % list.count + list.count) % list.count]
        switchPlayback(to: next)
    }

    func returnToPreviousChannel() {
        guard let previousChannel else { return }
        switchPlayback(to: previousChannel)
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
        if let currentPlayback { await endPlayback(currentPlayback) }
    }

    #if DEBUG
    // Offline guide fixture for UI iteration (PIGTV_UI_TEST_SCREEN=guide).
    func injectGuideFixture() {
        guard let address = try? ServerAddress("http://127.0.0.1:3000") else { return }
        let client = APIClient(address: address, token: "fixture")
        let model = BrowseModel(client: client)
        model.guide = GuideFixtures.channels()
        browse = model
        categories = GuideFixtures.categories()
        user = GuideFixtures.user()
    }
    #endif
}
