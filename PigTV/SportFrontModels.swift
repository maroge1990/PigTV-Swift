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

    /// The empty state's help: Settings › Sport when the server has per-account follows (C-U), else the web app.
    static func followHelp(settings: Bool) -> String {
        settings
            ? "Choose the sports, leagues and teams you follow in Settings › Sport. They appear here on every device."
            : "Choose the sports, teams and drivers you follow in the PigTV web app, under Settings → Sports."
    }

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

    /// #204: the channels Record offers for a game: every channel carrying it, best first (the server's order), each
    /// on its own airing (C-I #20); one whose airing has ended is left out.
    static func recordChoices(_ event: SportEvent, now: Date) -> [SportEventChannel] {
        event.channels.filter { SportRows.channelAction(event, on: $0, now: now) != .ended }
    }

    /// "Fox Footy · 7:30 pm – 10:30 pm" (another day: "Sat 7:30 pm – …"): the channel's own times, under the dialog's
    /// "Record on which channel?" (short enough for a focused tvOS button).
    static func recordChoiceLabel(_ event: SportEvent, on channel: SportEventChannel, now: Date,
                                  calendar: Calendar = .current) -> String {
        let end = event.end(on: channel).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
        return "\(channel.name) · \(when(event.start(on: channel), now: now, calendar: calendar)) – \(end)"
    }

    enum Action: Equatable { case watch, remind, details, none }
    /// What selecting a card does: Watch only while its channel airs it now (that channel's own `start`/`end`, C-R; a
    /// cached `canWatch` never outlasts them, as an answer may be minutes old or kept after a failed refresh), Remind me
    /// before, the details (Record, the channels) otherwise. Called again at the moment of the press (`playable`).
    static func action(_ game: SportsGame, now: Date) -> Action {
        guard !game.terminal, let event = event(game), let best = event.best else { return .none }
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
        case .none: return game.terminal ? "" : "Not on your channels"
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

    /// The monogram disc's colour by league (hex), when a badge has no logo.
    static func leagueColor(_ league: String) -> String {
        ["NFL": "013369", "F1": "E10600", "NBA": "C9082A", "AFL": "0B3D91", "AFLW": "0B3D91", "Cricket": "1F7A3A",
         "EPL": "3D195B", "MLB": "041E42", "NRL": "00A651"][league] ?? "5A5466"
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
    static func headerLine(_ section: Section, in front: SportFront, now: Date, calendar: Calendar = .current) -> String {
        let leagues = section.rails.map(\.league).filter { $0 != section.sport }
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

    /// Which competitor is a followed team (its name or the follow's, either ending the other: "Packers" in "Green Bay
    /// Packers"), for the card's star; nil when none matches.
    static func followedSide(_ game: SportsGame, names: [String]) -> Int? {
        let wanted = names.map { $0.lowercased() }
        return game.competitors.firstIndex { competitor in
            let name = competitor.name.lowercased()
            return wanted.contains { $0 == name || $0.hasSuffix(" " + name) || name.hasSuffix(" " + $0) }
        }
    }

    /// The hero's words in the banner. `hidden`: spoiler-free (the answer's or the preference): no score, no situation.
    static func hero(_ game: SportsGame, in front: SportFront, hidden: Bool, now: Date,
                     calendar: Calendar = .current) -> SportBannerHero {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let sport = sport(of: game.league, in: front)
        var kicker = [drawn.kicker]
        if sport.caseInsensitiveCompare(game.league) != .orderedSame { kicker.append(sport.uppercased()) }
        kicker.append(game.league.uppercased())
        if game.followed == true { kicker.append("YOUR TEAM") }
        var line: [String] = []
        if let scores = drawn.scores, scores.count == 2 { line.append(scores.joined(separator: "–")) }
        if let situation = drawn.situation { line.append(situation) }
        if game.status == "scheduled" {
            let when = SportFrontText.when(SportFrontText.date(game.start), now: now, calendar: calendar)
            line.append(game.session.map { "\($0) · \(when)" } ?? when)
        }
        line.append(game.channels.first?.name ?? (game.terminal ? game.availabilityLabel : "No TV listing found"))
        return SportBannerHero(kicker: kicker.joined(separator: " · "), live: drawn.kicker == "LIVE",
                               title: game.title, line: line.joined(separator: " · "))
    }
}
