import Foundation

// C-U (server 0391, #193, D-41; Apple #200): what an account follows, sport -> leagues -> teams, and Settings › Sport's
// pure rules, ported from the web's `SportFollowModel` (public/js/pages/SportSettings.js) so both apps behave alike.
// Everything here is nonisolated: the Swift 5 test target and the contract checks call it directly.

/// `GET/PUT /api/sports/follows`: the account's sports in its order, each with its leagues (at least one, in order) and
/// its followed teams or people (one list for the whole sport).
nonisolated struct SportFollows: Codable, Equatable, Sendable {
    var spoilerFree: Bool
    var sports: [Entry]

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var sport: String
        var leagues: [String]
        var teams: [String]

        init(sport: String, leagues: [String], teams: [String] = []) {
            self.sport = sport
            self.leagues = leagues
            self.teams = teams
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sport = try c.decode(String.self, forKey: .sport)
            leagues = (try? c.decode([String].self, forKey: .leagues)) ?? []
            teams = (try? c.decode([String].self, forKey: .teams)) ?? []
        }
    }

    init(spoilerFree: Bool = false, sports: [Entry] = []) {
        self.spoilerFree = spoilerFree
        self.sports = sports
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spoilerFree = (try? c.decode(Bool.self, forKey: .spoilerFree)) ?? false
        sports = try c.decode([Entry].self, forKey: .sports)
    }

    func entry(_ sport: String) -> Entry? { sports.first { $0.sport == sport } }
}

/// `GET /api/sports/catalog`: what can be followed, in the order Settings offers it. 0391–0398 sent plain league names;
/// those are read as a league labelled with its own name.
nonisolated struct SportCatalog: Codable, Equatable, Sendable {
    var sports: [Sport]

    nonisolated struct Sport: Codable, Equatable, Sendable {
        let sport: String
        let leagues: [League]

        init(sport: String, leagues: [League]) { self.sport = sport; self.leagues = leagues }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sport = try c.decode(String.self, forKey: .sport)
            leagues = try c.decode([FollowLossy<League>].self, forKey: .leagues).compactMap(\.value)
        }
    }

    nonisolated struct League: Codable, Equatable, Sendable {
        let league: String
        let label: String
        let heading: String?

        init(league: String, label: String? = nil, heading: String? = nil) {
            self.league = league
            self.label = label ?? league
            self.heading = heading
        }

        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(league: name)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let league = try c.decode(String.self, forKey: .league)
            self.init(league: league, label: try? c.decode(String.self, forKey: .label),
                      heading: try? c.decodeIfPresent(String.self, forKey: .heading))
        }
    }

    init(sports: [Sport] = []) { self.sports = sports }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sports = try c.decode([FollowLossy<Sport>].self, forKey: .sports).compactMap(\.value)
    }

    func sport(_ name: String) -> Sport? { sports.first { $0.sport == name } }

    /// What Settings shows for a league ("International (men)" for cricket's `Cricket`); the name when unknown.
    func label(_ league: String) -> String {
        for s in sports { if let l = s.leagues.first(where: { $0.league == league }) { return l.label } }
        return league
    }
}

/// `GET /api/sports/names?league=`: what can be followed in one league, in name order.
nonisolated struct SportNames: Decodable, Equatable, Sendable {
    let league: String
    /// `team`, or `person` for Tennis, Golf, Combat and Motorsport.
    let kind: String
    let names: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        league = (try? c.decode(String.self, forKey: .league)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "team"
        names = ((try? c.decode([FollowLossy<String>].self, forKey: .names)) ?? []).compactMap(\.value)
    }
    private enum CodingKeys: String, CodingKey { case league, kind, names }
}

/// `GET /api/sports/suggestions`: competitions a followed team plays in that the account does not follow.
nonisolated struct SportSuggestions: Decodable, Equatable, Sendable {
    let suggestions: [Suggestion]

    nonisolated struct Suggestion: Decodable, Equatable, Sendable, Identifiable {
        let sport: String
        let team: String
        let league: String
        let label: String
        /// The team's first fixture there, ms.
        let start: Double
        var id: String { "\(sport)|\(team)|\(league)" }
    }

    init(suggestions: [Suggestion]) { self.suggestions = suggestions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestions = ((try? c.decode([FollowLossy<Suggestion>].self, forKey: .suggestions)) ?? []).compactMap(\.value)
    }
    private enum CodingKeys: String, CodingKey { case suggestions }
}

