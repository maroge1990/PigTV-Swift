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
        /// C-U since 0391: the league's sport ("Football"); nil from an older server.
        var sport: String? = nil
        /// The sport the league belongs to: the server's, else the league itself (an older server).
        var sportName: String { sport ?? league }

        struct Next: Decodable, Equatable, Sendable {
            let gameId: String
            let start: Double
        }

        enum CodingKeys: String, CodingKey { case league, live, next, line, sport }

        init(league: String, live: Int, next: Next?, line: String, sport: String? = nil) {
            self.league = league; self.live = live; self.next = next; self.line = line; self.sport = sport
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            league = try c.decode(String.self, forKey: .league)
            live = ((try? c.decodeIfPresent(Int.self, forKey: .live)) ?? nil) ?? 0
            next = (try? c.decodeIfPresent(Next.self, forKey: .next)) ?? nil
            line = ((try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil) ?? "quiet"
            sport = ((try? c.decodeIfPresent(String.self, forKey: .sport)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
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
        /// C-U since 0391: the follow's sport; nil from an older server.
        var sport: String? = nil
        var sportName: String { sport ?? league }

        var key: String { "\(league)|\(name)" }
        /// Only cached same-server logos (as `SportsGame.Competitor.cachedLogo`).
        var cachedLogo: String? {
            logo.flatMap { $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil }
        }

        enum CodingKeys: String, CodingKey { case league, name, logo, state, gameId, start, sport }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            league = try c.decode(String.self, forKey: .league)
            name = try c.decode(String.self, forKey: .name)
            logo = ((try? c.decodeIfPresent(String.self, forKey: .logo)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "none"
            gameId = (try? c.decodeIfPresent(String.self, forKey: .gameId)) ?? nil
            start = (try? c.decodeIfPresent(Double.self, forKey: .start)) ?? nil
            sport = ((try? c.decodeIfPresent(String.self, forKey: .sport)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
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
        /// C-U since 0391: the league's sport; nil from an older server.
        var sport: String? = nil
        var sportName: String { sport ?? league }

        enum CodingKeys: String, CodingKey { case league, gameIds, sport }

        init(league: String, gameIds: [String], sport: String? = nil) {
            self.league = league; self.gameIds = gameIds; self.sport = sport
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            league = try c.decode(String.self, forKey: .league)
            gameIds = ((try? c.decodeIfPresent([String].self, forKey: .gameIds)) ?? nil) ?? []
            sport = ((try? c.decodeIfPresent(String.self, forKey: .sport)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        }
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
    /// #261 (187): a game under way, or not over and within an hour of its start: the page re-asks every 20 s, so a game
    /// going live shows within seconds of the server having it (not after a 60 s wait for the first live answer).
    func wantsFastRefresh(at now: Date) -> Bool {
        let ms = now.timeIntervalSince1970 * 1000
        return games.contains { SportFrontHero.ongoing.contains($0.status) || (!$0.terminal && abs($0.start - ms) <= 3_600_000) }
    }
}

/// Which game the hero band shows. The server proposes one (`hero`); the client keeps the hero it shows until its game
/// is no longer under way, unless a follow goes live (then that follow takes it); a viewer's own choice (a flip in the
/// follows list, or a long press "Make this the hero") wins over both while its game is on the page (C-R, D-39).
nonisolated enum SportFrontHero {
    /// Statuses during which a hero stays put.
    static let ongoing: Set<String> = SportStatus.underWayStatuses

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

/// #278 (audit D5): the one answer to "are scores hidden on this screen?". Every sport screen asks it here, with what it
/// knows: `preference`, the account's preference as the sport pages hold it (`F1PageModel.hidesSpoilers`: unknown counts
/// as hidden); `answer`, the front answer's own `spoilerFree` (nil before there is an answer, which adds nothing by
/// itself: the preference is already hidden while unknown); `page`, the decision a parent page passed down (the
/// `sportHidesSpoilers` environment value, or a `hidden:` parameter). Any one saying hidden hides: a mistake here shows a
/// score the household asked not to see. `PigTVTests/SportSpoilersTests` checks no screen combines these inputs itself.
nonisolated enum SportSpoilers {
    static func hidden(preference: Bool, answer: Bool?, page: Bool) -> Bool {
        if preference { return true }
        if answer == true { return true }
        return page
    }
}

/// What the front page says. Pure.
nonisolated enum SportFrontText {
    static let scoresUnavailable = "The scores feed isn’t available right now. The guide’s channels and times are shown."

    /// The empty state's help: Settings › Sport when the server has per-account follows (C-U), else the web app.
    static func followHelp(settings: Bool) -> String {
        settings
            ? "Choose the sports, leagues and teams you follow in Settings › Sport. They appear here on every device."
            : "Choose the sports, teams and drivers you follow in the PigTV web app, under Settings › Sport."
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

    /// #218: a game of a weekly league's next round (C-R `nextRound`, past the 72 hours).
    static func isNextRound(_ game: SportsGame) -> Bool { game.nextRound == true && game.status == "scheduled" }

    /// When a game starts: "5:30 pm", "Sat 5:30 pm", or for a next-round game "Next round · Sat 15 Nov" (#218).
    static func startLine(_ game: SportsGame, now: Date, calendar: Calendar = .current) -> String {
        let date = date(game.start)
        guard isNextRound(game) else { return when(date, now: now, calendar: calendar) }
        return "Next round · \(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).day().month(.abbreviated)))"
    }

    /// The channel words beside a game: its best channel, "No TV listing found" for a game to come without one, nothing
    /// for a result or a next-round game (#218: the guide does not reach that far; no channel is drawn).
    static func channelLine(_ game: SportsGame) -> String {
        if isNextRound(game) { return "" }
        return game.channels.first?.name ?? (game.terminal ? "" : "No TV listing found")
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
        // `hidden` is the caller's decision (it already holds the preference); the answer's own switch still hides here.
        let hide = SportSpoilers.hidden(preference: false, answer: front.spoilerFree, page: hidden)
        let feed = !front.scoresUnavailable
        return Drawn(scores: feed ? scores(game, spoilerFree: hide) : nil,
                     situation: feed ? situation(game, spoilerFree: hide) : nil,
                     kicker: kicker(game), status: game.statusLabel)
    }

    /// #211: a live card's short clock: "Q4 0:17", "OT1 10:00", "2nd half 67'", "Top 5"; never the situation (the
    /// banner's line has it). The status ("LIVE", "HT") without the scores feed or a fresh clock.
    static func cardClock(_ game: SportsGame, in front: SportFront, hidden: Bool) -> String {
        guard !front.scoresUnavailable, game.freshness == "fresh", game.family != .motorsport else { return game.statusLabel }
        var parts: [String] = []
        if let period = game.progress.period, period > 0 {
            switch game.family {
            case .americanFootball, .basketball: parts.append(period <= 4 ? "Q\(period)" : "OT\(period - 4)")
            case .australianFootball: parts.append(period <= 4 ? "Q\(period)" : "ET\(period - 4)")
            case .football: parts.append([1: "1st half", 2: "2nd half", 3: "ET 1st", 4: "ET 2nd", 5: "Pens"][period] ?? "P\(period)")
            case .baseball: parts.append("\(game.progress.half?.capitalized ?? "Inn") \(period)")
            default: break
            }
        }
        if game.family == .cricket { return situation(game, spoilerFree: hidden) ?? game.statusLabel }
        if let clock = game.progress.clock { parts.append(clock) }
        return parts.isEmpty ? game.statusLabel : parts.joined(separator: " ")
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

    /// #204: the channels Record offers for a game: every channel carrying it, best first (the server's order), each
    /// on its own airing (C-I #20); one whose airing has ended is left out.
    static func recordChoices(_ event: SportEvent, now: Date) -> [SportEventChannel] {
        event.channels.filter { SportRows.channelAction(event, on: $0, now: now) != .ended }
    }

    enum Action: Equatable { case watch, remind, details, none }
    /// What selecting a card does: Watch only while its channel airs it now (that channel's own `start`/`end`, C-R; a
    /// cached `canWatch` never outlasts them, as an answer may be minutes old or kept after a failed refresh), Remind me
    /// before, the details (Record, the channels) otherwise. Called again at the moment of the press (`playable`).
    static func action(_ game: SportsGame, now: Date) -> Action {
        // #218: a next round is days away and drawn without a channel: nothing to watch or be reminded of yet.
        guard !game.terminal, !isNextRound(game), let event = event(game), let best = event.best else { return .none }
        if event.isLive(on: best, at: now) { return .watch }
        return event.start(on: best) > now ? .remind : .details
    }

    /// The event to play if the game's channel airs it at `now`, else nil (open the details instead). Checked when
    /// Watch is pressed, never from what was drawn.
    static func playable(_ game: SportsGame, at now: Date) -> SportEvent? {
        action(game, now: now) == .watch ? event(game) : nil
    }

    static func actionLabel(_ game: SportsGame, now: Date) -> String {
        switch action(game, now: now) {
        case .watch: return "Watch"
        case .remind: return "Remind me"
        case .details: return "Details"
        case .none: return game.terminal || isNextRound(game) ? "" : "Not on your channels"
        }
    }

    /// A badge draws its logo only once the logo has loaded; without one, while loading, or after a failed load it
    /// draws the monogram disc.
    static func badgeShowsLogo(logo: String?, decoded: Bool) -> Bool { logo != nil && decoded }

    /// "Green Bay Packers" → "GP", "Bears" → "B".
    static func monogram(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// The monogram disc's colour by league, when a badge has no logo: a named colour in the catalogue (#280; they were
    /// typed in here as hex). Each keeps its white letters at 4.5:1 or more in light and dark (BrandRulesTests); NRL's
    /// green is darkened from 00A651 (3.2:1) to 00843F (4.8:1).
    static func leagueColorName(_ league: String) -> String {
        ["NFL": "LeagueNFL", "F1": "LeagueF1", "NBA": "LeagueNBA", "AFL": "LeagueAFL", "AFLW": "LeagueAFL",
         "Cricket": "LeagueCricket", "EPL": "LeagueEPL", "MLB": "LeagueMLB", "NRL": "LeagueNRL"][league] ?? "LeagueOther"
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

/// D-43 (1 Nov): the Apple TV front page's layout, from the answer. Pure (tests `SportFrontLayoutTests`). Everything keeps
/// the server's order (C-R since 0427: the account's order, anything playing now first); nothing is re-sorted here.
nonisolated enum SportFrontLayout {
    /// A sport's rails under one header ("Football ›"): its leagues' rails in the server's order.
    struct Section: Equatable, Identifiable, Sendable {
        let sport: String
        let rails: [SportFront.Rail]
        var id: String { sport }
    }

    /// One section per sport that has a rail with a game, in the order its first rail comes (rails put the leagues
    /// with a game on now first); a rail whose ids match no card counts as no rail.
    static func sections(_ front: SportFront) -> [Section] {
        var order: [String] = []
        var rails: [String: [SportFront.Rail]] = [:]
        for rail in front.rails where !front.games(in: rail).isEmpty {
            let sport = sport(of: rail.league, railSport: rail.sport, in: front)
            if rails[sport] == nil { order.append(sport) }
            rails[sport, default: []].append(rail)
        }
        return order.map { Section(sport: $0, rails: rails[$0] ?? []) }
    }

    /// "Also in your sports": the followed sports with nothing in the next 72 hours (no rail), in the server's order.
    static func alsoInYourSports(_ front: SportFront) -> [String] {
        let shown = Set(sections(front).map(\.sport))
        return sports(front).filter { !shown.contains($0) }
    }

    /// Every followed sport once, in the order of `sports[]` (then any only a rail names).
    static func sports(_ front: SportFront) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in front.sports.map(\.sportName) + front.rails.map({ sport(of: $0.league, railSport: $0.sport, in: front) })
        where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    /// The sport a league belongs to: the rail's own, else its `sports[]` entry's, else the league itself.
    static func sport(of league: String, railSport: String? = nil, in front: SportFront) -> String {
        railSport ?? front.sports.first { $0.league == league }?.sport ?? league
    }

    /// A section header's line: "EPL · 2 live", "F1 · Mon 7:00 am" (its leagues, then live or the next start).
    static func headerLine(_ section: Section, in front: SportFront, now: Date, labels: [String: String] = [:],
                           calendar: Calendar = .current) -> String {
        let leagues = section.rails.map(\.league).filter { $0 != section.sport }.map { SportLabels.label($0, in: labels) }
        let entries = front.sports.filter { $0.sportName == section.sport }
        let live = entries.reduce(0) { $0 + $1.live }
        var parts = leagues.isEmpty ? [] : [leagues.joined(separator: ", ")]
        if live > 0 {
            parts.append("\(live) live")
        } else if let next = entries.compactMap(\.next).map(\.start).min() {
            parts.append(SportFrontText.when(SportFrontText.date(next), now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    /// An "Also in your sports" button's line: the next start when the server has one, else nothing.
    static func alsoLine(_ sport: String, in front: SportFront, now: Date, calendar: Calendar = .current) -> String? {
        front.sports.filter { $0.sportName == sport }.compactMap(\.next).map(\.start).min()
            .map { SportFrontText.when(SportFrontText.date($0), now: now, calendar: calendar) }
    }

    /// The banner's list on the front page: the follows in the server's order.
    static func followItems(_ front: SportFront, now: Date, calendar: Calendar = .current) -> [SportBannerItem] {
        front.follows.map { follow in
            SportBannerItem(id: follow.key, title: follow.name,
                            trailing: followTrailing(follow, in: front, now: now, calendar: calendar),
                            live: follow.state == "live",
                            badge: .init(name: follow.name, logo: follow.cachedLogo, league: follow.league))
        }
    }

    /// A follow row's right-hand words: "LIVE · v Man City", "Race · Mon 7:00 am", "Mon 5:00 am", "Nothing in 3 days".
    static func followTrailing(_ follow: SportFront.Follow, in front: SportFront, now: Date,
                               calendar: Calendar = .current) -> String {
        let game = front.game(follow.gameId)
        switch follow.state {
        case "live":
            guard let game, let other = opponent(of: follow, in: game) else { return "LIVE" }
            return "LIVE · v \(other)"
        case "next":
            guard let start = follow.start ?? game?.start else { return "Next" }
            if let game, SportFrontText.isNextRound(game) { return SportFrontText.startLine(game, now: now, calendar: calendar) }
            let when = SportFrontText.when(SportFrontText.date(start), now: now, calendar: calendar)
            return game?.session.map { "\($0) · \(when)" } ?? when
        default:
            return "Nothing in 3 days"
        }
    }

    /// The other side of a two-sided game, when the follow is one of them.
    static func opponent(of follow: SportFront.Follow, in game: SportsGame) -> String? {
        guard game.competitors.count == 2, let mine = followedSide(game, names: [follow.name]) else { return nil }
        return game.competitors[1 - mine].name
    }

    /// Every competitor that is a followed team (both, when the account follows both sides).
    static func followedSides(_ game: SportsGame, names: [String]) -> [Int] {
        // #249: the server's own match when it sends one; names only for an older server.
        if let sides = game.followedSides { return sides.filter { game.competitors.indices.contains($0) } }
        return game.competitors.indices.filter { matches(game.competitors[$0].name, names: names) }
    }

    /// The sides a game card stars. #279 (Apple 202): on the television a followed card has no outline, so a followed
    /// two-sided game whose followed side cannot be told (a server before 0493 sends no `followedSides`, and the follow
    /// matched an alias the names here miss) stars its first line rather than nothing. Touch keeps its outline instead.
    static func cardStars(_ game: SportsGame, names: [String], firstWhenUnknown: Bool) -> (sides: [Int], unknown: Bool) {
        guard game.followed == true else { return ([], false) }
        let sides = followedSides(game, names: names)
        guard sides.isEmpty, firstWhenUnknown, !game.competitors.isEmpty else { return (sides, false) }
        return ([0], true)
    }

    private static func matches(_ competitor: String, names: [String]) -> Bool {
        let name = competitor.lowercased()
        return names.map { $0.lowercased() }.contains { $0 == name || $0.hasSuffix(" " + name) || name.hasSuffix(" " + $0) }
    }

    /// Which competitor is a followed team (its name or the follow's, either ending the other: "Packers" in "Green Bay
    /// Packers"), for the card's star; nil when none matches.
    static func followedSide(_ game: SportsGame, names: [String]) -> Int? {
        // #249: a name that matches decides (a follow's own side when both are followed); else the server's match
        // ("ARI" never ends "Arizona Cardinals"), but only when it names one side: with both followed it cannot say which
        // is this follow's (176 Codex round 1, high: Record from SEA's card would have offered ARI's rule).
        if let byName = game.competitors.firstIndex(where: { matches($0.name, names: names) }) { return byName }
        let sides = (game.followedSides ?? []).filter { game.competitors.indices.contains($0) }
        return sides.count == 1 ? sides[0] : nil
    }

    /// The hero's words in the banner. `hidden`: spoiler-free (the answer's or the preference): no score, no situation.
    /// `labels`: the catalogue's league labels (D-43: "PREMIER LEAGUE", not "EPL"); a followed name is "YOUR DRIVER",
    /// "YOUR PLAYER", "YOUR FIGHTER" or "YOUR TEAM" by sport.
    static func hero(_ game: SportsGame, in front: SportFront, hidden: Bool, now: Date, labels: [String: String] = [:],
                     calendar: Calendar = .current) -> SportBannerHero {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let sport = sport(of: game.league, in: front)
        let league = SportLabels.label(game.league, in: labels)
        var kicker = [drawn.kicker]
        if sport.caseInsensitiveCompare(game.league) != .orderedSame && sport.caseInsensitiveCompare(league) != .orderedSame {
            kicker.append(sport.uppercased())
        }
        kicker.append(league.uppercased())
        if game.followed == true { kicker.append(SportLabels.yours(sport: sport)) }
        var line: [String] = []
        if let scores = drawn.scores, scores.count == 2 { line.append(scores.joined(separator: "–")) }
        if let situation = drawn.situation { line.append(situation) }
        if game.status == "scheduled" {
            let when = SportFrontText.startLine(game, now: now, calendar: calendar)
            line.append(game.session.map { "\($0) · \(when)" } ?? when)
        }
        if !SportFrontText.isNextRound(game) {
            line.append(game.channels.first?.name ?? (game.terminal ? game.availabilityLabel : "No TV listing found"))
        }
        return SportBannerHero(kicker: kicker.joined(separator: " · "), live: drawn.kicker == "LIVE",
                               title: game.title, line: line.joined(separator: " · "))
    }
}
