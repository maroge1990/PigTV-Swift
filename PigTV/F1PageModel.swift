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
    /// #171: saves still to answer, per field: an answer is merged field by field, never wholesale.
    private var savingFields: [Field: Int] = [:]
    /// #172: moves whenever a save answers; a refresh that started before it is older than that answer.
    private var answers = 0
    /// Saves are sent one after another, in the order they were made.
    private var saveQueue: Task<Void, Never>?
    private enum Field: CaseIterable { case spoilerFree, following, nflFollowing, sports, teams }

    private static func copy(_ field: Field, from source: SportPagePreferences, to target: inout SportPagePreferences) {
        switch field {
        case .spoilerFree: target.spoilerFree = source.spoilerFree
        case .following: target.f1Following = source.f1Following
        case .nflFollowing: target.nflFollowing = source.nflFollowing
        case .sports: target.sports = source.sports
        case .teams: target.teams = source.teams
        }
    }

    /// Takes the server's value of each field nothing local is still changing: into what is shown and what a refused
    /// change falls back to. The spoiler choice is known once its own value has been taken (#171).
    private func merge(_ answer: SportPagePreferences, skipping busy: (Field) -> Bool) {
        var shown = preferences
        for field in Field.allCases where !busy(field) {
            Self.copy(field, from: answer, to: &confirmed)
            Self.copy(field, from: answer, to: &shown)
            if field == .spoilerFree { preferencesKnown = true }
        }
        if shown != preferences { preferences = shown }
    }

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

    /// #185: the household's preferences alone (another sport page refreshes them without fetching the F1 page).
    func refreshPreferences() async {
        guard !isFixture else { return }
        await loadPreferences()
    }

    private func loadPreferences() async {
        let startedFields = fieldGeneration
        let startedAnswers = answers
        do {
            let answer: SportPagePreferences = try await client.request("sports/pages/preferences")
            serverPreferences = true
            // #171, #172: per field, and only where nothing changed it, or is saving it, or answered since this began.
            merge(answer) { field in
                (self.savingFields[field] ?? 0) > 0 || self.fieldGeneration[field] != startedFields[field] || self.answers != startedAnswers
            }
        } catch {
            if error as? PigTVError == .http(404) {
                serverPreferences = false
                let local = defaults.data(forKey: Self.localKey).flatMap { try? JSONDecoder().decode(SportPagePreferences.self, from: $0) }
                    ?? SportPagePreferences()
                merge(local) { field in self.fieldGeneration[field] != startedFields[field] }
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

    /// C-Q (#21): the NFL page's followed team (an abbreviation), the household's like the rest. Only with the server's
    /// `sportPageNfl` flag (an older server refuses the key).
    func setNFLFollowing(_ team: String?) async {
        await save(.nflFollowing, body: NFLFollowBody(following: .init(NFL: team))) { $0.nflFollowing = team }
    }

    private nonisolated struct NFLFollowBody: Encodable, Sendable {
        nonisolated struct Pages: Encodable, Sendable {
            let NFL: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(NFL, forKey: .nfl)
            }
            enum Key: String, CodingKey { case nfl = "NFL" }
        }
        let following: Pages
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
            Self.copy(field, from: preferences, to: &confirmed)
            return storeLocally(preferences)
        }
        savingFields[field, default: 0] += 1
        let previous = saveQueue
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let answer: SportPagePreferences = try await self.client.request("sports/pages/preferences", method: "PUT", body: body)
                self.savingFields[field, default: 1] -= 1
                self.answers += 1
                // The server's state after this save: every field nothing local is still saving (#171).
                self.merge(answer) { other in
                    (self.savingFields[other] ?? 0) > 0 || (other == field && self.fieldGeneration[field] != mine)
                }
            } catch {
                self.savingFields[field, default: 1] -= 1
                if error as? PigTVError == .http(404) {
                    self.serverPreferences = false
                    self.confirmed = self.preferences
                    self.storeLocally(self.preferences)
                } else if self.fieldGeneration[field] == mine {
                    Self.copy(field, from: self.confirmed, to: &self.preferences)
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