/// What finding a team's "Record every game" rule needs of a C-M rule row (#278: the app's rows are `RecordingRule`, from
/// the one store Scheduled also lists).
nonisolated protocol SportTeamRuleFields {
    var kind: String { get }
    var match: String { get }
    var sport: String? { get }
}

nonisolated extension RecordingRule: SportTeamRuleFields {}

/// A row of `GET /api/recordings/rules` (C-M), only the fields "Record every game" needs (kind `team`, 0414). #278: the
/// app reads `RecordingRule` from the recordings store; this type remains for the contract checks' decoding.
nonisolated struct SportTeamRule: Decodable, Equatable, Sendable, SportTeamRuleFields {
    let id: Int
    let kind: String
    let match: String
    let sport: String?
    let enabled: Bool
    let createdByName: String?

    init(id: Int, kind: String = "team", match: String, sport: String?, enabled: Bool = true, createdByName: String? = nil) {
        self.id = id; self.kind = kind; self.match = match; self.sport = sport; self.enabled = enabled; self.createdByName = createdByName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        match = (try? c.decode(String.self, forKey: .match)) ?? ""
        sport = try? c.decodeIfPresent(String.self, forKey: .sport)
        // SQLite booleans may arrive as 0/1.
        if let flag = try? c.decode(Bool.self, forKey: .enabled) { enabled = flag }
        else { enabled = ((try? c.decode(Int.self, forKey: .enabled)) ?? 1) != 0 }
        createdByName = try? c.decodeIfPresent(String.self, forKey: .createdByName)
    }
    private enum CodingKeys: String, CodingKey { case id, kind, match, sport, enabled, createdByName }

    /// The rows of a rules answer; one that does not decode is skipped.
    static func list(_ data: Data) throws -> [SportTeamRule] {
        try JSONDecoder().decode([FollowLossy<SportTeamRule>].self, from: data).compactMap(\.value)
    }
}

/// One element that may fail to decode without failing its list.
nonisolated struct FollowLossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A question Settings › Sport asks before a change (an alert): `confirm` answers true, `cancel` false, and dismissing
/// it (Menu) answers `dismissAnswer`.
nonisolated struct SportQuestion: Equatable, Sendable {
    let title: String
    let message: String?
    let confirm: String
    let cancel: String
    /// Whether `confirm` is the destructive choice (else `cancel` is).
    let confirmIsDestructive: Bool
    let dismissAnswer: Bool
}

