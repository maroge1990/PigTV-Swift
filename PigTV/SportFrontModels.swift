import Foundation

// C-R (server 0381, flag `sportFront`; #21, D-39): the Sport front page, "Blend 1". `GET /api/sports/front` answers
// `{ now, timezone, spoilerFree, scores, sports, follows, hero, rails, games }`: the household's followed sports (the
// tiles), its followed teams and drivers (the flip list), the server's hero choice, one rail per followed sport (ids into
// `games`) and the C-O cards themselves (`SportsGame`, with `followed` and per-channel airing times). Decoding is
// tolerant: a sport, follow, rail or game that does not decode is dropped. What the page says and which game is the hero
// are pure (`SportFrontText`, `SportFrontHero`; tests `SportFrontTests`).

nonisolated struct SportFront: Decodable, Equatable, Sendable {
    struct Sport: Decodable, Equatable, Sendable {
        let league: String
        let live: Int
        let next: Next?
        /// "live" | "next" | "quiet" (the client words it).
        let line: String

        struct Next: Decodable, Equatable, Sendable {
            let gameId: String
            let start: Double
        }

        enum CodingKeys: String, CodingKey { case league, live, next, line }

        init(league: String, live: Int, next: Next?, line: String) {
            self.league = league; self.live = live; self.next = next; self.line = line
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            league = try c.decode(String.self, forKey: .league)
            live = ((try? c.decodeIfPresent(Int.self, forKey: .live)) ?? nil) ?? 0
            next = (try? c.decodeIfPresent(Next.self, forKey: .next)) ?? nil
            line = ((try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil) ?? "quiet"
        }
    }

    /// A followed team or driver.
    struct Follow: Decodable, Equatable, Sendable {
        let league: String
        let name: String
        let logo: String?
        /// "live" | "next" | "none".
        let state: String
        let gameId: String?
        let start: Double?

        var key: String { "\(league)|\(name)" }
        /// Only cached same-server logos (as `SportsGame.Competitor.cachedLogo`).
        var cachedLogo: String? {
            logo.flatMap { $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil }
        }

        enum CodingKeys: String, CodingKey { case league, name, logo, state, gameId, start }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            league = try c.decode(String.self, forKey: .league)
            name = try c.decode(String.self, forKey: .name)
            logo = ((try? c.decodeIfPresent(String.self, forKey: .logo)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "none"
            gameId = (try? c.decodeIfPresent(String.self, forKey: .gameId)) ?? nil
            start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? nil
        }
    }

    struct Hero: Decodable, Equatable, Sendable {
        /// "follow-live" | "league-live" | "follow-next" | "guide" | "none".
        let reason: String
        let followIndex: Int?
        let gameId: String?

        static let empty = Hero(reason: "none", followIndex: nil, gameId: nil)

        init(reason: String, followIndex: Int?, gameId: String?) {
            self.reason = reason; self.followIndex = followIndex; self.gameId = gameId
        }

        enum CodingKeys: String, CodingKey { case reason, followIndex, gameId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil) ?? "none"
            followIndex = (try? c.decodeIfPresent(Int.self, forKey: .followIndex)) ?? nil
            gameId = (try? c.decodeIfPresent(String.self, forKey: .gameId)) ?? nil
        }
    }

    struct Rail: Decodable, Equatable, Sendable {
        let league: String
        let gameIds: [String]
    }

    let now: Double
    let timezone: String?
    let spoilerFree: Bool
    /// "fresh" | "stale" | "unavailable".
    let scores: String
    let sports: [Sport]
    let follows: [Follow]
    let hero: Hero
    let rails: [Rail]
    let games: [SportsGame]

    enum CodingKeys: String, CodingKey { case now, timezone, spoilerFree, scores, sports, follows, hero, rails, games }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = ((try? c.decodeIfPresent(Double.self, forKey: .now)) ?? nil) ?? Date().timeIntervalSince1970 * 1000
        timezone = (try? c.decodeIfPresent(String.self, forKey: .timezone)) ?? nil
        spoilerFree = ((try? c.decodeIfPresent(Bool.self, forKey: .spoilerFree)) ?? nil) ?? false
        scores = ((try? c.decodeIfPresent(String.self, forKey: .scores)) ?? nil) ?? "unavailable"
        sports = ((try? c.decodeIfPresent(LossyList<Sport>.self, forKey: .sports)) ?? nil)?.items ?? []
        follows = ((try? c.decodeIfPresent(LossyList<Follow>.self, forKey: .follows)) ?? nil)?.items ?? []
        hero = ((try? c.decodeIfPresent(Hero.self, forKey: .hero)) ?? nil) ?? .empty
        rails = ((try? c.decodeIfPresent(LossyList<Rail>.self, forKey: .rails)) ?? nil)?.items ?? []
        games = ((try? c.decodeIfPresent(LossyList<SportsGame>.self, forKey: .games)) ?? nil)?.items ?? []
    }

    func game(_ id: String?) -> SportsGame? {
        guard let id else { return nil }
        return games.first { $0.id == id }
    }

    /// A rail's games in the server's order (live first, results, then upcoming); ids without a card are skipped.
    func games(in rail: Rail) -> [SportsGame] { rail.gameIds.compactMap { game($0) } }

    /// No score data at all: the page says so once and shows the guide's channels and times.
    var scoresUnavailable: Bool { scores == "unavailable" }
    /// Nothing followed: the page offers to follow a sport.
    var isEmpty: Bool { sports.isEmpty }
    /// A game is under way (live, at a break or suspended): the page polls faster.
    var hasLiveGame: Bool { games.contains { SportFrontHero.ongoing.contains($0.status) } }
}

