import Foundation
import Combine

/// Settings › Sport (#200, C-U, D-41): what this account follows, synced through the server. One per signed-in session,
/// owned by BrowseModel; used only with the server's `sportFollows` flag. The web's "Your sport" panel
/// (public/js/pages/SportSettings.js) ported: every change is a whole-list `PUT sports/follows`, sent one at a time and
/// built from the state its turn finds (so two quick changes never build on the same old list), and the server's answer
/// is what is shown. "Record every game" is a C-M rule of kind `team`; #278: those rules have one owner, `BrowseModel`
/// and its `RecordingsStore` (what Scheduled lists), which this model reads and changes through `ruleOwner`.
@MainActor
final class SportFollowSettingsModel: ObservableObject {
    /// Asks a question (an alert) and answers with the choice; injectable so tests choose.
    typealias Ask = @MainActor (SportQuestion) async -> Bool

    /// What the account follows: the server's last answer, or (offline) the last copy kept on this device.
    @Published private(set) var follows: SportFollows?
    @Published private(set) var catalog = SportCatalog()
    /// League -> its names (absent: not asked yet).
    @Published private(set) var names: [String: [String]] = [:]
    /// League -> `team` or `person`.
    @Published private(set) var kinds: [String: String] = [:]
    @Published private(set) var suggestions: [SportSuggestions.Suggestion] = []
    /// The line under the controls: what the last change did, or why it was not saved.
    @Published var message = ""
    /// #256 (iPhone, iPad): Edit order is on; the page's form shows each sport's drag handle.
    @Published var ordering = false
    /// #250: how long a "what the change did" line stays ("Removed NFL."). The model lives as long as the app, so it
    /// stayed until the next save or a relaunch. A "Not saved" line stays until the next change. Tests shorten it.
    var doneLingers: Duration = .seconds(6)
    private var doneExpiry: Task<Void, Never>?

    /// A line saying what a change did, cleared after `doneLingers` unless something else has replaced it.
    func showDone(_ text: String) {
        message = text
        doneExpiry?.cancel()
        guard !text.isEmpty else { return }
        let lingers = doneLingers
        doneExpiry = Task { [weak self] in
            try? await Task.sleep(for: lingers)
            guard !Task.isCancelled, let self, self.message == text else { return }
            self.message = ""
        }
    }
    /// The follows could not be read: `follows` is this device's last copy, and nothing can be changed.
    @Published private(set) var offline = false
    /// The follows could not be read and there is no copy.
    @Published private(set) var loadFailed = false
    /// Changes waiting for their turn or their answer.
    @Published private(set) var pending = 0
    /// Rules being switched (sport|name), so a second press waits for the first.
    @Published private(set) var ruleBusy: Set<String> = []

    var canEdit: Bool { follows != nil && !offline }

    /// #280: what Settings › Sport shows: its shape until the first answer, the error (with its own 20 s retry: nothing
    /// polls this page) when there is neither an answer nor a copy, E1 with Add a sport when nothing is followed, or the
    /// sports, with the slim notice while they are this device's last copy (`offline`).
    var state: PageState {
        PageState.of(loaded: loadFailed, hasAnswer: follows != nil, isEmpty: follows?.sports.isEmpty == true,
                     failed: loadFailed, stale: offline, since: nil, failure: PageWords.sportSettingsFailed)
    }
    /// "Record every game" is offered (C-M recording rules; a fixture says whether).
    var rulesAvailable: Bool { isFixture ? fixtureRules : ruleOwner != nil }
    /// #278: the one owner of the recording rules (set by `BrowseModel` when it makes this model).
    weak var ruleOwner: (any RecordingRuleOwner)?
    /// Where the rules are kept: the page observes it, so a change made in Scheduled redraws the switches.
    var ruleStore: RecordingsStore { ruleOwner?.recordingStore ?? Self.noRules }
    private static let noRules = RecordingsStore()
    /// False when the rules could not be read: never taken as "no rules" (web 0421).
    var rulesKnown: Bool {
        if isFixture { return fixtureRules }
        return ruleOwner != nil && ruleStore.rulesLoaded && ruleStore.rulesError == nil
    }
    /// The rules as this page shows them: the store's, less any removed in Recordings (its Undo still open, or the
    /// removal sent and not yet reloaded); none while they could not be read.
    private var rules: [RecordingRule] {
        guard rulesKnown else { return [] }
        let store = ruleStore
        return store.rules.filter { !removed($0) }
    }
    private func removed(_ rule: RecordingRule) -> Bool {
        let key = RecordingsHome.key(rule)
        return ruleStore.pendingRemovals.contains(key) || ruleStore.tombstones[key] != nil
    }
    /// After a save that changed the spoiler-free switch: the sport pages forget their copy of it.
    var onSpoilerFreeChange: (@MainActor () -> Void)?

