import Foundation

// D-43 (1 Nov, mock-ups V2-Motor-1 and V2-Motor-4): the Motorsport page's leagues under the banner. Formula 1 (C-P):
// the weekend's sessions as tiles plus a circuit-stats tile, then the starting grid (or the last race) and the drivers'
// and constructors' standings side by side, ten each; spoiler-free (and while the account's choice is not known yet)
// hides the session results, the grid and the standings. MotoGP and Supercars (C-R cards only): their sessions or
// weekend cards in the same tile row, nothing else. IndyCar and NASCAR (C-V `race`): the entry list (alphabetical), the
// last winner and the next race; no standings and no running order. Pure (tests `SportMotorTests`).

nonisolated enum SportMotorText {
    struct Tile: Equatable, Identifiable, Sendable {
        enum State: Equatable, Sendable { case live, next, done, later }
        /// The session's id ("practice 1", "race").
        var id: String
        var title: String
        var when: Date
        var state: State
        /// "Fastest · Leclerc", "Pole · Antonelli", "Winner · Norris"; "Finished" with spoilers hidden; "On now" live;
        /// "On air · starts 3:10 pm" while the coverage is on before the session (#203).
        var line: String?
        /// The live pill's word: "LIVE", or "ON AIR" before the session (#203: the live dot, never as live).
        var liveWord: String = "LIVE"
    }

    /// The weekend's sessions as tiles, in order (five on a weekend; six on a sprint weekend's older shape).
    static func tiles(_ weekend: F1Weekend, now: Date, spoilerFree: Bool) -> [Tile] {
        weekend.sessions.map { session in
            switch F1PageText.pill(session, in: weekend, now: now, spoilerFree: spoilerFree) {
            case .live: return Tile(id: session.id, title: session.name, when: session.start, state: .live, line: "On now")
            case .onAir:
                return Tile(id: session.id, title: session.name, when: session.start, state: .live,
                            line: F1PageText.onAirLine(session), liveWord: "ON AIR")
            case .next: return Tile(id: session.id, title: session.name, when: session.start, state: .next, line: nil)
            case .done(let text): return Tile(id: session.id, title: session.name, when: session.start, state: .done, line: text)
            case .none: return Tile(id: session.id, title: session.name, when: session.start, state: .later, line: nil)
            }
        }
    }

    struct ListRow: Equatable, Sendable {
        var pos: Int
        var name: String
        /// The team (grid and drivers), else nil.
        var detail: String?
        var teamColor: String?
        var points: String?
        var followed: Bool
    }

    struct Lists: Equatable, Sendable {
        /// "Starting grid", "Last race · Mexico City GP"; nil without results.
        var gridTitle: String?
        var grid: [ListRow]
        var drivers: [ListRow]
        var constructors: [ListRow]
        /// "After round 20".
        var standingsNote: String?
        /// Spoiler-free (or the choice not known yet): every list is hidden.
        var hidden: Bool
    }

    /// The three lists, ten rows each. `followed`: the account's followed drivers (exact names, any case).
    static func lists(_ page: F1Page, followed: [String], spoilerFree: Bool) -> Lists {
        let wanted = Set(followed.map { $0.lowercased() })
        let grid = (page.results?.rows ?? []).prefix(10).map {
            ListRow(pos: $0.pos, name: $0.driver, detail: $0.team, teamColor: $0.teamColor, points: nil,
                    followed: wanted.contains($0.driver.lowercased()))
        }
        let drivers = (page.standings?.drivers ?? []).prefix(10).map {
            ListRow(pos: $0.pos, name: $0.name, detail: $0.team, teamColor: $0.teamColor, points: F1PageText.points($0.points),
                    followed: wanted.contains($0.name.lowercased()))
        }
        let constructors = (page.standings?.constructors ?? []).prefix(10).map {
            ListRow(pos: $0.pos, name: $0.name, detail: nil, teamColor: $0.teamColor, points: F1PageText.points($0.points),
                    followed: false)
        }
        let title = page.results.map { $0.kind == "grid" ? "Starting grid" : $0.title }
        let note = page.standings?.afterRound.map { "After round \($0)" }
        guard !spoilerFree else {
            return Lists(gridTitle: title, grid: [], drivers: [], constructors: [], standingsNote: note, hidden: true)
        }
        return Lists(gridTitle: title, grid: Array(grid), drivers: Array(drivers), constructors: Array(constructors),
                     standingsNote: note, hidden: false)
    }

    /// The account's followed F1 drivers: the sport's names (C-U, under any of its leagues) and the older single follow.
    static func followedDrivers(_ preferences: SportPagePreferences) -> [String] {
        var out = preferences.teams["F1"] ?? []
        if let one = preferences.f1Following, !out.contains(one) { out.append(one) }
        return out
    }

    /// MotoGP and Supercars, whose feeds have only C-R cards: the league's cards in start order, at most six.
    static func cardTiles(_ games: [SportsGame]) -> [SportsGame] {
        Array(games.sorted { $0.start < $1.start }.prefix(6))
    }

    /// "Mon 9 Nov · 7:00 am".
    static func nextLine(_ next: SportEventsPage.Next?) -> String? {
        guard let start = next?.start else { return nil }
        return F1PageText.when(SportFrontText.date(start))
    }
}
