import Foundation

// D-44 (R5-Front-iPhone, Apple 139): the iPhone Sport front page from C-R. Under the header a 212 pt carousel of the
// follows (in the order sent: playing now, then the next to start, #215), one card each; then one card per sport under
// its "Football ›" header, each game a fixture row: logo · Team v Team · logo on the left, the score on the right, the
// state, time and channel on a second line (#205, #213: the cached `/api/logo/` badges, a monogram only without one).
// Spoiler-free (the answer's or the account's, unknown counts as on: #192) hides every score, in the words and in what
// VoiceOver reads. Pure (tests `SportPhoneLayoutTests`).

/// One game as a fixture row, spoiler-free already applied.
nonisolated struct SportFixtureRowModel: Equatable, Identifiable, Sendable {
    struct Side: Equatable, Sendable {
        let name: String
        let logo: String?
        let followed: Bool
    }

    let id: String
    let league: String
    /// Two sides for a game of two; empty for a session or an event (then `title`).
    let sides: [Side]
    /// "Practice 3", "Mexico City Grand Prix": a game without two sides.
    let title: String
    /// The square kicker badge of a session row ("F1"); nil for a game of two.
    let badge: String?
    /// "1–1"; nil before the start, without the scores feed, or with spoilers hidden.
    let score: String?
    /// "LIVE 55'" (the red part of the second line) while it is on, else nil.
    let live: String?
    /// "Optus Sport 2 HD", "4:30 am · Optus Sport 1 HD", "Next round · Sat 15 Nov", "Final".
    let sub: String
    /// What VoiceOver reads: never a hidden score.
    let accessibilityLabel: String
    /// #254 (Mark, 8 Nov: the short score in the middle): what is drawn, "245/6–180/3", "60–47"; `score` stays whole
    /// for VoiceOver. Nil when `score` is.
    var shortScore: String? = nil
    /// The rest of the score, small under the short one on a card: "48.2 ov – 31.4 ov", "9.6 – 7.5".
    var scoreDetail: String? = nil
}

/// #254: a long score ("245/6 (48.2)", AFL's "9.6 (60)") split into what fits between two names and the rest.
nonisolated enum SportScoreText {
    /// One side's score: (main, detail). Cricket keeps runs/wickets and moves the overs; AFL shows its total points
    /// and moves goals.behinds; anything else is shown whole.
    static func split(_ score: String) -> (main: String, detail: String?) {
        let text = score.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, nil) }
        let head = text[..<open].trimmingCharacters(in: .whitespaces)
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !inner.isEmpty else { return (text, nil) }
        let isNumber = { (s: String) in !s.isEmpty && s.allSatisfy(\.isNumber) }
        let goalsBehinds = head.split(separator: ".").count == 2 && head.split(separator: ".").allSatisfy { isNumber(String($0)) }
        if goalsBehinds && isNumber(inner) { return (inner, head) }
        if inner.hasSuffix("ov") { return (head, inner) }
        if inner.allSatisfy({ $0.isNumber || $0 == "." }) { return (head, "\(inner) ov") }
        return (head, inner)
    }

    /// Two sides' scores: the short score and its detail (nil when nothing was moved).
    static func short(_ scores: [String]) -> (main: String, detail: String?) {
        let parts = scores.map(split)
        let details = parts.compactMap(\.detail)
        return (parts.map(\.main).joined(separator: "–"), details.isEmpty ? nil : details.joined(separator: " – "))
    }
}

/// A follow in the carousel.
nonisolated struct SportPhoneCard: Equatable, Identifiable, Sendable {
    /// Its place in `follows[]` (what `SportFrontModel.select(follow:)` takes).
    let index: Int
    let id: String
    /// "LIVE · PREMIER LEAGUE", "NFL · MON 5:00 AM", "ATP TOUR".
    let kicker: String
    let live: Bool
    /// Two sides for a game of two (the followed one starred); else one badge, the follow's.
    let sides: [SportFixtureRowModel.Side]
    /// The game's title when it has no two sides ("Mexico City Grand Prix"), or the follow's name without a game.
    let title: String?
    /// The session under the title ("Race").
    let session: String?
    /// #254: the short score ("245/6–180/3"); VoiceOver reads the whole one.
    let score: String?
    /// "2nd half 67' · Optus Sport 1 HD", "Mon 5:00 am · Fox Sports 503 HD", "Nothing in the next three days".
    let line: String
    let gameId: String?
    /// #49: the follow this card is for: its team rules are this team's, never the other followed side's.
    let team: String
    let accessibilityLabel: String
    /// #254: the rest of the score, small under it ("48.2 ov – 31.4 ov").
    var scoreDetail: String? = nil
}