/// Which game the hero band shows. The server proposes one (`hero`); the client keeps the hero it shows until its game
/// is no longer under way, unless a follow goes live (then that follow takes it); a viewer's own choice (a flip in the
/// follows list, or a long press "Make this the hero") wins over both while its game is on the page (C-R, D-39).
nonisolated enum SportFrontHero {
    /// Statuses during which a hero stays put.
    static let ongoing: Set<String> = ["live", "break", "suspended"]

    /// Follows (by index in `front`) that are live now and were not in `previous`. None on a first answer: the server's
    /// own hero already puts a live follow first.
    static func followsGoneLive(previous: SportFront?, front: SportFront) -> [Int] {
        guard let previous else { return [] }
        let before = Dictionary(previous.follows.map { ($0.key, $0.state) }, uniquingKeysWith: { first, _ in first })
        return front.follows.indices.filter { front.follows[$0].state == "live" && before[front.follows[$0].key] != "live" }
    }

    static func resolve(current: String?, front: SportFront, wentLive: [Int], selectedFollow: Int?,
                        pinned: String?) -> String? {
        if let pinned, front.game(pinned) != nil { return pinned }
        if let index = selectedFollow, front.follows.indices.contains(index),
           let id = front.follows[index].gameId, front.game(id) != nil {
            return id
        }
        if !wentLive.isEmpty {
            // The server's pick when it is one of them (closest to finishing), else the first in the household's order.
            if let index = front.hero.followIndex, wentLive.contains(index), let id = front.follows[index].gameId,
               front.game(id) != nil {
                return id
            }
            if let id = wentLive.lazy.compactMap({ front.follows[$0].gameId }).first(where: { front.game($0) != nil }) {
                return id
            }
        }
        if let current, let game = front.game(current), ongoing.contains(game.status) { return current }
        return front.game(front.hero.gameId)?.id
    }
}

