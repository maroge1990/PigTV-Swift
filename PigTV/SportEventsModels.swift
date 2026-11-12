import Foundation

// C-V (server 0428, flag `sportPageEvents`; #197, D-43): the pages of the leagues followed by individuals.
// `GET /api/sports/pages/events?league=<league>` answers `{ available, league, sport, kind, updatedAt, events }` (and, for
// a race league, `lastWinner` and `next`): this week's events, each with the C-R card's id, its status, the account's
// followed names found in it, and by `kind` the tennis matches and draws, the golf leaderboard, the UFC bouts or the
// race's entry list. No channels: Watch and Record use the event's C-R card. Fields the feed lacks are null and decode
// as nil; an event, match, bout or row that does not decode is dropped. What the pages show is pure (`SportEventsText`,
// tests `SportEventsTests`).

private extension KeyedDecodingContainer {
    nonisolated func eventOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
    nonisolated func eventText(_ key: Key) -> String? {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        return nil
    }
}

/// The C-V leagues (C-U): anything else is a 400.
nonisolated enum SportEventLeagues {
    static let all: Set<String> = ["Grand Slams", "ATP Tour", "WTA Tour", "Majors", "PGA Tour", "DP World Tour", "LIV", "LPGA",
                                   "UFC", "IndyCar", "NASCAR"]
}

nonisolated struct SportEventsPage: Decodable, Equatable, Sendable {
    struct Winner: Decodable, Equatable, Sendable {
        var name: String
        var race: String?
        var date: Double?
    }
    struct Next: Decodable, Equatable, Sendable {
        var name: String
        var start: Double?
    }

    var available: Bool
    var league: String?
    var sport: String?
    /// "tennis" | "golf" | "fight" | "race".
    var kind: String?
    var updatedAt: Double?
    var events: [SportEventsEvent]
    var lastWinner: Winner?
    var next: Next?

    enum CodingKeys: String, CodingKey { case available, league, sport, kind, updatedAt, events, lastWinner, next }

    init(available: Bool = true, league: String? = nil, sport: String? = nil, kind: String? = nil, events: [SportEventsEvent] = [],
         lastWinner: Winner? = nil, next: Next? = nil) {
        self.available = available; self.league = league; self.sport = sport; self.kind = kind; self.events = events
        self.lastWinner = lastWinner; self.next = next
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.eventOptional(Bool.self, .available) ?? false
        league = c.eventOptional(String.self, .league)
        sport = c.eventOptional(String.self, .sport)
        kind = c.eventOptional(String.self, .kind)
        updatedAt = c.eventOptional(Double.self, .updatedAt)
        events = c.eventOptional(LossyList<SportEventsEvent>.self, .events)?.items ?? []
        lastWinner = c.eventOptional(Winner.self, .lastWinner)
        next = c.eventOptional(Next.self, .next)
    }
}

nonisolated struct SportEventsEvent: Decodable, Equatable, Identifiable, Sendable {
    struct Venue: Decodable, Equatable, Sendable {
        var name: String?
        var city: String?
        var country: String?
    }

    /// The C-R card's id (`espn:<feed>:<event>`).
    var id: String
    var name: String
    var start: Double
    var end: Double?
    var status: String
    var breakLabel: String?
    var venue: Venue?
    /// The account's followed names found in the event, spelt as the event spells them.
    var followed: [String]
    // Tennis
    var matches: [TennisMatch]
    var draws: [TennisDraw]
    // Golf
    var round: Int?
    var leaderboard: [GolfRow]
    // UFC
    var bouts: [FightBout]
    // IndyCar, NASCAR
    var entryList: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, start, end, status, breakLabel, venue, followed, matches, draws, round, leaderboard, bouts, entryList
    }
    private struct Entry: Decodable { let name: String }

    init(id: String, name: String, start: Double, end: Double? = nil, status: String, followed: [String] = [],
         matches: [TennisMatch] = [], draws: [TennisDraw] = [], round: Int? = nil, leaderboard: [GolfRow] = [],
         bouts: [FightBout] = [], entryList: [String] = []) {
        self.id = id; self.name = name; self.start = start; self.end = end; self.status = status; self.followed = followed
        self.matches = matches; self.draws = draws; self.round = round; self.leaderboard = leaderboard; self.bouts = bouts
        self.entryList = entryList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.eventOptional(String.self, .name) ?? id
        start = try c.decode(Double.self, forKey: .start)
        end = c.eventOptional(Double.self, .end)
        status = c.eventOptional(String.self, .status) ?? "scheduled"
        breakLabel = c.eventOptional(String.self, .breakLabel)
        venue = c.eventOptional(Venue.self, .venue)
        followed = c.eventOptional([String].self, .followed) ?? []
        matches = c.eventOptional(LossyList<TennisMatch>.self, .matches)?.items ?? []
        draws = c.eventOptional(LossyList<TennisDraw>.self, .draws)?.items ?? []
        round = c.eventOptional(Int.self, .round)
        leaderboard = c.eventOptional(LossyList<GolfRow>.self, .leaderboard)?.items ?? []
        bouts = c.eventOptional(LossyList<FightBout>.self, .bouts)?.items ?? []
        entryList = (c.eventOptional(LossyList<Entry>.self, .entryList)?.items ?? []).map(\.name)
    }
}

