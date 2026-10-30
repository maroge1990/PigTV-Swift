import Foundation

// C-Q (server 0379, flag `sportPageNfl`; #21): the NFL page. `GET /api/sports/pages/nfl` answers `{ available,
// updatedAt, season, weeks, teams, standings }`: the week before the current one and the current one, each game with
// its teams, score or kick-off, status, live situation and C-I channels; the teams on a bye; every team's names,
// colour and logo; the eight divisions. Fields the feed lacks are null and decode as nil; nothing here throws on them.

nonisolated struct NFLPage: Decodable, Equatable, Sendable {
    var available: Bool
    var updatedAt: Double?
    var weeks: [NFLWeek]
    var teams: [String: NFLTeam]
    var standings: [NFLDivision]

    enum CodingKeys: String, CodingKey { case available, updatedAt, weeks, teams, standings }
    private enum StandingsKeys: String, CodingKey { case divisions }

    init(available: Bool = true, updatedAt: Double? = nil, weeks: [NFLWeek] = [], teams: [String: NFLTeam] = [:],
         standings: [NFLDivision] = []) {
        self.available = available; self.updatedAt = updatedAt; self.weeks = weeks; self.teams = teams; self.standings = standings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil
        weeks = (try? c.decodeIfPresent([NFLWeek].self, forKey: .weeks)) ?? []
        teams = (try? c.decodeIfPresent([String: NFLTeam].self, forKey: .teams)) ?? [:]
        let s = try? c.nestedContainer(keyedBy: StandingsKeys.self, forKey: .standings)
        standings = (try? s?.decodeIfPresent([NFLDivision].self, forKey: .divisions)) ?? []
    }
}

nonisolated struct NFLWeek: Decodable, Equatable, Identifiable, Sendable {
    var number: Int
    var label: String
    var current: Bool
    var byes: [String]
    var games: [NFLGame]
    var id: Int { number }

    init(number: Int, label: String, current: Bool, byes: [String] = [], games: [NFLGame] = []) {
        self.number = number; self.label = label; self.current = current; self.byes = byes; self.games = games
    }

    enum CodingKeys: String, CodingKey { case number, label, current, byes, games }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = (try? c.decode(String.self, forKey: .label)) ?? "Week \(number)"
        current = (try? c.decode(Bool.self, forKey: .current)) ?? false
        byes = (try? c.decodeIfPresent([String].self, forKey: .byes)) ?? []
        games = (try? c.decodeIfPresent([NFLGame].self, forKey: .games)) ?? []
    }
}

