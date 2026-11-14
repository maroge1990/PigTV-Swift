import Foundation

// D-44 (R5-League/Cricket/Motor/Golf/Tennis/UFC-iPhone, #177, #186): a sport's page on the iPhone follows the front
// page's pattern. Under the header ("‹ Sport", the sport, whether scores show) the sport's leagues as chips (when it has
// more than one), a 212 pt carousel of the selected league's games (yours, then live; with neither, the next to start),
// then its games as fixture rows in groups: Live, Later today, Coming up, Earlier. The extra content (a fixture league's
// rounds and standings, Formula 1's weekend, the cricket scoreboard and tour, a C-V league's leaderboard or card) is a
// page of its own behind a "Standings ›"-style header (#177: pages for the extra content, not one long scroll). Draws only
// what C-R sends; spoiler-free is applied by `SportPhoneLayout.row`/`card` (#192). Pure (tests `SportPhonePageTests`).

/// A group of the page's fixture rows ("Live", "Later today").
nonisolated struct SportPhonePageGroup: Equatable, Identifiable, Sendable {
    let title: String
    let rows: [SportFixtureRowModel]
    var id: String { title }
}

nonisolated enum SportPhonePageLayout {
    /// The carousel's limit (the dots stop at twelve).
    static let maxCards = 8

    /// The chips: the sport's leagues in the order sent; none for a sport of one league.
    static func chips(_ sport: String, in front: SportFront) -> [String] {
        let leagues = SportPageRules.leagues(sport, in: front).map(\.league)
        return leagues.count > 1 ? leagues : []
    }

    /// The league the page opens on: the chosen one while it is still the sport's, else the hero's (SportPageRules).
    static func league(_ sport: String, chosen: String?, in front: SportFront) -> String? {
        let leagues = SportPageRules.leagues(sport, in: front).map(\.league)
        if let chosen, leagues.contains(chosen) { return chosen }
        return SportPageRules.openingLeague(sport, in: front, hero: SportPageRules.hero(sport, in: front))
    }

    /// The carousel: the league's followed games (the follows in the order sent, #215), then its other games on now,
    /// each once; with none of those, the next game to start. A follow's card records that follow's team (#49).
    static func cards(league: String, in front: SportFront, hidden: Bool, now: Date, labels: [String: String] = [:],
                      calendar: Calendar = .current) -> [SportPhoneCard] {
        let label = SportLabels.label(league, in: labels).uppercased()
        let names = front.follows.map(\.name)
        var seen = Set<String>()
        var cards: [SportPhoneCard] = []
        for (index, follow) in front.follows.enumerated() where follow.league == league {
            guard let game = front.game(follow.gameId), !game.terminal, seen.insert(game.id).inserted else { continue }
            cards.append(SportPhoneLayout.card(game, in: front, hidden: hidden, now: now, index: index, id: follow.key,
                                               league: label, follow: (name: follow.name, logo: follow.cachedLogo),
                                               follows: [follow.name], calendar: calendar))
        }
        let games = SportPageRules.games(league: league, in: front)
        for game in games where SportFrontText.showsLive(game) && seen.insert(game.id).inserted {
            cards.append(SportPhoneLayout.card(game, in: front, hidden: hidden, now: now, index: -1, id: game.id,
                                               league: label, follow: nil, follows: names, calendar: calendar))
        }
        if cards.isEmpty, let next = games.filter({ $0.status == "scheduled" }).min(by: { $0.start < $1.start }) {
            cards.append(SportPhoneLayout.card(next, in: front, hidden: hidden, now: now, index: -1, id: next.id,
                                               league: label, follow: nil, follows: names, calendar: calendar))
        }
        return Array(cards.prefix(maxCards))
    }

    /// "1 of 4" (Mark, 14 Nov 2026: no "· yours, then live").
    static func position(_ index: Int, of count: Int) -> String {
        "\(min(index + 1, count)) of \(count)"
    }

    /// The league's games as fixture rows: Live, Later today, Coming up (later days, and the next round), Earlier
    /// (results, newest first); a group with none is left out.
    static func groups(league: String, in front: SportFront, hidden: Bool, now: Date,
                       calendar: Calendar = .current) -> [SportPhonePageGroup] {
        let names = front.follows.map(\.name)
        let games = SportPageRules.games(league: league, in: front)
        func rows(_ list: [SportsGame]) -> [SportFixtureRowModel] {
            list.map { SportPhoneLayout.row($0, in: front, hidden: hidden, now: now, follows: names, calendar: calendar) }
        }
        let live = games.filter { SportFrontText.showsLive($0) }
        let ended = games.filter { $0.terminal }.sorted { $0.start > $1.start }
        let upcoming = games.filter { !$0.terminal && !SportFrontText.showsLive($0) }.sorted { $0.start < $1.start }
        let today = upcoming.filter { !SportFrontText.isNextRound($0) && calendar.isDate(SportFrontText.date($0.start), inSameDayAs: now) }
        let later = upcoming.filter { game in !today.contains { $0.id == game.id } }
        return [("Live", live), ("Later today", today), ("Coming up", later), ("Earlier", ended)]
            .filter { !$0.1.isEmpty }
            .map { SportPhonePageGroup(title: $0.0, rows: rows($0.1)) }
    }

    /// The header of the league's own page (#177), by what the league shows below the TV banner; nil: no page beyond
    /// its games (a league without a server page).
    static func moreTitle(_ content: SportPageRules.LeagueContent, sport: String) -> String? {
        switch content {
        case .nfl, .league: return "Rounds and standings"
        case .f1: return "Weekend and standings"
        case .cricket: return "Scoreboard and tour"
        case .events:
            switch sport {
            case "Golf": return "Leaderboard"
            case "Tennis": return "Order of play"
            case "Combat": return "Fight card"
            default: return "Events"
            }
        case .motorCards, .games: return nil
        }
    }
}