nonisolated struct TennisMatch: Decodable, Equatable, Identifiable, Sendable {
    struct Player: Decodable, Equatable, Sendable {
        /// Nil while not drawn (TBD); a doubles pair "A / B".
        var name: String?
        var seed: Int?
        var country: String?
        var winner: Bool?
    }
    var id: String
    var draw: String?
    var round: String?
    var start: Double
    var status: String
    var court: String?
    var players: [Player]
    /// Per set, the two players' games, in the players' order; nil before play.
    var sets: [[Int]]?

    enum CodingKeys: String, CodingKey { case id, draw, round, start, status, court, players, sets }
    init(id: String, draw: String? = nil, round: String? = nil, start: Double, status: String, court: String? = nil,
         players: [Player], sets: [[Int]]? = nil) {
        self.id = id; self.draw = draw; self.round = round; self.start = start; self.status = status; self.court = court
        self.players = players; self.sets = sets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.eventText(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        self.id = id
        draw = c.eventOptional(String.self, .draw)
        round = c.eventOptional(String.self, .round)
        start = try c.decode(Double.self, forKey: .start)
        status = c.eventOptional(String.self, .status) ?? "scheduled"
        court = c.eventOptional(String.self, .court)
        players = c.eventOptional([Player].self, .players) ?? []
        sets = c.eventOptional([[Int]].self, .sets)
    }
}

nonisolated struct TennisDraw: Decodable, Equatable, Sendable {
    struct Round: Decodable, Equatable, Sendable {
        var name: String
        var matchIds: [String]
    }
    var name: String
    var rounds: [Round]
}

nonisolated struct GolfRow: Decodable, Equatable, Sendable {
    /// "1", "T4"; nil after a missed cut or when the leaderboard did not answer.
    var pos: String?
    var name: String
    var country: String?
    /// "-7", "E", "+2".
    var toPar: String?
    /// Strokes per round once all 18 holes are in; nil while being played.
    var rounds: [Int?]
    /// "cut" | "wd" | "dq" | nil.
    var status: String?

    init(pos: String?, name: String, toPar: String?, rounds: [Int?] = [], status: String? = nil) {
        self.pos = pos; self.name = name; self.toPar = toPar; self.rounds = rounds; self.status = status
    }
}

nonisolated struct FightBout: Decodable, Equatable, Identifiable, Sendable {
    struct Fighter: Decodable, Equatable, Sendable {
        var name: String
        var winner: Bool?
    }
    struct Result: Decodable, Equatable, Sendable {
        var round: Int?
        var clock: String?
    }
    var id: String
    var start: Double?
    var status: String
    var weightClass: String?
    /// "main" | "prelims".
    var card: String
    var fighters: [Fighter]
    var result: Result?

    enum CodingKeys: String, CodingKey { case id, start, status, weightClass, card, fighters, result }
    init(id: String, start: Double? = nil, status: String, weightClass: String? = nil, card: String, fighters: [Fighter],
         result: Result? = nil) {
        self.id = id; self.start = start; self.status = status; self.weightClass = weightClass; self.card = card
        self.fighters = fighters; self.result = result
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.eventText(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        self.id = id
        start = c.eventOptional(Double.self, .start)
        status = c.eventOptional(String.self, .status) ?? "scheduled"
        weightClass = c.eventOptional(String.self, .weightClass)
        card = c.eventOptional(String.self, .card) ?? "main"
        fighters = c.eventOptional([Fighter].self, .fighters) ?? []
        result = c.eventOptional(Result.self, .result)
    }
}

/// What the event pages show, from the answer, the clock and the spoiler-free switch. Pure.
nonisolated enum SportEventsText {
    static let ongoing: Set<String> = SportStatus.underWayStatuses

    /// A name is followed when the event's `followed` has it exactly (a doubles pair when either of its names is).
    static func followed(_ name: String?, in event: SportEventsEvent) -> Bool {
        guard let name, !event.followed.isEmpty else { return false }
        let names = Set(event.followed)
        if names.contains(name) { return true }
        return name.components(separatedBy: " / ").contains { names.contains($0) }
    }

    /// The event a one-event page leads with: one under way, else the next to start, else the latest.
    static func focus(_ events: [SportEventsEvent]) -> SportEventsEvent? {
        events.first { ongoing.contains($0.status) }
            ?? events.filter { $0.status == "scheduled" }.min { $0.start < $1.start }
            ?? events.max { $0.start < $1.start }
    }

    // MARK: UFC

    struct FightCard: Equatable, Sendable {
        var main: [FightBout]
        var prelims: [FightBout]
    }

    /// The main card and the prelims, each in the feed's order (the first bout of the night first, the main event last).
    static func card(_ event: SportEventsEvent) -> FightCard {
        FightCard(main: event.bouts.filter { $0.card != "prelims" }, prelims: event.bouts.filter { $0.card == "prelims" })
    }

    /// A bout's line: the winner with round and clock ("Szabová · R3 3:20") once finished (spoiler-free: "Finished"),
    /// "Live" while on, the main event or "Up next" before.
    static func boutLine(_ bout: FightBout, isMainEvent: Bool, spoilerFree: Bool) -> String {
        switch bout.status {
        case "finished", "done", "final":
            guard !spoilerFree else { return "Finished" }
            let winner = bout.fighters.first { $0.winner == true }.map { surname($0.name) }
            let result = bout.result.map { r in [r.round.map { "R\($0)" }, r.clock].compactMap { $0 }.joined(separator: " ") }
            let parts = [winner, result].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? "Finished" : parts.joined(separator: " · ")
        case "live", "break": return "Live"
        default: return isMainEvent ? "Main event" : "Up next"
        }
    }

    /// The bout's winner to mark (none with spoilers hidden or before the end).
    static func winner(_ bout: FightBout, spoilerFree: Bool) -> Int? {
        spoilerFree ? nil : bout.fighters.firstIndex { $0.winner == true }
    }

    static func surname(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }

    // MARK: Tennis

    struct TennisRails: Equatable, Sendable {
        var yourPlayers: [TennisMatch]
        var liveNow: [TennisMatch]
        var tonight: [TennisMatch]
        var resultsToday: [TennisMatch]
    }

    /// The rails from every event's matches: Your players (only when a followed player plays this week: their matches,
    /// live first, then the next, then the finished), Live now, Tonight (the rest of today's), Results today.
    static func rails(_ events: [SportEventsEvent], now: Date, calendar: Calendar = .current) -> TennisRails {
        let all = events.flatMap { event in event.matches.map { (event, $0) } }
        func today(_ ms: Double) -> Bool { calendar.isDate(Date(timeIntervalSince1970: ms / 1000), inSameDayAs: now) }
        let nowMs = now.timeIntervalSince1970 * 1000
        let mine = all.filter { event, match in match.players.contains { followed($0.name, in: event) } }.map(\.1)
        func rank(_ m: TennisMatch) -> Int { ongoing.contains(m.status) ? 0 : m.status == "scheduled" ? 1 : 2 }
        let yours = mine.sorted { (rank($0), rank($0) == 2 ? -$0.start : $0.start) < (rank($1), rank($1) == 2 ? -$1.start : $1.start) }
        let live = all.map(\.1).filter { ongoing.contains($0.status) }
        let tonight = all.map(\.1).filter { $0.status == "scheduled" && today($0.start) && $0.start >= nowMs - 3_600_000 }
            .sorted { $0.start < $1.start }
        let results = all.map(\.1).filter { ["finished", "done", "final"].contains($0.status) && today($0.start) }
            .sorted { $0.start > $1.start }
        return TennisRails(yourPlayers: yours, liveNow: live, tonight: tonight, resultsToday: results)
    }

    /// A player's set scores as drawn ("6", "4"…), one per set; none with spoilers hidden or before play.
    static func sets(_ match: TennisMatch, player: Int, spoilerFree: Bool) -> [String] {
        guard !spoilerFree, let sets = match.sets else { return [] }
        return sets.compactMap { $0.indices.contains(player) ? String($0[player]) : nil }
    }

    /// "Alex de Minaur [6]", "TBD".
    static func playerName(_ player: TennisMatch.Player) -> String {
        guard let name = player.name else { return "TBD" }
        return player.seed.map { "\(name) [\($0)]" } ?? name
    }

    /// A match's kicker: "MEN'S SINGLES · ROUND 1".
    static func kicker(_ match: TennisMatch) -> String {
        [match.draw, match.round].compactMap { $0 }.joined(separator: " · ").uppercased()
    }

    /// A match's state: "LIVE", the start ("9:00 pm"), "Final" (spoiler-free: "Finished").
    static func state(_ match: TennisMatch, now: Date, spoilerFree: Bool, calendar: Calendar = .current) -> String {
        if ongoing.contains(match.status) { return "LIVE" }
        if match.status == "scheduled" { return SportFrontText.when(SportFrontText.date(match.start), now: now, calendar: calendar) }
        return spoilerFree ? "Finished" : "Final"
    }

    // MARK: Golf

    struct GolfCard: Equatable, Sendable {
        var name: String
        var pos: String?
        var toPar: String?
        var rounds: [Int?]
        /// "9 behind", "Leader", "Level"; nil when either score is unknown.
        var gap: String?
    }

    struct GolfLayout: Equatable, Sendable {
        /// The top 11 in ESPN's order (spoiler-free: none, the leaderboard is hidden).
        var leaderboard: [GolfRow]
        /// The followed players in the field (an empty list: the right column holds Also this week only).
        var yourPlayers: [GolfCard]
    }

    /// "-7" → -7, "E" → 0, "+2" → 2 (a typographic minus too); nil otherwise.
    static func par(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.uppercased() == "E" { return 0 }
        return Int(text.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "+", with: ""))
    }

    /// The gap to the leader: "Leader", "9 behind"; nil without both scores.
    static func gap(_ row: GolfRow, leader: GolfRow?) -> String? {
        guard let mine = par(row.toPar), let lead = par(leader?.toPar) else { return nil }
        let behind = mine - lead
        return behind <= 0 ? "Leader" : "\(behind) behind"
    }

    /// Rounds 1–3 (the fourth is today's, being played or just done; D-43 shows three).
    static func firstRounds(_ row: GolfRow) -> [Int?] {
        (0..<3).map { $0 < row.rounds.count ? row.rounds[$0] : nil }
    }

    static func golf(_ event: SportEventsEvent, spoilerFree: Bool) -> GolfLayout {
        let leader = event.leaderboard.first { $0.pos != nil }
        let cards = event.leaderboard.filter { followed($0.name, in: event) }.map { row in
            spoilerFree ? GolfCard(name: row.name, pos: nil, toPar: nil, rounds: [], gap: nil)
                : GolfCard(name: row.name, pos: row.pos ?? row.status?.uppercased(), toPar: row.toPar, rounds: firstRounds(row),
                           gap: gap(row, leader: leader))
        }
        return GolfLayout(leaderboard: spoilerFree ? [] : Array(event.leaderboard.prefix(11)), yourPlayers: cards)
    }

    /// An Also this week row's right-hand words: the leader and score ("Yamashita -18"), or the state when spoiler-free
    /// or before it starts ("Round 4 in play", "Thu 5 Nov").
    static func alsoLine(_ event: SportEventsEvent, now: Date, spoilerFree: Bool, calendar: Calendar = .current) -> String {
        if event.status == "scheduled" {
            return SportFrontText.when(SportFrontText.date(event.start), now: now, calendar: calendar)
        }
        if !spoilerFree, let leader = event.leaderboard.first(where: { $0.pos != nil }) {
            return [surname(leader.name), leader.toPar].compactMap { $0 }.joined(separator: " ")
        }
        if let breakLabel = event.breakLabel { return breakLabel }
        if ongoing.contains(event.status) { return event.round.map { "Round \($0) in play" } ?? "In play" }
        return spoilerFree ? "Finished" : "Final"
    }

    // MARK: IndyCar, NASCAR

    struct Race: Equatable, Sendable {
        /// The event's entry list, alphabetical (never a running order).
        var entries: [String]
        /// "Ryan Blaney"; nil with spoilers hidden or none known.
        var lastWinner: String?
        var lastRace: String?
        var next: SportEventsPage.Next?
    }

    static func race(_ page: SportEventsPage, event: SportEventsEvent?, spoilerFree: Bool) -> Race {
        Race(entries: (event?.entryList ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
             lastWinner: spoilerFree ? nil : page.lastWinner?.name, lastRace: page.lastWinner?.race, next: page.next)
    }
}