    let client: APIClient
    private let defaults: UserDefaults
    private(set) var isFixture = false
    private var fixtureRules = false
    private var queue: Task<Void, Never>?
    /// Moves on every load; only the latest one applies its follows.
    private var loadGeneration = 0
    /// Moves on every save answer (or its re-read): a load that began before one does not overwrite it.
    private var answers = 0

    init(client: APIClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    /// Where this account's last copy is kept: per server and account, the key never contains the server's address.
    var cacheKey: String { "sportFollows.lastCopy.\(CacheScope(address: client.address, accountID: client.accountID).digest)" }

    private nonisolated struct Copy: Codable, Sendable {
        let follows: SportFollows
        let catalog: SportCatalog
    }

    func namesOf(_ league: String) -> [String]? { names[league] }
    func label(_ league: String) -> String { catalog.label(league) }
    func entry(_ sport: String) -> SportFollows.Entry? { follows?.entry(sport) }
    func followsPeople(_ entry: SportFollows.Entry) -> Bool { SportFollowLogic.followsPeople(entry, kinds: kinds) }
    func offered(_ entry: SportFollows.Entry) -> [String] { SportFollowLogic.offered(entry, namesOf: namesOf) }
    func rule(_ sport: String, _ name: String) -> RecordingRule? { SportFollowLogic.ruleFor(rules, sport: sport, name: name) }
    /// #278: a team's rule removed in Recordings and not yet settled (Undo open, or the DELETE on its way): until then
    /// its switch waits, so nothing here brings it back or sends a second DELETE.
    func ruleRemovalPending(_ sport: String, _ name: String) -> Bool {
        guard rulesKnown else { return false }
        return SportFollowLogic.ruleFor(ruleStore.rules.filter(removed), sport: sport, name: name) != nil
    }
    /// The row's switch is busy: its own change is waiting or on its way, or its rule's removal is, or the rules could not
    /// be read (#278, Codex high on 214: it would offer a change it cannot decide, so it waits for a read that answers).
    func ruleIsBusy(_ sport: String, _ name: String) -> Bool {
        !rulesKnown || ruleBusy.contains("\(sport)|\(name)") || ruleRemovalPending(sport, name)
    }
    /// The catalogue sports not followed yet, in its order.
    var unfollowedSports: [SportCatalog.Sport] { catalog.sports.filter { s in follows?.entry(s.sport) == nil } }
    /// A sport the catalogue has one league for: added with it, and no league editing.
    func isOneLeague(_ sport: String) -> Bool { (catalog.sport(sport)?.leagues.count ?? 0) <= 1 }

    // MARK: Loading

    /// The follows and the catalogue, then the rules, suggestions and names. Each time the section appears, so a change
    /// made on another device shows.
    func load() async {
        guard !isFixture else { return }
        switch await readFollows() {
        case .applied, .overtaken: break
        case .superseded, .failed: return
        }
        async let rulesRead: Void = loadRules()
        async let suggestionsRead: Void = loadSuggestions()
        async let namesRead: Void = loadNames()
        _ = await (rulesRead, suggestionsRead, namesRead)
    }

    /// What one read of the follows came to.
    private enum FollowsRead {
        /// Its answer is what `follows` holds now.
        case applied
        /// It answered, but a save answered meanwhile (or is waiting), so its answer was not shown.
        case overtaken
        /// A later read began before it answered: nothing was applied.
        case superseded
        /// It failed: `follows` is this device's last copy (`offline`), the old list, or nothing.
        case failed
    }

    /// The follows and the catalogue (the catalogue goes into this device's copy with them), with the load's rules: only
    /// the latest read applies, and a failed one falls back to this device's last copy. `load` and the chip's save both
    /// read through here (#278, review M1).
    private func readFollows() async -> FollowsRead {
        loadGeneration += 1
        let mine = loadGeneration
        let startedAnswers = answers
        async let catalogAnswer: SportCatalog = client.request("sports/catalog")
        let followsAnswer: Result<SportFollows, Error>
        do { followsAnswer = .success(try await client.request("sports/follows")) } catch { followsAnswer = .failure(error) }
        let catalogResult: SportCatalog? = try? await catalogAnswer
        guard mine == loadGeneration else { return .superseded }
        if let catalogResult { catalog = catalogResult }
        switch followsAnswer {
        case .success(let answer):
            // Apple 93 Codex round 2 (high): only an answer that is shown reopens changes; one a save overtook (or that
            // overlapped a save whose answer was lost) leaves `offline` as that save left it.
            guard answers == startedAnswers && pending == 0 else { return .overtaken }
            follows = answer
            offline = false
            loadFailed = false
            keepCopy()
            return .applied
        case .failure(let error):
            if UserMessage.isCancellation(error) { return .failed }
            if let copy = lastCopy() {
                follows = copy.follows
                if catalogResult == nil { catalog = copy.catalog }
                offline = true
                loadFailed = false
            } else if follows == nil {
                loadFailed = true
            } else {
                offline = true
            }
            return .failed
        }
    }

    private func keepCopy() {
        guard let follows, let data = try? JSONEncoder().encode(Copy(follows: follows, catalog: catalog)) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private func lastCopy() -> Copy? {
        defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(Copy.self, from: $0) }
    }

    /// #278: the rules are read by their owner (one generation for every reader, tombstones applied).
    func loadRules() async {
        guard !isFixture, let ruleOwner else { return }
        await ruleOwner.reloadRules()
    }

    func loadSuggestions() async {
        guard !isFixture else { return }
        do {
            let answer: SportSuggestions = try await client.request("sports/suggestions")
            suggestions = answer.suggestions
        } catch { suggestions = [] }
    }

    /// The names of every followed league not asked yet; one that fails stays unknown for now.
    func loadNames() async {
        guard !isFixture else { return }
        let wanted = Array(Set((follows?.sports ?? []).flatMap(\.leagues))).filter { names[$0] == nil }
        var reads: [Task<(String, SportNames?), Never>] = []
        for league in wanted {
            reads.append(Task { [client] in
                (league, try? await client.request("sports/names", query: [URLQueryItem(name: "league", value: league)]) as SportNames)
            })
        }
        for read in reads {
            let (league, answer) = await read.value
            guard let answer else { continue }
            names[league] = answer.names
            kinds[league] = answer.kind
        }
    }

    // MARK: Saving

    /// Saves the whole list (PUT replaces it) after any earlier change, built by `next` from the state when its turn
    /// comes (nil: nothing to change), then shows what the server kept; on failure "Not saved" and what it has.
    func save(_ next: @escaping @MainActor (SportFollows) -> SportFollows?, done: @escaping @MainActor () -> String = { "" }) async {
        pending += 1
        let previous = queue
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.pending -= 1 }
            guard let current = self.follows, !self.offline, let body = next(current) else { return }
            if self.isFixture {
                self.follows = body
                self.showDone(done())
                return
            }
            do {
                let answer: SportFollows = try await self.client.request("sports/follows", method: "PUT", body: body)
                self.answers += 1
                self.follows = answer
                self.keepCopy()
                self.showDone(done())
                if answer.spoilerFree != current.spoilerFree { self.onSpoilerFreeChange?() }
                async let namesRead: Void = self.loadNames()
                async let suggestionsRead: Void = self.loadSuggestions()
                _ = await (namesRead, suggestionsRead)
            } catch {
                self.answers += 1
                self.message = "Not saved: \(UserMessage.text(for: error) ?? "the change was cancelled.")"
                if let again: SportFollows = try? await self.client.request("sports/follows") {
                    self.answers += 1
                    if again.spoilerFree != current.spoilerFree { self.onSpoilerFreeChange?() }
                    self.follows = again
                    self.keepCopy()
                } else {
                    // Apple 92 Codex round 1 (high): the change may have been kept although its answer was lost, so the
                    // list shown may be old. Nothing more is sent until a load reads the server again (a queued change
                    // finds `offline` and drops), and the sport pages ask for Hide scores again in case it changed.
                    self.offline = true
                    self.onSpoilerFreeChange?()
                    self.message += " The server could not be read again, so nothing more can be changed until it answers."
                }
            }
        }
        queue = task
        await task.value
    }

    func setSpoilerFree(_ on: Bool) async {
        await save({ s in var n = s; n.spoilerFree = on; return n }, done: { on ? "Scores are hidden." : "Scores are shown." })
    }

    func moveSport(_ sport: String, by delta: Int) async {
        await save { SportFollowLogic.moveSport($0, sport, delta) }
    }

    /// #256: a sport dragged to a new place in the list (iPhone, iPad).
    func moveSports(from source: IndexSet, to destination: Int) async {
        guard let shown = follows?.sports.map(\.sport) else { return }
        let order = SportFollowLogic.moved(shown, from: source, to: destination)
        await save { SportFollowLogic.orderSports($0, order) }
    }

    func moveLeague(_ sport: String, _ league: String, by delta: Int) async {
        await save { SportFollowLogic.moveLeague($0, sport, league, delta) }
    }

    /// Follows a sport with its first league. -> whether it is followed now.
    @discardableResult
    func addSport(_ sport: String) async -> Bool {
        let one = isOneLeague(sport)
        await save({ [catalog] in SportFollowLogic.addSport($0, sport, catalog: catalog) },
                   done: { one ? "Following \(sport)." : "Following \(sport). Open it to choose its leagues." })
        let followed = follows?.entry(sport) != nil
        if followed { PigHaptic.play(.follow) }
        return followed
    }

    func addLeague(_ sport: String, _ league: String) async {
        let label = label(league)
        await save({ SportFollowLogic.addLeague($0, sport, league) }, done: { "Added \(label)." })
    }

    func removeLeague(_ sport: String, _ league: String, ask: Ask) async {
        guard let follows else { return }
        let label = label(league)
        let (_, orphans, error) = SportFollowLogic.removeLeague(follows, sport, league, namesOf: namesOf)
        if let error { message = error; return }
        if !orphans.isEmpty, !(await ask(SportFollowLogic.removeLeagueQuestion(orphans: orphans, sport: sport, label: label))) { return }
        settleRemovedRules(sport, orphans)
        let left = await forgetRules(sport, orphans, ask: ask)
        await save({ s in
            let removed = SportFollowLogic.removeLeague(s, sport, league)
            return removed.error == nil ? SportFollowLogic.removeNames(removed.state, sport, orphans) : nil
        }, done: { SportFollowLogic.after("Removed \(label).", left) })
    }

    /// -> whether the sport was stopped.
    @discardableResult
    func removeSport(_ sport: String, ask: Ask) async -> Bool {
        guard let entry = entry(sport) else { return false }
        guard await ask(SportFollowLogic.stopFollowingQuestion(entry)) else { return false }
        settleRemovedRules(sport, entry.teams)
        let left = await forgetRules(sport, entry.teams, ask: ask)
        await save({ SportFollowLogic.removeSport($0, sport) }, done: { SportFollowLogic.after("Stopped following \(sport).", left) })
        return self.entry(sport) == nil
    }

    /// Follows one of the names the sport's leagues offer (or, before any are known, the name as typed). -> whether it is
    /// followed now.
    @discardableResult
    func follow(_ sport: String, _ value: String) async -> Bool {
        guard let follows, let entry = follows.entry(sport) else { return false }
        let chosen = SportFollowLogic.choose(value, sport: sport, offered: offered(entry))
        guard let name = chosen.name else { message = chosen.error ?? ""; return false }
        if let error = SportFollowLogic.addName(follows, sport, name).error { message = error; return false }
        await save({ SportFollowLogic.addName($0, sport, name).state }, done: { "Following \(name)." })
        let followed = self.entry(sport)?.teams.contains { SportFollowLogic.same($0, name) } ?? false
        if followed { PigHaptic.play(.follow) }
        return followed
    }

    func unfollow(_ sport: String, _ name: String, ask: Ask) async {
        settleRemovedRules(sport, [name])
        let left = await forgetRules(sport, [name], ask: ask)
        await save({ SportFollowLogic.removeNames($0, sport, [name]) }, done: { SportFollowLogic.after("Unfollowed \(name).", left) })
    }

    func accept(_ suggestion: SportSuggestions.Suggestion) async {
        await save({ SportFollowLogic.addLeague($0, suggestion.sport, suggestion.league) }, done: { "Added \(suggestion.label)." })
    }

    func decline(_ suggestion: SportSuggestions.Suggestion) async {
        guard !isFixture else { suggestions.removeAll { $0 == suggestion }; return }
        struct Body: Encodable { let team: String; let league: String }
        struct Done: Decodable { let success: Bool? }
        do {
            let _: Done = try await client.request("sports/suggestions/decline", method: "POST", body: Body(team: suggestion.team, league: suggestion.league))
        } catch {
            message = "Not saved: \(UserMessage.text(for: error) ?? "the change was cancelled.")"
        }
        await loadSuggestions()
    }

    // MARK: Record every game (C-M kind `team`, D-41 point 11)

    /// #301: a team's rule removed in Scheduled whose Undo is still open is settled (the removal goes ahead) before an
    /// unfollow decides about its rule: otherwise no question is asked and Undo would bring back a rule for a team no
    /// longer followed. The user has already said they do not want that rule.
    private func settleRemovedRules(_ sport: String, _ names: [String]) {
        if names.contains(where: { ruleRemovalPending(sport, $0) }) { ruleOwner?.settlePendingRemovals() }
    }

    /// D-41 point 11: unfollowing a team asks whether to keep its "Record every game"; not kept, it is deleted. -> the
    /// names whose rule could not be stopped, or that the rules could not be read (said, never hidden behind "Unfollowed").
    func forgetRules(_ sport: String, _ names: [String], ask: Ask) async -> SportFollowLogic.Leftover {
        var left = SportFollowLogic.Leftover()
        guard !names.isEmpty, rulesAvailable, !isFixture else { return left }
        await loadRules() // what is set now, not when the section opened
        guard rulesKnown else { left.unknown = true; return left }
        for name in names {
            guard let rule = rule(sport, name), rule.isOn else { continue }
            if await ask(SportFollowLogic.keepRecordingQuestion(name)) { continue }
            do {
                if try await deleteRule(sport, name, asked: rule.id) == .rulesUnknown { left.unknown = true }
            } catch { left.failed.append(name) }
        }
        return left
    }

    /// What a change through the rules' owner came to.
    private enum RuleOutcome { case sent, unchanged, rulesUnknown }

    /// #278: one change through the rules' owner, chosen by `choose` once its turn comes. Codex (high, on 214): while the
    /// rules cannot be read (the first read has not answered, or a read failed, also one made by the change it waited
    /// for), nothing is chosen: an existing rule would look absent, and On would POST a new one instead of switching it
    /// on, or bring back one whose removal is pending.
    private func changeRule(_ ruleOwner: any RecordingRuleOwner, _ choose: () -> RuleChange?) async throws -> RuleOutcome {
        var unknown = false
        let sent = try await ruleOwner.changeRule { [self] in
            guard rulesKnown else { unknown = true; return nil }
            return choose()
        }
        return sent ? .sent : unknown ? .rulesUnknown : .unchanged
    }

    /// #278: deletes the rule the user was asked about, through the owner once its turn comes, unless it has gone or
    /// been removed in Recordings meanwhile (never a second DELETE). The owner reloads the rules after it.
    @discardableResult
    private func deleteRule(_ sport: String, _ name: String, asked id: Int) async throws -> RuleOutcome {
        guard let ruleOwner else { return .unchanged }
        return try await changeRule(ruleOwner) { [self] in
            guard let now = rule(sport, name), now.id == id else { return nil }
            return .delete(id: id)
        }
    }

    /// On: a rule switched off in Recordings is switched back on (its settings kept), else a new one. Off: asks, then
    /// deletes it (recordings already made stay).
    /// #278: through the rules' one owner, after any recordings change in flight (the row shows busy meanwhile), and
    /// decided from the rules as they are when its turn comes. A rule whose removal in Recordings is pending is left
    /// alone (its switch waits for it). The owner reloads the rules after a change, so Scheduled has it at once.
    func setRecording(_ sport: String, _ name: String, on: Bool, ask: Ask) async {
        let key = "\(sport)|\(name)"
        guard !ruleBusy.contains(key), !isFixture, let ruleOwner else { return }
        ruleBusy.insert(key)
        defer { ruleBusy.remove(key) }
        do {
            var outcome = RuleOutcome.unchanged
            if on {
                outcome = try await changeRule(ruleOwner) { [self] in
                    guard !ruleRemovalPending(sport, name) else { return nil }
                    if let current = rule(sport, name) { return .enable(id: current.id) }
                    return .add(RuleBody(kind: "team", match: name, sport: sport))
                }
                if outcome == .sent { showDone("Recording every \(name) game.") }
            } else if let current = rule(sport, name), await ask(SportFollowLogic.stopRecordingQuestion(name)) {
                outcome = try await deleteRule(sport, name, asked: current.id)
                if outcome == .sent { message = "" }
            }
            // The rules could not be read when its turn came: nothing was sent, and the page says so.
            if outcome == .rulesUnknown { message = "Not saved: \(PageWords.rulesFailed)" }
            // Nothing sent: the rules are read again, as before #278 (the owner reloads after a change).
            if outcome != .sent { await loadRules() }
        } catch {
            message = "Not saved: \(UserMessage.text(for: error) ?? "the change was cancelled.")"
        }
    }

    #if DEBUG
    /// Offline UI fixtures: nothing is requested; changes apply locally.
    /// #280 (`PIGTV_UI_TEST_SETTINGS_SPORT_STATE`): Settings › Sport in one of its states: `loading` (no answer, and
    /// none comes), `failed` (no answer and no copy), `empty` (nothing followed), `stale` (the last copy, offline).
    func setFixtureState(_ state: String) {
        isFixture = true
        switch state {
        case "loading":
            follows = nil
            loadFailed = false
        case "failed":
            follows = nil
            loadFailed = true
        case "empty":
            follows = SportFollows(spoilerFree: follows?.spoilerFree ?? false, sports: [])
            suggestions = []
        case "stale":
            offline = true
        default: break
        }
    }

    func setFixture(_ follows: SportFollows, catalog: SportCatalog, names: [String: SportNames.Fixture] = [:],
                    suggestions: [SportSuggestions.Suggestion] = [], rules: [RecordingRule]? = nil) {
        isFixture = true
        self.follows = follows
        self.catalog = catalog
        self.names = names.mapValues(\.names)
        self.kinds = names.mapValues(\.kind)
        self.suggestions = suggestions
        fixtureRules = rules != nil
        // The fixture's rules go where the page reads them: the owner's store (no request is made).
        ruleOwner?.recordingStore.rules = rules ?? []
    }
    #endif
}

