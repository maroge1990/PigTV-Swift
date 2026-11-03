import Foundation

// D-43 (1 Nov, mock-up V2-League-1): a fixture league under its sport page's banner, the NFL (C-Q) and every C-T league
// alike: the round as a three-column grid of game cards, the last and current round (and the next, once C-T sends it)
// to switch between, and the standings on the right (Division / Conference / Overall where the league has them, else
// one table). Spoiler-free hides scores, the detail after the start and the standings. Watch and Record use the game's
// C-R card when the front page has it (its channels, the card actions and the 95 record choice), else the game's own
// C-I channels. Pure (tests `SportFixtureTests`).

nonisolated struct FixtureLeague: Equatable, Sendable {
    struct Side: Equatable, Sendable {
        var id: String
        var abbr: String
        var name: String
        var logo: String?
        var color: String?
        /// The team's record ("5-3", NFL), hidden with spoilers.
        var record: String?
        var score: String?
        var followed: Bool
    }

    struct Game: Equatable, Identifiable, Sendable {
        var id: String
        var start: Double
        /// scheduled | live | break | done | postponed | cancelled.
        var status: String
        var detail: String?
        /// The live situation (NFL: down and distance), hidden with spoilers.
        var situation: String?
        var home: Side
        var away: Side
        var channels: [SportEventChannel]
        var followed: Bool { home.followed || away.followed }
        var ongoing: Bool { status == "live" || status == "break" }
    }

    struct Round: Equatable, Identifiable, Sendable {
        var key: String
        var label: String
        var current: Bool
        var games: [Game]
        /// NFL: "Bye: Eagles, 49ers".
        var note: String?
        var id: String { key }
    }

    struct Row: Equatable, Sendable {
        var id: String
        var rank: Int?
        var abbr: String
        var name: String
        var logo: String?
        var values: [String?]
        var followed: Bool
    }

    struct Table: Equatable, Sendable {
        var title: String?
        var columns: [String]
        var rows: [Row]
    }

    /// A standings view ("Division", "Conference", "Overall", or one unnamed view) and its tables.
    struct View: Equatable, Sendable {
        var name: String
        var tables: [Table]
    }

    var league: String
    var rounds: [Round]
    var views: [View]
    /// The NFL lists the away team first ("Packers at Lions").
    var awayFirst = false
}