/// The web's `SportFollowModel`, rule for rule.
nonisolated enum SportFollowLogic {
    static let maxNames = 20
    static let maxNameLength = 80
    /// The sports whose followed names are people (the server's `followsOf`), for before a names answer says.
    static let personSports: Set<String> = ["Tennis", "Golf", "Combat", "Motorsport"]

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Spaces collapsed and trimmed, as the server stores a name.
    static func clean(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `list` with item `index` moved by `delta` (-1 up, +1 down); unchanged at either end.
    static func move<T>(_ list: [T], _ index: Int, _ delta: Int) -> [T] {
        let to = index + delta
        guard list.indices.contains(index), list.indices.contains(to) else { return list }
        var out = list
        out.swapAt(index, to)
        return out
    }

    static func moveSport(_ state: SportFollows, _ sport: String, _ delta: Int) -> SportFollows {
        var next = state
        if let i = state.sports.firstIndex(where: { $0.sport == sport }) { next.sports = move(state.sports, i, delta) }
        return next
    }

    /// #256: a drag in the list. `order` is the sports as the list shows them after the drop; the state its save finds
    /// is put in that order (a sport the list did not have keeps its place after them), so a change made meanwhile on
    /// another device is not lost.
    static func orderSports(_ state: SportFollows, _ order: [String]) -> SportFollows {
        var next = state
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        next.sports = state.sports.enumerated().sorted { a, b in
            (rank[a.element.sport] ?? order.count + a.offset, a.offset) < (rank[b.element.sport] ?? order.count + b.offset, b.offset)
        }.map(\.element)
        return next
    }

    /// A list after a drag: the rows at `source` moved to before `destination` (as SwiftUI's `onMove` reports them).
    static func moved<T>(_ list: [T], from source: IndexSet, to destination: Int) -> [T] {
        let moving = source.filter { list.indices.contains($0) }.map { list[$0] }
        var rest = list.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let at = min(rest.count, max(0, destination - source.filter { $0 < destination }.count))
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    static func moveLeague(_ state: SportFollows, _ sport: String, _ league: String, _ delta: Int) -> SportFollows {
        var next = state
        if let s = next.sports.firstIndex(where: { $0.sport == sport }), let i = next.sports[s].leagues.firstIndex(of: league) {
            next.sports[s].leagues = move(next.sports[s].leagues, i, delta)
        }
        return next
    }

    /// A followed sport added at the end with its first league (a sport needs one; a one-league sport has only that).
    static func addSport(_ state: SportFollows, _ sport: String, catalog: SportCatalog) -> SportFollows {
        guard let entry = catalog.sport(sport), let first = entry.leagues.first, state.entry(sport) == nil else { return state }
        var next = state
        next.sports.append(.init(sport: sport, leagues: [first.league]))
        return next
    }

    static func removeSport(_ state: SportFollows, _ sport: String) -> SportFollows {
        var next = state
        next.sports.removeAll { $0.sport == sport }
        return next
    }

    static func addLeague(_ state: SportFollows, _ sport: String, _ league: String) -> SportFollows {
        var next = state
        if let s = next.sports.firstIndex(where: { $0.sport == sport }), !next.sports[s].leagues.contains(league) {
            next.sports[s].leagues.append(league)
        }
        return next
    }

    static let lastLeagueError = "A sport needs at least one league: remove the sport instead."

    /// Remove a league -> the state, the followed names only that league offers (`orphans`: unfollowed with it, after a
    /// warning), or an error (a sport keeps at least one). A league whose names are not known yet (`namesOf` nil) is never
    /// taken to lack a team.
    static func removeLeague(_ state: SportFollows, _ sport: String, _ league: String,
                             namesOf: (String) -> [String]? = { _ in nil }) -> (state: SportFollows, orphans: [String], error: String?) {
        guard let s = state.entry(sport), s.leagues.contains(league) else { return (state, [], nil) }
        if s.leagues.count == 1 { return (state, [], lastLeagueError) }
        let rest = s.leagues.filter { $0 != league }
        func has(_ l: String, _ name: String) -> Bool? { namesOf(l).map { names in names.contains { same($0, name) } } }
        let orphans = s.teams.filter { t in has(league, t) == true && rest.allSatisfy { has($0, t) == false } }
        var next = state
        if let i = next.sports.firstIndex(where: { $0.sport == sport }) { next.sports[i].leagues = rest }
        return (next, orphans, nil)
    }

    /// Follow `name` in `sport`: once (any case), at most `maxNames`, at most `maxNameLength` characters.
    static func addName(_ state: SportFollows, _ sport: String, _ name: String) -> (state: SportFollows, error: String?) {
        let value = clean(name)
        guard let i = state.sports.firstIndex(where: { $0.sport == sport }), !value.isEmpty else { return (state, nil) }
        if state.sports[i].teams.contains(where: { same($0, value) }) { return (state, "\(value) is followed already.") }
        if state.sports[i].teams.count >= maxNames { return (state, "At most \(maxNames) in one sport.") }
        if value.count > maxNameLength { return (state, "A followed name is too long") }
        var next = state
        next.sports[i].teams.append(value)
        return (next, nil)
    }

    /// The web's `addName` (its panel half): once a sport's leagues offer names, only one of them can be followed, in the
    /// list's own spelling. -> the name to follow, or the error to show.
    static func choose(_ value: String, sport: String, offered: [String]) -> (name: String?, error: String?) {
        let known = offered.first { same($0, value) }
        if !offered.isEmpty, known == nil {
            let shown = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, "\(shown.isEmpty ? "That" : shown) is not in the leagues you follow in \(sport).")
        }
        return (known ?? clean(value), nil)
    }

    static func removeNames(_ state: SportFollows, _ sport: String, _ names: [String]) -> SportFollows {
        var next = state
        if let i = next.sports.firstIndex(where: { $0.sport == sport }) {
            next.sports[i].teams.removeAll { t in names.contains { same($0, t) } }
        }
        return next
    }

    /// The names a sport's chosen leagues offer, each once (any case), in name order.
    static func offered(_ entry: SportFollows.Entry, namesOf: (String) -> [String]?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for l in entry.leagues {
            for n in namesOf(l) ?? [] where seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return out.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// The search: the offered names not followed already, containing `query` (any case), at most `limit`.
    static func matches(_ query: String, offered: [String], following: [String], limit: Int = 30) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let open = offered.filter { n in !following.contains { same($0, n) } }
        let hits = q.isEmpty ? open : open.filter { $0.lowercased().contains(q) }
        return Array(hits.prefix(limit))
    }

    /// The "Record every game" rule on a followed name, if any.
    static func ruleFor<Rule: SportTeamRuleFields>(_ rules: [Rule], sport: String, name: String) -> Rule? {
        rules.first { $0.kind == "team" && $0.sport == sport && same($0.match, name) }
    }

    /// Whether a sport follows people: what its leagues' names answers say (`kinds`: league -> kind), else the server's
    /// fixed list.
    static func followsPeople(_ entry: SportFollows.Entry, kinds: [String: String]) -> Bool {
        if let kind = entry.leagues.lazy.compactMap({ kinds[$0] }).first { return kind == "person" }
        return personSports.contains(entry.sport)
    }

    /// The heading over a sport's followed names: "Teams", "Players", "Fighters" or "Drivers".
    static func namesHeading(_ sport: String, people: Bool) -> String {
        guard people else { return "Teams" }
        switch sport {
        case "Combat": return "Fighters"
        case "Motorsport": return "Drivers"
        default: return "Players"
        }
    }

    /// "Follow a team…", "Follow a player…".
    static func followTitle(_ sport: String, people: Bool) -> String {
        let one: String
        switch namesHeading(sport, people: people) {
        case "Fighters": one = "fighter"
        case "Drivers": one = "driver"
        case "Players": one = "player"
        default: one = "team"
        }
        return "Follow a \(one)…"
    }

    /// A followed sport's row: its leagues by label, then its followed names.
    static func summary(_ entry: SportFollows.Entry, catalog: SportCatalog) -> String {
        let leagues = entry.leagues.map(catalog.label).joined(separator: ", ")
        return entry.teams.isEmpty ? leagues : "\(leagues) · \(entry.teams.joined(separator: ", "))"
    }

    /// "Tue 4 Nov", in `calendar`'s time zone.
    static func day(_ ms: Double, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(days[((c.weekday ?? 1) - 1) % 7]) \(c.day ?? 1) \(months[((c.month ?? 1) - 1) % 12])"
    }

    /// "NRL has Brisbane Broncos games too (the first Tue 4 Nov)."
    static func suggestionText(_ s: SportSuggestions.Suggestion, calendar: Calendar = .current) -> String {
        "\(s.label) has \(s.team) games too (the first \(day(s.start, calendar: calendar)))."
    }

    /// What `forgetRules` left behind: rules that could not be stopped, or the rules could not be read at all.
    nonisolated struct Leftover: Equatable, Sendable {
        var failed: [String] = []
        var unknown = false
    }

    /// A save's message, with any "Record every game" that could not be stopped.
    static func after(_ done: String, _ left: Leftover) -> String {
        if left.unknown {
            return "\(done) The recording rules could not be read, so any \"Record every game\" on it is still on: check Recordings › Recording rules."
        }
        return left.failed.isEmpty ? done
            : "\(done) But every \(left.failed.joined(separator: ", ")) game is still being recorded: stop it in Recordings › Recording rules."
    }

    // MARK: Questions (the web's confirm texts)

    static func stopFollowingQuestion(_ entry: SportFollows.Entry) -> SportQuestion {
        SportQuestion(title: "Stop following \(entry.sport)\(entry.teams.isEmpty ? "" : " and \(entry.teams.joined(separator: ", "))")?",
                      message: nil, confirm: "Stop following", cancel: "Cancel", confirmIsDestructive: true, dismissAnswer: false)
    }

    static func removeLeagueQuestion(orphans: [String], sport: String, label: String) -> SportQuestion {
        let one = orphans.count == 1
        return SportQuestion(title: "Remove \(label)?",
                             message: "\(orphans.joined(separator: ", ")) \(one ? "plays" : "play") in no other league you follow in \(sport), so \(one ? "it" : "they") will be unfollowed too.",
                             confirm: "Remove", cancel: "Cancel", confirmIsDestructive: true, dismissAnswer: false)
    }

    /// Unfollowing a name with "Record every game" on: kept unless "Stop recording" is chosen (Menu keeps it).
    static func keepRecordingQuestion(_ name: String) -> SportQuestion {
        SportQuestion(title: "Keep recording every \(name) game?", message: "Recordings already made stay.",
                      confirm: "Keep recording", cancel: "Stop recording", confirmIsDestructive: false, dismissAnswer: true)
    }

    static func stopRecordingQuestion(_ name: String) -> SportQuestion {
        SportQuestion(title: "Stop recording every \(name) game?", message: "Recordings already made stay.",
                      confirm: "Stop recording", cancel: "Cancel", confirmIsDestructive: true, dismissAnswer: false)
    }
}
