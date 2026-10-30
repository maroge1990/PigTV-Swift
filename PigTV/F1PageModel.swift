import Foundation
import Combine

/// C-P (#21): the Formula 1 page's data and the household's sport page preferences. One per signed-in session,
/// owned by BrowseModel; used only when the server advertises `sportPages`. Loaded when the page opens and every
/// 60 s while it is on screen (the server keeps ESPN's answer 10 min on a race weekend, so a reload is cheap and
/// moves a session's status and its channels as the guide gains them).
@MainActor
final class F1PageModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)
    /// An older server (0340–0345) has no preferences route: the device keeps them.
    static let localKey = "sportPagePreferences.local"

    @Published private(set) var page: F1Page?
    @Published private(set) var preferences = SportPagePreferences()
    /// True once one load has finished.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// A save that did not reach the server (the switch is put back).
    @Published private(set) var saveError: String?
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?
    private var serverPreferences = true
    private let defaults: UserDefaults

    init(client: APIClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    func load() async {
        if let inFlight { await inFlight.value; return }
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            async let pageAnswer: F1Page = self.client.decodedOffMain("sports/pages/f1")
            await self.loadPreferences()
            do {
                let answer = try await pageAnswer
                // "Not ready yet" keeps what is on screen; a later load has it.
                if answer.available || self.page == nil, answer != self.page { self.page = answer }
                self.error = nil
            } catch is CancellationError {
            } catch {
                if self.page == nil { self.error = UserMessage.text(for: error) }
            }
            self.loaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func loadPreferences() async {
        do {
            let answer: SportPagePreferences = try await client.request("sports/pages/preferences")
            serverPreferences = true
            if answer != preferences { preferences = answer }
        } catch {
            if error as? PigTVError == .http(404) {
                serverPreferences = false
                let local = defaults.data(forKey: Self.localKey).flatMap { try? JSONDecoder().decode(SportPagePreferences.self, from: $0) }
                    ?? SportPagePreferences()
                if local != preferences { preferences = local }
            }
            // Anything else keeps what is on screen.
        }
    }

    func setSpoilerFree(_ value: Bool) async {
        var next = preferences
        next.spoilerFree = value
        await save(next, body: SpoilerBody(spoilerFree: value))
    }

    func setFollowing(_ driver: String?) async {
        var next = preferences
        next.f1Following = driver
        await save(next, body: FollowBody(following: .init(F1: driver)))
    }

    private struct SpoilerBody: Encodable { let spoilerFree: Bool }
    private struct FollowBody: Encodable {
        struct Pages: Encodable {
            let F1: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(F1, forKey: .f1)
            }
            enum Key: String, CodingKey { case f1 = "F1" }
        }
        let following: Pages
    }

    /// Shows the change at once; puts it back when the server refuses it.
    private func save(_ next: SportPagePreferences, body: any Encodable) async {
        let previous = preferences
        preferences = next
        saveError = nil
        guard !isFixture else { return }
        guard serverPreferences else { return storeLocally(next) }
        do {
            let answer: SportPagePreferences = try await client.request("sports/pages/preferences", method: "PUT", body: body)
            if answer != preferences { preferences = answer }
        } catch {
            if error as? PigTVError == .http(404) {
                serverPreferences = false
                storeLocally(next)
            } else {
                preferences = previous
                saveError = UserMessage.text(for: error)
            }
        }
    }

    private func storeLocally(_ value: SportPagePreferences) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.localKey) }
    }

    /// Loads now, then every 60 s until the calling task is cancelled (the page went away).
    func keepFresh() async {
        await load()
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            await load()
        }
    }

    #if DEBUG
    func setFixture(_ page: F1Page, preferences: SportPagePreferences = SportPagePreferences()) {
        isFixture = true
        self.page = page
        self.preferences = preferences
        loaded = true
    }
    #endif
}