nonisolated enum FixtureText {
    /// Only same-server logo-cache paths (as `cachedLogo`).
    static func cached(_ logo: String?) -> String? {
        logo.flatMap { $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil }
    }

    /// A followed name matches a team by its name, full name or abbreviation, any case.
    static func follows(_ names: [String], name: String?, full: String?, abbr: String) -> Bool {
        let wanted = Set(names.map { $0.lowercased() })
        return [name, full, abbr].compactMap { $0?.lowercased() }.contains { wanted.contains($0) }
    }

    // MARK: From the NFL page (C-Q)

    static func nfl(_ page: NFLPage, following: [String], spoilerFree: Bool) -> FixtureLeague {
        func side(_ s: NFLGame.Side, game: NFLGame) -> FixtureLeague.Side {
            let team = page.teams[s.abbr]
            return FixtureLeague.Side(id: s.abbr, abbr: s.abbr, name: team?.name ?? s.abbr, logo: cached(team?.logo),
                                      color: NFLPageText.discColor(s.abbr, in: page),
                                      record: spoilerFree ? nil : s.record,
                                      score: NFLPageText.score(s, game: game, spoilerFree: spoilerFree),
                                      followed: follows(following, name: team?.name, full: team?.full, abbr: s.abbr))
        }
        let rounds = page.weeks.map { week in
            FixtureLeague.Round(
                key: String(week.number), label: week.label, current: week.current,
                games: week.games.map { game in
                    FixtureLeague.Game(id: game.id, start: game.startTime, status: game.status.rawValue,
                                       detail: detail(game.detail, status: game.status.rawValue, spoilerFree: spoilerFree),
                                       situation: spoilerFree || game.status != .live ? nil : game.situation?.downDistance,
                                       home: side(game.home, game: game), away: side(game.away, game: game),
                                       channels: game.channels)
                },
                note: week.byes.isEmpty ? nil : "Bye: " + week.byes.map { NFLPageText.name($0, in: page) }.joined(separator: ", "))
        }
        let followed = page.standings.flatMap(\.teams).first { row in
            let team = page.teams[row.abbr]
            return follows(following, name: team?.name, full: team?.full, abbr: row.abbr)
        }?.abbr
        let views: [FixtureLeague.View] = page.standings.isEmpty ? [] : NFLPageText.StandingsView.allCases.map { view in
            FixtureLeague.View(name: view.rawValue, tables: NFLPageText.standings(page, view: view, following: followed).map { group in
                FixtureLeague.Table(title: group.title, columns: ["W-L", "STREAK"], rows: group.rows.map { rank, row in
                    let team = page.teams[row.abbr]
                    return FixtureLeague.Row(id: row.abbr, rank: rank, abbr: row.abbr, name: team?.name ?? row.abbr,
                                             logo: cached(team?.logo), values: [row.record, row.streak],
                                             followed: row.abbr == followed)
                })
            })
        }
        return FixtureLeague(league: "NFL", rounds: rounds, views: views, awayFirst: true)
    }

    // MARK: From a C-T page

    static func league(_ page: LeaguePage, league: String, following: [String], spoilerFree: Bool) -> FixtureLeague {
        func isFollowed(_ id: String?, abbr: String) -> Bool {
            if let id, id == page.following { return true }
            let team = id.flatMap { page.teams[$0] }
            return follows(following, name: team?.name, full: team?.full, abbr: abbr)
        }
        func side(_ s: LeagueGame.Side, game: LeagueGame) -> FixtureLeague.Side {
            let team = s.id.flatMap { page.teams[$0] }
            let played = !["scheduled", "postponed", "cancelled"].contains(game.status)
            return FixtureLeague.Side(id: s.id ?? s.abbr, abbr: s.abbr, name: team?.name ?? team?.full ?? s.abbr,
                                      logo: cached(team?.logo), color: team?.color, record: nil,
                                      score: spoilerFree || !played ? nil : s.score,
                                      followed: isFollowed(s.id, abbr: s.abbr))
        }
        let rounds = page.rounds.map { round in
            FixtureLeague.Round(key: round.key, label: round.label, current: round.current, games: round.games.map { game in
                FixtureLeague.Game(id: game.id, start: game.start, status: game.status,
                                   detail: detail(game.detail, status: game.status, spoilerFree: spoilerFree), situation: nil,
                                   home: side(game.home, game: game), away: side(game.away, game: game), channels: game.channels)
            }, note: nil)
        }
        let tables = page.standings.map { group in
            FixtureLeague.Table(title: group.name, columns: group.columns.map(\.label), rows: group.rows.map { row in
                let team = row.id.flatMap { page.teams[$0] }
                return FixtureLeague.Row(id: row.id ?? row.abbr, rank: row.rank, abbr: row.abbr,
                                         name: team?.name ?? team?.full ?? row.abbr, logo: cached(team?.logo),
                                         values: group.columns.map { standingValue(row.values[$0.key] ?? nil, key: $0.key) },
                                         followed: isFollowed(row.id, abbr: row.abbr))
            })
        }
        return FixtureLeague(league: league, rounds: rounds, views: tables.isEmpty ? [] : [FixtureLeague.View(name: "", tables: tables)])
    }

    /// A standings value as drawn: ESPN's text, except a percentage, to one decimal ("137.200" → "137.2", #211).
    static func standingValue(_ value: String?, key: String) -> String? {
        guard key == "percentage", let value, let number = Double(value.trimmingCharacters(in: .whitespaces)) else { return value }
        return String(format: "%.1f", number)
    }

    /// The detail as it may be drawn: before the start none; with spoilers hidden only neutral words ("Live", "Played").
    static func detail(_ detail: String?, status: String, spoilerFree: Bool) -> String? {
        switch status {
        case "scheduled": return nil
        case "postponed": return "Postponed"
        case "cancelled": return "Cancelled"
        case "live", "break": return spoilerFree ? "Live" : (detail ?? "Live")
        default: return spoilerFree ? "Played" : (detail ?? "Final")
        }
    }

    // MARK: Choices

    /// The round the page opens on: the current one, else the last.
    static func openingRound(_ league: FixtureLeague) -> String? {
        (league.rounds.first(where: \.current) ?? league.rounds.last)?.key
    }

    /// The round shown: the chosen one while the answer still has it, else the opening one.
    static func round(_ chosen: String?, in league: FixtureLeague) -> FixtureLeague.Round? {
        if let chosen, let round = league.rounds.first(where: { $0.key == chosen }) { return round }
        let key = openingRound(league)
        return league.rounds.first { $0.key == key }
    }

    /// The standings view shown: the chosen one while the league has it, else the first.
    static func view(_ chosen: String?, in league: FixtureLeague) -> FixtureLeague.View? {
        league.views.first { $0.name == chosen } ?? league.views.first
    }

    /// The followed team's table first (the rest in the order sent).
    static func tables(_ view: FixtureLeague.View) -> [FixtureLeague.Table] {
        view.tables.filter { $0.rows.contains(where: \.followed) } + view.tables.filter { !$0.rows.contains(where: \.followed) }
    }

    /// A table group under the standings' buttons.
    struct TableGroup: Equatable, Sendable {
        var name: String
        var tables: [FixtureLeague.Table]
    }

    /// The view's tables in groups of at most `size`, so every table is a button press away: up to `size` tables are one
    /// group; more go by their title's first word ("AFC East" → AFC, the followed team's group first), and a group still
    /// too big, or tables without such titles, in runs of `size` ("Tables 5–8").
    static func groups(_ view: FixtureLeague.View, size: Int = 4) -> [TableGroup] {
        let all = tables(view)
        guard all.count > size else { return [TableGroup(name: "", tables: all)] }
        var named: [TableGroup] = []
        for table in all {
            let word = table.title?.split(separator: " ").first.map(String.init) ?? ""
            if let index = named.firstIndex(where: { $0.name == word }) { named[index].tables.append(table) }
            else { named.append(TableGroup(name: word, tables: [table])) }
        }
        if named.count > 1, named.allSatisfy({ !$0.name.isEmpty && $0.tables.count <= size }) { return named }
        return stride(from: 0, to: all.count, by: size).map { start in
            let end = min(start + size, all.count)
            return TableGroup(name: "Tables \(start + 1)–\(end)", tables: Array(all[start..<end]))
        }
    }

    /// The game's C-R card on the front page (same league, both teams named, starting within 90 minutes), whose channels
    /// and actions Watch and Record use; nil when the front page has none.
    static func card(for game: FixtureLeague.Game, league: String, in front: SportFront?) -> SportsGame? {
        guard let front else { return nil }
        return front.games.first { card in
            guard card.league == league, abs(card.start - game.start) <= 90 * 60_000, card.competitors.count == 2 else { return false }
            let names = card.competitors.map { $0.name.lowercased() }
            func named(_ side: FixtureLeague.Side) -> Bool {
                let mine = [side.name, side.abbr].map { $0.lowercased() }
                return names.contains { name in mine.contains { $0 == name || $0.hasSuffix(" " + name) || name.hasSuffix(" " + $0) } }
            }
            return named(game.home) && named(game.away)
        }
    }

    /// A game without a C-R card as a C-I event on its own channels, so Watch and Record still work.
    static func event(_ game: FixtureLeague.Game, league: String) -> SportEvent {
        let start = game.channels.compactMap(\.startTime).min() ?? game.start
        let end = game.channels.compactMap(\.endTime).max() ?? (game.start + 3 * 3600 * 1000)
        return SportEvent(id: "\(league):\(game.id)", title: "\(game.home.name) v \(game.away.name)", league: league,
                          startTime: start, endTime: max(end, start + 60_000), channels: game.channels)
    }
}
