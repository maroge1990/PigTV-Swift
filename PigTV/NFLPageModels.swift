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

    /// A team's short name ("Packers"), else its abbreviation.
    static func name(_ abbr: String, in page: NFLPage) -> String { page.teams[abbr]?.name ?? abbr }

    /// #205 (D-39 point 4): the logo a team's badge draws, a same-server logo-cache path (as the front page's
    /// `cachedLogo`), else nil: the colour disc.
    static func logo(_ abbr: String, in page: NFLPage) -> String? {
        page.teams[abbr]?.logo.flatMap { $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil }
    }

    /// The disc's colour (hex) when a team has no logo, or while it loads; black is lifted to the brand's dark plum.
    static func discColor(_ abbr: String, in page: NFLPage) -> String? {
        page.teams[abbr]?.color.flatMap { $0 == "000000" ? "3A3242" : $0 }
    }

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

    enum Action: Hashable, Sendable {
        case watch, watchLive, watchAtKickOff, cancelKickOff, record
        /// #187: a game ESPN marks live whose channel airs it later (a delayed broadcast): play when that airing
        /// starts, or the cancel when already asked.
        case watchAt(Date), cancelWatchAt(Date)
    }

    /// What a game offers (#184): every play action needs a channel the guide carries it on; Watch while the best
    /// channel airs it now, else deferred play from that channel's own airing (#187, as the F1 page decides it):
    /// "Watch at kick-off" before kick-off, "Watch at <time>" for a live game the channel shows later, or the cancel
    /// when already asked; nothing to play once the airing has ended. Record until the game has finished.
    static func actions(_ game: NFLGame, in page: NFLPage, now: Date, pendingEventID: String?) -> [Action] {
        let event = event(game, in: page)
        guard let best = event.best else { return [] }
        var out: [Action] = []
        if game.status != .done {
            switch SportRows.channelAction(event, on: best, now: now) {
            case .play:
                out.append(game.status == .live ? .watchLive : .watch)
            case .wait:
                let pending = pendingEventID == event.id
                if game.status == .live {
                    let at = event.start(on: best)
                    out.append(pending ? .cancelWatchAt(at) : .watchAt(at))
                } else {
                    out.append(pending ? .cancelKickOff : .watchAtKickOff)
                }
            case .ended:
                break
            }
            out.append(.record)
        }
        return out
    }

    /// An action's words in the game's menu.
    static func label(_ action: Action) -> String {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        switch action {
        case .watch: return "Watch"
        case .watchLive: return "Watch live"
        case .watchAtKickOff: return "Watch at kick-off"
        case .cancelKickOff: return "Don't watch at kick-off"
        case .watchAt(let at): return "Watch at \(time(at))"
        case .cancelWatchAt(let at): return "Don't watch at \(time(at))"
        case .record: return "Record"
        }
    }
}