/// A sport's card: its header and its first games.
nonisolated struct SportPhoneGroup: Equatable, Identifiable, Sendable {
    let sport: String
    /// "Premier League · 1 live", "F1 · Mon 7:00 am".
    let note: String
    let rows: [SportFixtureRowModel]
    var id: String { sport }
}

nonisolated enum SportPhoneLayout {
    /// The rows a sport's card shows; its header opens the rest.
    static let rowsPerSport = 3

    static func card(_ index: Int, in front: SportFront, hidden: Bool, now: Date, labels: [String: String] = [:],
                     calendar: Calendar = .current) -> SportPhoneCard {
        let follow = front.follows[index]
        let league = SportLabels.label(follow.league, in: labels).uppercased()
        guard let game = front.game(follow.gameId) else {
            let line = "Nothing in the next three days"
            return SportPhoneCard(index: index, id: follow.key, kicker: league, live: false,
                                  sides: [.init(name: follow.name, logo: follow.cachedLogo, followed: true)],
                                  title: follow.name, session: nil, score: nil, line: line, gameId: nil, team: follow.name,
                                  accessibilityLabel: [follow.name, league, line].joined(separator: ", "))
        }
        return card(game, in: front, hidden: hidden, now: now, index: index, id: follow.key, league: league,
                    follow: (name: follow.name, logo: follow.cachedLogo), follows: [follow.name], calendar: calendar)
    }

    /// A game's card (also the sport page's carousel, D-44): `follow` is the follow it is for (its badge for a session,
    /// its team for the record rule), nil for a game nobody named (then its own followed sides are starred).
    static func card(_ game: SportsGame, in front: SportFront, hidden: Bool, now: Date, index: Int, id: String,
                     league: String, follow: (name: String, logo: String?)?, follows: [String],
                     calendar: Calendar = .current) -> SportPhoneCard {
        let row = row(game, in: front, hidden: hidden, now: now, follows: follows, calendar: calendar)
        let live = row.live != nil
        let kicker: String
        if live {
            kicker = "\(game.isOnAir ? "ON AIR" : "LIVE") · \(league)"
        } else if game.terminal {
            kicker = "\(game.statusLabel) · \(league)"
        } else {
            kicker = "\(league) · \(SportFrontText.startLine(game, now: now, calendar: calendar).uppercased())"
        }
        var line: [String] = []
        if game.isOnAir {
            line.append(SportFrontText.onAirLine(game, calendar: calendar))
        } else if live, let clock = row.live?.dropFirst("LIVE".count).trimmingCharacters(in: .whitespaces), !clock.isEmpty {
            line.append(clock)
        } else if !live && !game.terminal {
            line.append(SportFrontText.startLine(game, now: now, calendar: calendar))
        } else if game.terminal {
            line.append(game.statusLabel.capitalized)
        }
        let channel = SportFrontText.channelLine(game)
        if !channel.isEmpty && !game.terminal { line.append(channel) }
        let text = line.joined(separator: " · ")
        let names = row.sides.isEmpty ? [game.title] + [game.session].compactMap { $0 } : row.sides.map(\.name)
        let badge = follow.map { SportFixtureRowModel.Side(name: $0.name, logo: $0.logo, followed: true) }
            ?? SportFixtureRowModel.Side(name: game.league, logo: nil, followed: false)
        return SportPhoneCard(index: index, id: id, kicker: kicker, live: live,
                              sides: row.sides.isEmpty ? [badge] : row.sides,
                              title: row.sides.isEmpty ? game.title : nil, session: row.sides.isEmpty ? game.session : nil,
                              score: row.shortScore ?? row.score, line: text, gameId: game.id, team: follow?.name ?? "",
                              accessibilityLabel: ([kicker] + names + [row.score, text].compactMap { $0 })
                                .filter { !$0.isEmpty }.joined(separator: ", "),
                              scoreDetail: row.scoreDetail)
    }

    static func cards(_ front: SportFront, hidden: Bool, now: Date, labels: [String: String] = [:],
                      calendar: Calendar = .current) -> [SportPhoneCard] {
        front.follows.indices.map { card($0, in: front, hidden: hidden, now: now, labels: labels, calendar: calendar) }
    }

    /// One card per sport with a game (`SportFrontLayout.sections`, in the server's order), its first games.
    static func groups(_ front: SportFront, hidden: Bool, now: Date, labels: [String: String] = [:],
                       calendar: Calendar = .current) -> [SportPhoneGroup] {
        let names = front.follows.map(\.name)
        return SportFrontLayout.sections(front).map { section in
            let games = section.rails.flatMap { front.games(in: $0) }.prefix(rowsPerSport)
            return SportPhoneGroup(sport: section.sport,
                                   note: SportFrontLayout.headerLine(section, in: front, now: now, labels: labels, calendar: calendar),
                                   rows: games.map { row($0, in: front, hidden: hidden, now: now, follows: names, calendar: calendar) })
        }
    }

    /// A game as a fixture row. `hidden`: spoiler-free (the answer's own switch is applied too).
    static func row(_ game: SportsGame, in front: SportFront, hidden: Bool, now: Date, follows: [String],
                    calendar: Calendar = .current) -> SportFixtureRowModel {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let two = game.competitors.count == 2
        let stars = two && game.followed == true ? SportFrontLayout.followedSides(game, names: follows) : []
        let sides = two ? game.competitors.enumerated().map { index, team in
            SportFixtureRowModel.Side(name: team.name, logo: team.cachedLogo, followed: stars.contains(index))
        } : []
        let pair = two ? drawn.scores.flatMap { $0.count == 2 ? $0 : nil } : nil
        let score = pair?.joined(separator: "–")
        let short = pair.map(SportScoreText.short)
        // #203: on air before play takes the live dot too, worded "On air · starts 3:10 pm".
        let ongoing = SportFrontText.showsLive(game)
        let clock = ongoing ? SportFrontText.cardClock(game, in: front, hidden: hidden) : nil
        let live = game.isOnAir ? clock
            : ongoing ? ["LIVE", clock == game.statusLabel ? nil : clock].compactMap { $0 }.joined(separator: " ") : nil
        let channel = SportFrontText.channelLine(game)
        let sub: String
        if ongoing {
            sub = channel
        } else if game.terminal {
            sub = game.statusLabel.capitalized
        } else {
            sub = [SportFrontText.startLine(game, now: now, calendar: calendar), channel].filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        let title = two ? sides.map(\.name).joined(separator: " v ") : (game.session ?? game.title)
        let spoken = [two ? sides.map(\.name).joined(separator: " versus ") : title,
                      two ? nil : (game.session == nil ? nil : game.title),
                      sides.first { $0.followed }.map { "your team \($0.name)" },
                      score, live, sub.isEmpty ? nil : sub].compactMap { $0 }
        return SportFixtureRowModel(id: game.id, league: game.league, sides: sides, title: title,
                                    badge: two ? nil : badge(game.league), score: score, live: live, sub: sub,
                                    accessibilityLabel: spoken.joined(separator: ", "),
                                    shortScore: short?.main, scoreDetail: short?.detail)
    }

    /// A session row's square badge: the league's short name ("F1", "NASCAR" → "NAS").
    static func badge(_ league: String) -> String {
        league.count <= 3 ? league.uppercased() : String(league.filter { !$0.isWhitespace }.prefix(3)).uppercased()
    }

    /// The header chip: what spoiler-free does to the page.
    static func scoresChip(hidden: Bool) -> String { hidden ? "Scores hidden" : "Scores shown" }

    /// "1 of 10 follows".
    static func position(_ index: Int, of count: Int) -> String {
        "\(min(index + 1, count)) of \(count) \(count == 1 ? "follow" : "follows")"
    }
}

/// #225 (Mark, 4 Nov 2026): a card's two buttons, "Watch" (on now) or "Remind me" (before), then "Record": one style
/// family, the same width and height. Record opens the record page (every channel, and every game of the card's team
/// when it has one), whose own wording stays longer. Pure (tests `SportPhonePageTests`).
nonisolated enum SportPhoneCardButtons {
    static let record = "Record"
    /// The rose primary before Record: "Watch" or "Remind me"; none otherwise.
    static func primary(_ action: SportFrontText.Action) -> String? {
        switch action {
        case .watch: "Watch"
        case .remind: "Remind me"
        case .details, .none: nil
        }
    }
}
