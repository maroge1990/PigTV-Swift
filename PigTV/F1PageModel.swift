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
    /// #162: false until the household's choice is known (a load answered, or the device keeps it on an older server).
    @Published private(set) var preferencesKnown = false
    /// What the page hides: spoiler-free, or not knowing yet whether it is on.
    var hidesSpoilers: Bool { !preferencesKnown || preferences.spoilerFree }
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
    /// #163: what the server (or this device) last confirmed; a refused change puts its own field back to this.
    private var confirmed = SportPagePreferences()
    /// Moves on every local change; a refresh or an answer that started before it does not overwrite it.
    private var generation = 0
    private var fieldGeneration: [Field: Int] = [:]
    private var savesInFlight = 0
    /// Saves are sent one after another, in the order they were made.
    private var saveQueue: Task<Void, Never>?
    private enum Field { case spoilerFree, following }

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
        let started = generation
        do {
            let answer: SportPagePreferences = try await client.request("sports/pages/preferences")
            serverPreferences = true
            if savesInFlight == 0 {
                confirmed = answer
                // #163: a change made while this was on its way stands.
                if generation == started, answer != preferences { preferences = answer }
            }
            preferencesKnown = true
        } catch {
            if error as? PigTVError == .http(404) {
                serverPreferences = false
                let local = defaults.data(forKey: Self.localKey).flatMap { try? JSONDecoder().decode(SportPagePreferences.self, from: $0) }
                    ?? SportPagePreferences()
                confirmed = local
                if generation == started, local != preferences { preferences = local }
                preferencesKnown = true
            }
            // Anything else keeps what is on screen, and an unknown choice stays unknown (#162).
        }
    }

    func setSpoilerFree(_ value: Bool) async {
        await save(.spoilerFree, body: SpoilerBody(spoilerFree: value)) { $0.spoilerFree = value }
    }

    func setFollowing(_ driver: String?) async {
        await save(.following, body: FollowBody(following: .init(F1: driver))) { $0.f1Following = driver }
    }

    private nonisolated struct SpoilerBody: Encodable, Sendable { let spoilerFree: Bool }
    private nonisolated struct FollowBody: Encodable, Sendable {
        nonisolated struct Pages: Encodable, Sendable {
            let F1: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(F1, forKey: .f1)
            }
            enum Key: String, CodingKey { case f1 = "F1" }
        }
        let following: Pages
    }

    /// Shows the change at once and sends it after any earlier one (#163). A refused change puts back only its own
    /// field, and only if nothing newer changed that field; an answer older than a newer local change is not applied.
    private func save(_ field: Field, body: some Encodable & Sendable, apply: (inout SportPagePreferences) -> Void) async {
        apply(&preferences)
        generation += 1
        let mine = generation
        fieldGeneration[field] = mine
        saveError = nil
        guard !isFixture else { return }
        guard serverPreferences else {
            confirmed = preferences
            return storeLocally(preferences)
        }
        savesInFlight += 1
        let previous = saveQueue
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.savesInFlight -= 1 }
            do {
                let answer: SportPagePreferences = try await self.client.request("sports/pages/preferences", method: "PUT", body: body)
                self.confirmed = answer
                if self.generation == mine, answer != self.preferences { self.preferences = answer }
            } catch {
                if error as? PigTVError == .http(404) {
                    self.serverPreferences = false
                    self.confirmed = self.preferences
                    self.storeLocally(self.preferences)
                } else if self.fieldGeneration[field] == mine {
                    switch field {
                    case .spoilerFree: self.preferences.spoilerFree = self.confirmed.spoilerFree
                    case .following: self.preferences.f1Following = self.confirmed.f1Following
                    }
                    self.saveError = UserMessage.text(for: error)
                }
            }
        }
        saveQueue = task
        await task.value
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
        confirmed = preferences
        preferencesKnown = true
        loaded = true
    }
    #endif
}