#if DEBUG
extension SportNames {
    /// A league's names for an offline fixture.
    nonisolated struct Fixture: Sendable {
        let kind: String
        let names: [String]
    }
}
#endif

#if DEBUG
/// Offline data for Settings › Sport (PIGTV_UI_TEST_SCREEN=settings-sport).
enum SportFollowFixtures {
    static let catalog = SportCatalog(sports: [
        .init(sport: "Football", leagues: [
            .init(league: "Premier League", heading: "Domestic leagues"), .init(league: "A-League", heading: "Domestic leagues"),
            .init(league: "League Cup", heading: "Cups"), .init(league: "Champions League", heading: "Europe"),
            .init(league: "Internationals", label: "International (men)", heading: "International")]),
        .init(sport: "Cricket", leagues: [.init(league: "Cricket", label: "International (men)", heading: "International"),
                                          .init(league: "BBL", heading: "Franchise")]),
        .init(sport: "Rugby league", leagues: [.init(league: "NRL")]),
        .init(sport: "Tennis", leagues: [.init(league: "Grand Slams"), .init(league: "ATP Tour"), .init(league: "WTA Tour")])
    ])
    static let follows = SportFollows(spoilerFree: true, sports: [
        .init(sport: "Football", leagues: ["Premier League", "Champions League"], teams: ["Arsenal", "Liverpool"]),
        .init(sport: "Cricket", leagues: ["Cricket"], teams: ["Australia"])
    ])

    static func apply(to model: SportFollowSettingsModel?) {
        let day = 86_400_000.0
        let soon = (Date().timeIntervalSince1970 * 1000).rounded() + 3 * day
        model?.setFixture(follows, catalog: catalog, names: [
            "Premier League": .init(kind: "team", names: ["Arsenal", "Aston Villa", "Chelsea", "Liverpool", "Manchester City", "Tottenham Hotspur"]),
            "Champions League": .init(kind: "team", names: ["Arsenal", "Barcelona", "Liverpool", "Real Madrid"]),
            "Cricket": .init(kind: "team", names: ["Australia", "England", "India", "South Africa"])
        ], suggestions: [
            .init(sport: "Football", team: "Arsenal", league: "League Cup", label: "League Cup", start: soon)
        ], rules: [RecordingRule(id: 7, kind: "team", match: "Arsenal", enabled: true, sport: "Football", createdByName: "mark")])
    }
}
#endif
