import Foundation

// C-T (server 0388, flag `sportPageLeagues`, an array of the leagues it answers; #21, D-43): any team league's page.
// `GET /api/sports/pages/league/<league>` answers `{ available, updatedAt, league, sport, season, rounds, teams, following,
// standings }`: the round before the current one, the current one (and the next once it is over), each game with its
// teams (ids into `teams`), score, status, detail and C-I channels; every team's names, colour and logo by ESPN id; the
// account's followed team's id; the standings as groups of rows with the sport's columns. Fields the feed lacks are null
// and decode as nil; a game, round or row that does not decode is dropped.

private extension KeyedDecodingContainer {
    nonisolated func leagueOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
    /// An id or score that may arrive as a number.
    nonisolated func leagueText(_ key: Key) -> String? {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        if let number = try? decode(Double.self, forKey: key) { return String(number) }
        return nil
    }
}

nonisolated struct LeaguePage: Decodable, Equatable, Sendable {
    var available: Bool
    var updatedAt: Double?
    var league: String?
    /// "australian-football" | "rugby-league" | "rugby" | "soccer" | "basketball" | "baseball" | "hockey".
    var sport: String?
    var rounds: [LeagueRound]
    var teams: [String: LeagueTeam]
    /// The account's followed team's id, or nil.
    var following: String?
    var standings: [LeagueStandingsGroup]

    enum CodingKeys: String, CodingKey { case available, updatedAt, league, sport, rounds, teams, following, standings }
    private enum StandingsKeys: String, CodingKey { case groups }

    init(available: Bool = true, league: String? = nil, rounds: [LeagueRound] = [], teams: [String: LeagueTeam] = [:],
         following: String? = nil, standings: [LeagueStandingsGroup] = []) {
        self.available = available; self.league = league; self.rounds = rounds; self.teams = teams; self.following = following
        self.standings = standings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.leagueOptional(Bool.self, .available) ?? false
        updatedAt = c.leagueOptional(Double.self, .updatedAt)
        league = c.leagueOptional(String.self, .league)
        sport = c.leagueOptional(String.self, .sport)
        rounds = c.leagueOptional(LossyList<LeagueRound>.self, .rounds)?.items ?? []
        var teams: [String: LeagueTeam] = [:]
        if let raw = c.leagueOptional([String: LeagueLossy<LeagueTeam>].self, .teams) {
            for (key, value) in raw { if let team = value.value { teams[key] = team } }
        }
        self.teams = teams
        following = c.leagueText(.following)
        let s = try? c.nestedContainer(keyedBy: StandingsKeys.self, forKey: .standings)
        standings = (s?.leagueOptional(LossyList<LeagueStandingsGroup>.self, .groups))?.items ?? []
    }
}

/// A value that decodes to nil instead of failing its container.
nonisolated struct LeagueLossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

nonisolated struct LeagueRound: Decodable, Equatable, Identifiable, Sendable {
    var key: String
    var label: String
    var current: Bool
    var games: [LeagueGame]
    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, label, current, games }
    init(key: String, label: String, current: Bool, games: [LeagueGame]) {
        self.key = key; self.label = label; self.current = current; self.games = games
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.leagueText(.key) else {
            throw DecodingError.keyNotFound(CodingKeys.key, .init(codingPath: c.codingPath, debugDescription: "no key"))
        }
        self.key = key
        label = c.leagueOptional(String.self, .label) ?? key
        current = c.leagueOptional(Bool.self, .current) ?? false
        games = c.leagueOptional(LossyList<LeagueGame>.self, .games)?.items ?? []
    }
}

nonisolated struct LeagueGame: Decodable, Equatable, Identifiable, Sendable {
    struct Side: Decodable, Equatable, Sendable {
        var id: String?
        var abbr: String
        var score: String?

        enum CodingKeys: String, CodingKey { case id, abbr, score }
        init(id: String?, abbr: String, score: String? = nil) { self.id = id; self.abbr = abbr; self.score = score }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.leagueText(.id)
            abbr = c.leagueOptional(String.self, .abbr) ?? id ?? "?"
            score = c.leagueText(.score)
        }
    }
    var id: String
    var start: Double
    /// scheduled | live | break | done | postponed | cancelled.
    var status: String
    var detail: String?
    var home: Side
    var away: Side
    var venue: String?
    var competition: String?
    var channels: [SportEventChannel]

    enum CodingKeys: String, CodingKey { case id, start, status, detail, home, away, venue, competition, channels }
    init(id: String, start: Double, status: String, detail: String? = nil, home: Side, away: Side, venue: String? = nil,
         competition: String? = nil, channels: [SportEventChannel] = []) {
        self.id = id; self.start = start; self.status = status; self.detail = detail; self.home = home; self.away = away
        self.venue = venue; self.competition = competition; self.channels = channels
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.leagueText(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        self.id = id
        start = try c.decode(Double.self, forKey: .start)
        status = c.leagueOptional(String.self, .status) ?? "scheduled"
        detail = c.leagueOptional(String.self, .detail)
        home = try c.decode(Side.self, forKey: .home)
        away = try c.decode(Side.self, forKey: .away)
        venue = c.leagueOptional(String.self, .venue)
        competition = c.leagueOptional(String.self, .competition)
        channels = c.leagueOptional(LossyList<SportEventChannel>.self, .channels)?.items ?? []
    }
}

nonisolated struct LeagueTeam: Decodable, Equatable, Sendable {
    var id: String?
    var abbr: String
    var name: String?
    var full: String?
    var location: String?
    var color: String?
    var logo: String?

    enum CodingKeys: String, CodingKey { case id, abbr, name, full, location, color, logo }
    init(id: String? = nil, abbr: String, name: String? = nil, full: String? = nil, color: String? = nil, logo: String? = nil) {
        self.id = id; self.abbr = abbr; self.name = name; self.full = full; self.color = color; self.logo = logo
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.leagueText(.id)
        abbr = c.leagueOptional(String.self, .abbr) ?? id ?? "?"
        name = c.leagueOptional(String.self, .name)
        full = c.leagueOptional(String.self, .full)
        location = c.leagueOptional(String.self, .location)
        color = c.leagueOptional(String.self, .color)
        logo = c.leagueOptional(String.self, .logo)
    }
}

nonisolated struct LeagueStandingsGroup: Decodable, Equatable, Sendable {
    struct Column: Decodable, Equatable, Sendable {
        var key: String
        var label: String
    }
    struct Row: Decodable, Equatable, Sendable {
        var id: String?
        var abbr: String
        var rank: Int?
        var values: [String: String?]

        enum CodingKeys: String, CodingKey { case id, abbr, rank, values }
        init(id: String?, abbr: String, rank: Int?, values: [String: String?]) {
            self.id = id; self.abbr = abbr; self.rank = rank; self.values = values
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.leagueText(.id)
            abbr = c.leagueOptional(String.self, .abbr) ?? id ?? "?"
            rank = c.leagueOptional(Int.self, .rank)
            values = c.leagueOptional([String: String?].self, .values) ?? [:]
        }
    }
    /// Nil for a single table; else the conference or competition.
    var name: String?
    var columns: [Column]
    var rows: [Row]

    enum CodingKeys: String, CodingKey { case name, columns, rows }
    init(name: String?, columns: [Column], rows: [Row]) { self.name = name; self.columns = columns; self.rows = rows }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.leagueOptional(String.self, .name)
        columns = c.leagueOptional(LossyList<Column>.self, .columns)?.items ?? []
        rows = c.leagueOptional(LossyList<Row>.self, .rows)?.items ?? []
    }
}