/// What the front page says. Pure.
nonisolated enum SportFrontText {
    static let scoresUnavailable = "Live scores are not available right now. The guide's channels and times are shown."

    /// The tile's line: "Race live", "2 live", a start time, "Nothing scheduled".
    static func tileLine(_ sport: SportFront.Sport, in front: SportFront, now: Date, calendar: Calendar = .current) -> String {
        if sport.line == "live" || sport.live > 0 {
            if sport.league == "F1" {
                let session = front.games.first { $0.league == "F1" && SportFrontHero.ongoing.contains($0.status) }?.session
                return session.map { $0 == "Race" ? "Race live" : "\($0) live" } ?? "Race live"
            }
            return "\(max(sport.live, 1)) live"
        }
        if let next = sport.next { return when(date(next.start), now: now, calendar: calendar) }
        return "Nothing scheduled"
    }

    /// A follow's line: "Live · Packers v Bears", "Next · Sat 5:30 pm", "Nothing scheduled".
    static func followLine(_ follow: SportFront.Follow, in front: SportFront, now: Date, calendar: Calendar = .current) -> String {
        switch follow.state {
        case "live": return front.game(follow.gameId).map { "Live · \($0.title)" } ?? "Live"
        case "next":
            guard let start = follow.start ?? front.game(follow.gameId)?.start else { return "Next" }
            return "Next · \(when(date(start), now: now, calendar: calendar))"
        default: return "Nothing in the next three days"
        }
    }

    /// A compact row's when: "Live", "5:30 pm", "Sat 5:30 pm", "—".
    static func shortWhen(_ follow: SportFront.Follow, now: Date, calendar: Calendar = .current) -> String {
        switch follow.state {
        case "live": return "Live"
        case "next": return follow.start.map { when(date($0), now: now, calendar: calendar) } ?? "Next"
        default: return "—"
        }
    }

    /// The compact list's order (more than three follows): live first, then the soonest start (a next game without a
    /// start after those with one), then the rest, each in the household's order.
    static func compactOrder(_ follows: [SportFront.Follow]) -> [Int] {
        func key(_ index: Int) -> (Int, Int, Double, Int) {
            let f = follows[index]
            let rank = f.state == "live" ? 0 : f.state == "next" ? 1 : 2
            let start = rank == 1 ? f.start : nil
            return (rank, rank == 1 && start == nil ? 1 : 0, start ?? 0, index)
        }
        return follows.indices.sorted { key($0) < key($1) }
    }

    /// "5:30 pm" today, else "Sat 5:30 pm" (the device's zone, as the sport pages).
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(formatter.string(from: date)) \(time)"
    }

    /// The hero's kicker word.
    static func kicker(_ game: SportsGame) -> String {
        switch game.status {
        case "live", "break", "suspended": return "LIVE"
        case "scheduled": return "NEXT"
        case "finished": return "FINAL"
        default: return game.broadcastStatus == "on-tv" ? "ON TV" : "NEXT"
        }
    }

    /// What a card or the hero draws of a game's state. `hidden`: the household is spoiler-free (the answer's own
    /// switch, or the preference as this device last read it).
    struct Drawn: Equatable {
        /// One per competitor, or nil.
        let scores: [String]?
        /// Neutral progress, then the situation unless hidden.
        let situation: String?
        /// The hero's kicker ("LIVE", "NEXT", "FINAL", "ON TV").
        let kicker: String
        /// A card's status pill.
        let status: String
    }

    static func drawn(_ game: SportsGame, in front: SportFront, hidden: Bool) -> Drawn {
        // Without the scores feed nothing is shown of a score or a clock (C-R): the guide's channel and times only.
        let hide = hidden || front.spoilerFree
        let feed = !front.scoresUnavailable
        return Drawn(scores: feed ? scores(game, spoilerFree: hide) : nil,
                     situation: feed ? situation(game, spoilerFree: hide) : nil,
                     kicker: kicker(game), status: game.statusLabel)
    }

    /// Scores to draw, one per competitor, or nil (spoiler-free, stale or not a two-sided game).
    static func scores(_ game: SportsGame, spoilerFree: Bool) -> [String]? { game.visibleScores(hidden: spoilerFree) }

    /// Neutral progress ("Quarter 2 · 5:00"), then the situation unless spoiler-free.
    static func situation(_ game: SportsGame, spoilerFree: Bool) -> String? {
        let parts = [game.progressLabel(), game.situationLabel(hidden: spoilerFree) ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The game as a C-I event on its channels (Watch, Record, Remind me), each channel on its own airing (#20); nil
    /// without a channel.
    static func event(_ game: SportsGame) -> SportEvent? {
        guard let best = game.channels.first else { return nil }
        let airing = game.events.first
        let start = best.startTime ?? airing?.start ?? game.start
        let end = best.endTime ?? airing?.end ?? game.end ?? (start + 3 * 3600 * 1000)
        return SportEvent(id: airing?.id ?? game.id, title: game.title, league: game.league, startTime: start,
                          endTime: max(end, start + 60_000), channels: game.channels)
    }

    enum Action: Equatable { case watch, remind, details, none }
    /// What selecting a card does: Watch while it is on a channel now, Remind me before, the details otherwise.
    static func action(_ game: SportsGame, now: Date) -> Action {
        guard !game.terminal, let event = event(game) else { return .none }
        if SportFrontHero.ongoing.contains(game.status) || game.broadcastStatus == "on-tv" {
            return game.canWatch || event.isLive(at: now) ? .watch : .details
        }
        return event.start > now ? .remind : .details
    }

    static func actionLabel(_ game: SportsGame, now: Date) -> String {
        switch action(game, now: now) {
        case .watch: return "Watch"
        case .remind: return "Remind me"
        case .details: return "Details"
        case .none: return game.terminal ? "" : "Not on your channels"
        }
    }

    /// "Green Bay Packers" → "GP", "Bears" → "B".
    static func monogram(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// The monogram disc's colour by league (hex), when a badge has no logo.
    static func leagueColor(_ league: String) -> String {
        ["NFL": "013369", "F1": "E10600", "NBA": "C9082A", "AFL": "0B3D91", "AFLW": "0B3D91", "Cricket": "1F7A3A",
         "EPL": "3D195B", "MLB": "041E42", "NRL": "00A651"][league] ?? "5A5466"
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