nonisolated struct NFLGame: Decodable, Equatable, Identifiable, Sendable {
    enum Status: String, Sendable { case scheduled, live, done }
    struct Side: Decodable, Equatable, Sendable {
        var abbr: String
        var score: Int?
        var record: String?
    }
    struct Situation: Decodable, Equatable, Sendable {
        var downDistance: String?
        var possession: String?
        var redZone: Bool?
    }
    var id: String
    /// Milliseconds since 1970.
    var startTime: Double
    var status: Status
    /// "Q1 5:54", "Halftime", "Final", "Final · OT"; nil before kick-off.
    var detail: String?
    var home: Side
    var away: Side
    var situation: Situation?
    var broadcasts: [String]
    var channels: [SportEventChannel]

    var start: Date { Date(timeIntervalSince1970: startTime / 1000) }

    enum CodingKeys: String, CodingKey { case id, start, status, detail, home, away, situation, broadcasts, channels }

    init(id: String, startTime: Double, status: Status, detail: String? = nil, home: Side, away: Side,
         situation: Situation? = nil, broadcasts: [String] = [], channels: [SportEventChannel] = []) {
        self.id = id; self.startTime = startTime; self.status = status; self.detail = detail; self.home = home
        self.away = away; self.situation = situation; self.broadcasts = broadcasts; self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) { id = text } else { id = String(try c.decode(Int.self, forKey: .id)) }
        startTime = try c.decode(Double.self, forKey: .start)
        status = (try? c.decode(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .scheduled
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        home = try c.decode(Side.self, forKey: .home)
        away = try c.decode(Side.self, forKey: .away)
        situation = (try? c.decodeIfPresent(Situation.self, forKey: .situation)) ?? nil
        broadcasts = (try? c.decodeIfPresent([String].self, forKey: .broadcasts)) ?? []
        channels = (try? c.decodeIfPresent([SportEventChannel].self, forKey: .channels)) ?? []
    }
}

nonisolated struct NFLTeam: Decodable, Equatable, Sendable {
    var abbr: String
    var name: String?
    var full: String?
    var location: String?
    var color: String?
    var logo: String?
}

nonisolated struct NFLDivision: Decodable, Equatable, Identifiable, Sendable {
    struct Row: Decodable, Equatable, Sendable {
        var abbr: String
        var wins: Int?
        var losses: Int?
        var ties: Int?
        var record: String?
        var seed: Int?
        var streak: String?
        var pointsFor: Int?
        var pointsAgainst: Int?
    }
    var name: String
    var conference: String?
    var teams: [Row]
    var id: String { name }
}

/// What the page says and orders, from the data, the clock and the preferences. Pure.
nonisolated enum NFLPageText {
    enum StandingsView: String, CaseIterable, Sendable { case division = "Division", conference = "Conference", overall = "Overall" }

    struct StandingsGroup: Equatable, Sendable {
        var title: String
        /// (rank shown, row): the seed in the conference view, the place otherwise.
        var rows: [(rank: Int, row: NFLDivision.Row)]
        static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.rows.map(\.rank) == b.rows.map(\.rank) && a.rows.map(\.row) == b.rows.map(\.row) }
    }

    /// The week the page opens on: the current one (else the last).
    static func openingWeek(_ page: NFLPage) -> Int? {
        (page.weeks.first(where: \.current) ?? page.weeks.last)?.number
    }

    /// A team's short name ("Packers"), else its abbreviation.
    static func name(_ abbr: String, in page: NFLPage) -> String { page.teams[abbr]?.name ?? abbr }

    /// Wins plus half the ties over games played; 0 before any.
    static func winShare(_ r: NFLDivision.Row) -> Double {
        let w = Double(r.wins ?? 0), l = Double(r.losses ?? 0), t = Double(r.ties ?? 0)
        return w + l + t > 0 ? (w + t / 2) / (w + l + t) : 0
    }

    /// The standings as the chosen view shows them. Division: every division, the followed team's first. Conference:
    /// each conference by seed (the followed team's first). Overall: all 32 by win share, then point difference.
    static func standings(_ page: NFLPage, view: StandingsView, following: String?) -> [StandingsGroup] {
        let divisions = page.standings
        switch view {
        case .division:
            let ordered = divisions.filter { d in d.teams.contains { $0.abbr == following } } + divisions.filter { d in !d.teams.contains { $0.abbr == following } }
            return ordered.map { d in StandingsGroup(title: d.name, rows: d.teams.enumerated().map { ($0.offset + 1, $0.element) }) }
        case .conference:
            var confs = Array(Set(divisions.compactMap(\.conference))).sorted()
            if let mine = divisions.first(where: { d in d.teams.contains { $0.abbr == following } })?.conference,
               let i = confs.firstIndex(of: mine) { confs.insert(confs.remove(at: i), at: 0) }
            return confs.map { conf in
                let rows = divisions.filter { $0.conference == conf }.flatMap(\.teams).sorted { ($0.seed ?? 99, $0.abbr) < ($1.seed ?? 99, $1.abbr) }
                return StandingsGroup(title: conf, rows: rows.enumerated().map { ($0.element.seed ?? $0.offset + 1, $0.element) })
            }
        case .overall:
            let rows = divisions.flatMap(\.teams).sorted {
                let a = winShare($0), b = winShare($1)
                if a != b { return a > b }
                let da = ($0.pointsFor ?? 0) - ($0.pointsAgainst ?? 0), db = ($1.pointsFor ?? 0) - ($1.pointsAgainst ?? 0)
                return da != db ? da > db : $0.abbr < $1.abbr
            }
            return [StandingsGroup(title: "League", rows: rows.enumerated().map { ($0.offset + 1, $0.element) })]
        }
    }

    /// The game as a C-I event, so Watch, Record, "Watch when it starts" and the channel picker are the Sport tab's own.
    static func event(_ game: NFLGame, in page: NFLPage) -> SportEvent {
        let start = game.channels.compactMap(\.startTime).min() ?? game.startTime
        let end = game.channels.compactMap(\.endTime).max() ?? (game.startTime + 3.5 * 3600 * 1000)
        return SportEvent(id: "nfl:\(game.id)", title: "\(name(game.away.abbr, in: page)) at \(name(game.home.abbr, in: page))",
                          league: "NFL", startTime: start, endTime: end, channels: game.channels)
    }

    /// The line under a game: the status while live or after, the kick-off before; none of a result with spoilers hidden.
    static func status(_ game: NFLGame, spoilerFree: Bool) -> String {
        switch game.status {
        case .scheduled:
            return game.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .live:
            return spoilerFree ? "Live" : (game.detail ?? "Live")
        case .done:
            return spoilerFree ? "Played" : (game.detail ?? "Final")
        }
    }

    /// The score to show beside a team, or nil (before kick-off, or with spoilers hidden).
    static func score(_ side: NFLGame.Side, game: NFLGame, spoilerFree: Bool) -> String? {
        guard game.status != .scheduled, !spoilerFree, let s = side.score else { return nil }
        return String(s)
    }

    /// The followed team's last and next games across the weeks the page has.
    static func lastAndNext(_ page: NFLPage, team: String) -> (last: NFLGame?, next: NFLGame?) {
        let mine = page.weeks.flatMap(\.games).filter { $0.home.abbr == team || $0.away.abbr == team }.sorted { $0.startTime < $1.startTime }
        return (mine.last { $0.status == .done }, mine.first { $0.status != .done })
    }

    /// Every team, by name, to offer to follow (never in standings order: that would give records away).
    static func followable(_ page: NFLPage) -> [NFLTeam] {
        page.teams.values.sorted { ($0.full ?? $0.abbr) < ($1.full ?? $1.abbr) }
    }
}
