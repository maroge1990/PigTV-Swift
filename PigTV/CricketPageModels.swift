import Foundation

// C-S (server 0383, flag `sportPageCricket`; #21): the Cricket page. `GET /api/sports/pages/cricket` answers `{ available,
// updatedAt, lead, series, others }`: the match the page leads with (the household's followed team's, else the first live
// one, else the next) with its innings per team, summary, who is at the crease, its days and the C-I channels for the
// day's airing; the lead's series with every match and its result; the other competitions' matches today and tomorrow.
// Fields the feed lacks are null and decode as nil; nothing here throws on them, and unknown fields (a channel's
// `overrun`, server 0386) are ignored.

nonisolated enum CricketStatus: String, Sendable {
    case scheduled, live, onBreak = "break", done
}

private extension KeyedDecodingContainer {
    /// An id that may arrive as a number.
    nonisolated func cricketID(_ key: Key) -> String? {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        return nil
    }
    nonisolated func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(type, forKey: key)) ?? nil }
    nonisolated func status(_ key: Key) -> CricketStatus { optional(String.self, key).flatMap(CricketStatus.init(rawValue:)) ?? .scheduled }
}

nonisolated struct CricketPage: Decodable, Equatable, Sendable {
    var available: Bool
    var updatedAt: Double?
    var lead: CricketLead?
    var series: CricketSeries?
    var others: [CricketOther]

    enum CodingKeys: String, CodingKey { case available, updatedAt, lead, series, others }

    init(available: Bool = true, updatedAt: Double? = nil, lead: CricketLead? = nil, series: CricketSeries? = nil, others: [CricketOther] = []) {
        self.available = available; self.updatedAt = updatedAt; self.lead = lead; self.series = series; self.others = others
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.optional(Bool.self, .available) ?? false
        updatedAt = c.optional(Double.self, .updatedAt)
        lead = c.optional(CricketLead.self, .lead)
        series = c.optional(CricketSeries.self, .series)
        others = c.optional(LossyList<CricketOther>.self, .others)?.items ?? []
    }
}

nonisolated struct CricketTeam: Decodable, Equatable, Sendable {
    var abbr: String?
    var name: String
    /// A logo-cache path, or nil.
    var logo: String?
}

nonisolated struct CricketInnings: Decodable, Equatable, Sendable {
    var runs: Int?
    var wickets: Int?
    /// Balls notation, as text ("71.4").
    var overs: String?
    var declared: Bool
    var current: Bool

    init(runs: Int?, wickets: Int?, overs: String? = nil, declared: Bool = false, current: Bool = false) {
        self.runs = runs; self.wickets = wickets; self.overs = overs; self.declared = declared; self.current = current
    }

    enum CodingKeys: String, CodingKey { case runs, wickets, overs, declared, current }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = c.optional(Int.self, .runs)
        wickets = c.optional(Int.self, .wickets)
        overs = c.optional(String.self, .overs) ?? c.optional(Double.self, .overs).map { String($0) }
        declared = c.optional(Bool.self, .declared) ?? false
        current = c.optional(Bool.self, .current) ?? false
    }
}

nonisolated struct CricketBatter: Decodable, Equatable, Sendable {
    var name: String
    var runs: Int?
    var balls: Int?
}

nonisolated struct CricketDay: Decodable, Equatable, Identifiable, Sendable {
    enum State: String, Sendable { case done, live, next, later }
    var number: Int
    /// Local midnight, in ms.
    var date: Double?
    var state: State
    var id: Int { number }

    enum CodingKeys: String, CodingKey { case number, date, state }
    init(number: Int, date: Double?, state: State) { self.number = number; self.date = date; self.state = state }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        date = c.optional(Double.self, .date)
        state = c.optional(String.self, .state).flatMap(State.init(rawValue:)) ?? .later
    }
}

/// The match the page leads with.
nonisolated struct CricketLead: Decodable, Equatable, Sendable {
    var id: String
    var seriesId: String?
    var competition: String?
    /// "3rd Test".
    var label: String?
    /// test | odi | t20 | first-class | list-a.
    var format: String?
    var venue: String?
    var city: String?
    var start: Double?
    var end: Double?
    var status: CricketStatus
    /// "Stumps", "Lunch" while on a break.
    var breakLabel: String?
    /// "Day 4".
    var day: String?
    /// 1–3, live only.
    var session: Int?
    var teams: [CricketTeam]
    /// One list per team (in `teams` order); an empty list: the team has not batted.
    var innings: [[CricketInnings]]
    var summary: String?
    var crease: [CricketBatter]?
    var seriesLine: String?
    var days: [CricketDay]
    var nextStart: Double?
    var channels: [SportEventChannel]

    enum CodingKeys: String, CodingKey {
        case id, seriesId, competition, label, format, venue, city, start, end, status, breakLabel, day, session, teams, innings,
             summary, crease, seriesLine, days, nextStart, channels
    }

    init(id: String, status: CricketStatus, teams: [CricketTeam], innings: [[CricketInnings]] = [], label: String? = nil,
         start: Double? = nil, end: Double? = nil, days: [CricketDay] = [], nextStart: Double? = nil, channels: [SportEventChannel] = []) {
        self.id = id; self.status = status; self.teams = teams; self.innings = innings; self.label = label; self.start = start
        self.end = end; self.days = days; self.nextStart = nextStart; self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.cricketID(.id) else { throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id")) }
        self.id = id
        seriesId = c.cricketID(.seriesId)
        competition = c.optional(String.self, .competition)
        label = c.optional(String.self, .label)
        format = c.optional(String.self, .format)
        venue = c.optional(String.self, .venue)
        city = c.optional(String.self, .city)
        start = c.optional(Double.self, .start)
        end = c.optional(Double.self, .end)
        status = c.status(.status)
        breakLabel = c.optional(String.self, .breakLabel)
        day = c.optional(String.self, .day)
        session = c.optional(Int.self, .session)
        teams = c.optional(LossyList<CricketTeam>.self, .teams)?.items ?? []
        innings = c.optional([[CricketInnings]].self, .innings) ?? []
        summary = c.optional(String.self, .summary)
        crease = c.optional([CricketBatter].self, .crease)
        seriesLine = c.optional(String.self, .seriesLine)
        days = c.optional(LossyList<CricketDay>.self, .days)?.items ?? []
        nextStart = c.optional(Double.self, .nextStart)
        channels = c.optional(LossyList<SportEventChannel>.self, .channels)?.items ?? []
    }
}

nonisolated struct CricketSeries: Decodable, Equatable, Sendable {
    nonisolated struct Match: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var label: String?
        var start: Double?
        var end: Double?
        var status: CricketStatus
        var result: String?
        var current: Bool

        enum CodingKeys: String, CodingKey { case id, label, start, end, status, result, current }
        init(id: String, label: String?, start: Double?, end: Double?, status: CricketStatus, result: String? = nil, current: Bool = false) {
            self.id = id; self.label = label; self.start = start; self.end = end; self.status = status; self.result = result; self.current = current
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.cricketID(.id) else { throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id")) }
            self.id = id
            label = c.optional(String.self, .label)
            start = c.optional(Double.self, .start)
            end = c.optional(Double.self, .end)
            status = c.status(.status)
            result = c.optional(String.self, .result)
            current = c.optional(Bool.self, .current) ?? false
        }
    }
    var id: String?
    var name: String?
    var season: String?
    var matches: [Match]

    enum CodingKeys: String, CodingKey { case id, name, season, matches }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.cricketID(.id)
        name = c.optional(String.self, .name)
        season = c.optional(String.self, .season)
        matches = c.optional(LossyList<Match>.self, .matches)?.items ?? []
    }
}

/// A match from another competition, today or tomorrow.
nonisolated struct CricketOther: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var seriesId: String?
    var competition: String?
    var teams: [CricketTeam]
    /// As ESPN shows them, one per team ("329 & 200/5"); nil for a team that has not batted.
    var scores: [String?]
    /// The feed's summary (the match situation).
    var line: String?
    var status: CricketStatus
    var start: Double?
    var nextStart: Double?
    var channels: [SportEventChannel]

    enum CodingKeys: String, CodingKey { case id, seriesId, competition, teams, scores, line, status, start, nextStart, channels }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.cricketID(.id) else { throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "no id")) }
        self.id = id
        seriesId = c.cricketID(.seriesId)
        competition = c.optional(String.self, .competition)
        teams = c.optional(LossyList<CricketTeam>.self, .teams)?.items ?? []
        scores = c.optional([String?].self, .scores) ?? []
        line = c.optional(String.self, .line)
        status = c.status(.status)
        start = c.optional(Double.self, .start)
        nextStart = c.optional(Double.self, .nextStart)
        channels = c.optional(LossyList<SportEventChannel>.self, .channels)?.items ?? []
    }
}

/// What the page says, from the data, the clock and the household's spoiler-free switch. Pure.
nonisolated enum CricketPageText {
    /// A day's play when the guide has nothing better (as the server's DAY_HOURS: a Test day 6.5 h).
    static let typicalDay: Double = 6.5 * 3600 * 1000

    /// The page as it may be drawn: with spoiler-free on, the lead's innings (each team's list emptied), summary, crease
    /// and series line, every series result, and each other match's scores and line are removed; the day, status, break,
    /// days, next start and teams stay. The view draws only this.
    static func visible(_ page: CricketPage, spoilerFree: Bool) -> CricketPage {
        guard spoilerFree else { return page }
        var out = page
        if var lead = out.lead {
            lead.innings = lead.innings.map { _ in [] }
            lead.summary = nil
            lead.crease = nil
            lead.seriesLine = nil
            out.lead = lead
        }
        if var series = out.series {
            series.matches = series.matches.map { var m = $0; m.result = nil; return m }
            out.series = series
        }
        out.others = out.others.map { var o = $0; o.scores = o.scores.map { _ in nil }; o.line = nil; return o }
        return out
    }

    /// One team's innings as the scores card shows them: "329 & 200/5", "406/5d"; nil when it has not batted (never 0).
    /// All out (10 wickets) shows the runs alone.
    static func innings(_ list: [CricketInnings]) -> String? {
        let parts = list.compactMap { i -> String? in
            guard let runs = i.runs else { return nil }
            var text = String(runs)
            if let w = i.wickets, w < 10 { text += "/\(w)" }
            if i.declared { text += "d" }
            return text
        }
        return parts.isEmpty ? nil : parts.joined(separator: " & ")
    }

    /// The note beside the batting team: "batting · 71.4 ov" while in play, "90 ov" at a break; nil otherwise.
    static func battingNote(_ list: [CricketInnings], status: CricketStatus) -> String? {
        guard let open = list.last(where: \.current), let overs = open.overs, status == .live || status == .onBreak else { return nil }
        return status == .live ? "batting · \(overs) ov" : "\(overs) ov"
    }

    /// "Rickelton 31* · Mulder 4*" (surnames); nil without a crease.
    static func crease(_ batters: [CricketBatter]?) -> String? {
        guard let batters, !batters.isEmpty else { return nil }
        return batters.map { b in
            let surname = b.name.split(separator: " ").last.map(String.init) ?? b.name
            return b.runs.map { "\(surname) \($0)*" } ?? surname
        }.joined(separator: " · ")
    }

    static func title(_ teams: [CricketTeam]) -> String { teams.map(\.name).joined(separator: " v ") }

    /// The current day's number ("Day 4" → 4), else the live day's.
    static func dayNumber(_ lead: CricketLead) -> Int? {
        if let text = lead.day, let n = Int(text.filter(\.isNumber)) { return n }
        return lead.days.first { $0.state == .live }?.number
    }

    /// The day play resumes or starts on: the `next` chip's number.
    static func nextDay(_ lead: CricketLead) -> Int? { lead.days.first { $0.state == .next }?.number }

    /// "3RD TEST · DAY 4 · SESSION 1" while live; "3RD TEST · STUMPS, DAY 4" on a break.
    static func kicker(_ lead: CricketLead) -> String {
        var parts = [lead.label ?? lead.competition ?? "Cricket"]
        switch lead.status {
        case .live:
            if let day = lead.day { parts.append(day) }
            if let s = lead.session { parts.append("Session \(s)") }
        case .onBreak:
            parts.append([lead.breakLabel ?? "Break", lead.day].compactMap { $0 }.joined(separator: ", "))
        case .scheduled:
            if lead.days.count > 1, let n = nextDay(lead) { parts.append("Day \(n)") }
        case .done:
            break
        }
        return parts.joined(separator: " · ").uppercased()
    }

    /// The pill beside the kicker: "LIVE"; "DAY 5 IN 21 H" before the next day; "LUNCH" on a break with no next start;
    /// "STARTS IN 3 H" before the match; "FINISHED".
    static func pill(_ lead: CricketLead, now: Date) -> String {
        switch lead.status {
        case .live: return "LIVE"
        case .done: return "FINISHED"
        case .onBreak, .scheduled:
            guard let next = lead.nextStart ?? (lead.status == .scheduled ? lead.start : nil) else { return (lead.breakLabel ?? "Break").uppercased() }
            let seconds = Date(timeIntervalSince1970: next / 1000).timeIntervalSince(now)
            let label: String
            if lead.status == .onBreak { label = nextDay(lead).map { "Day \($0)" } ?? "Play" }
            else if lead.days.count > 1, let n = nextDay(lead), n > 1 { label = "Day \(n)" }
            else { label = "Starts" }
            return seconds > 0 ? "\(label) in \(shortSpan(seconds))".uppercased() : (lead.breakLabel ?? "Soon").uppercased()
        }
    }

    /// "21 h", "40 min", "3 days".
    static func shortSpan(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h" : "\(hours / 24) days"
    }

    private static func formatter(_ template: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "Tue 27 Oct".
    static func dayDate(_ ms: Double, calendar: Calendar = .current) -> String {
        formatter("EEEdMMM", calendar: calendar).string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// "Sat 7:30 pm" (the time alone today).
    static func when(_ ms: Double, now: Date, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let time = formatter("jmm", calendar: calendar).string(from: date)
        return calendar.isDate(date, inSameDayAs: now) ? time : "\(formatter("EEE", calendar: calendar).string(from: date)) \(time)"
    }

    /// "9–13 Oct", "29 Oct–2 Nov", or one day "Thu 24 Sep".
    static func span(start: Double?, end: Double?, calendar: Calendar = .current) -> String? {
        guard let start else { return nil }
        let a = Date(timeIntervalSince1970: start / 1000)
        guard let end else { return dayDate(start, calendar: calendar) }
        let b = Date(timeIntervalSince1970: (end - 1) / 1000)
        guard b > a, !calendar.isDate(a, inSameDayAs: b) else { return dayDate(start, calendar: calendar) }
        let sameMonth = calendar.component(.month, from: a) == calendar.component(.month, from: b)
        let first = formatter(sameMonth ? "d" : "dMMM", calendar: calendar).string(from: a)
        return "\(first)–\(formatter("dMMM", calendar: calendar).string(from: b))"
    }

    /// "Newlands, Cape Town · 5-day match, 27–31 Oct · Series level 1–1 · third of three Tests" (the series line only
    /// when the page may show it).
    static func venueLine(_ lead: CricketLead, calendar: Calendar = .current) -> String {
        let length: String? = {
            // By the days' local midnights when there are several (a Test that ends after midnight here still reads 27–31 Oct).
            let dates = lead.days.count > 1 ? span(start: lead.days.first?.date, end: lead.days.last?.date.map { $0 + 1 }, calendar: calendar)
                : span(start: lead.start, end: lead.end, calendar: calendar)
            let kind: String? = lead.days.count > 1 ? "\(lead.days.count)-day match" : formatName(lead.format)
            let joined = [kind, dates].compactMap { $0 }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }()
        return [lead.venue, length, lead.seriesLine].compactMap { $0 }.joined(separator: " · ")
    }

    static func formatName(_ format: String?) -> String? {
        switch format {
        case "test": return "Test"
        case "odi": return "One-day match"
        case "t20": return "T20"
        case "first-class": return "First-class match"
        case "list-a": return "One-day match"
        default: return nil
        }
    }

    /// A day chip's second line: "Live now", the break ("Stumps") on the current day, the next day's start, else its date.
    static func daySub(_ day: CricketDay, lead: CricketLead, now: Date, calendar: Calendar = .current) -> String {
        switch day.state {
        case .live: return "Live now"
        case .next:
            if let next = lead.nextStart { return when(next, now: now, calendar: calendar) }
        case .done:
            if lead.status == .onBreak, day.number == dayNumber(lead), let label = lead.breakLabel { return label }
        case .later: break
        }
        return day.date.map { dayDate($0, calendar: calendar) } ?? ""
    }

    /// A series match's right-hand text: the lead's state on the current match ("Live · day 4", "Stumps · day 4"), the
    /// result (or "Finished" with spoiler-free on, or none given), else its start.
    static func seriesResult(_ match: CricketSeries.Match, lead: CricketLead?, spoilerFree: Bool, now: Date, calendar: Calendar = .current) -> String {
        if let lead, match.current || match.id == lead.id {
            let day = lead.day.map { $0.lowercased() }
            switch lead.status {
            case .live: return ["Live", day].compactMap { $0 }.joined(separator: " · ")
            case .onBreak: return [lead.breakLabel ?? "Break", day].compactMap { $0 }.joined(separator: " · ")
            case .scheduled, .done: break
            }
        }
        switch match.status {
        case .done: return spoilerFree ? "Finished" : (match.result ?? "Finished")
        case .live: return "Live"
        case .onBreak: return "Break"
        case .scheduled: return match.start.map { when($0, now: now, calendar: calendar) } ?? ""
        }
    }

    /// The lead as a C-I event on its channels' own airing (#20), so Watch, Remind me, Record and the channel picker are
    /// the Sport tab's own.
    static func event(_ lead: CricketLead) -> SportEvent {
        let start = lead.channels.compactMap(\.startTime).min() ?? lead.nextStart ?? lead.start ?? 0
        let end = lead.channels.compactMap(\.endTime).max() ?? (start + typicalDay)
        return SportEvent(id: "cricket:\(lead.id)", title: title(lead.teams), league: "Cricket", startTime: start,
                          endTime: max(end, start + 60_000), channels: lead.channels)
    }

    static func event(_ other: CricketOther) -> SportEvent {
        let start = other.channels.compactMap(\.startTime).min() ?? other.nextStart ?? other.start ?? 0
        let end = other.channels.compactMap(\.endTime).max() ?? (start + typicalDay)
        return SportEvent(id: "cricket:\(other.id)", title: title(other.teams), league: "Cricket", startTime: start,
                          endTime: max(end, start + 60_000), channels: other.channels)
    }

    enum Action: Equatable, Sendable { case watchLive, otherChannels, remind(day: Int?), cancelRemind, record(day: Int?) }

    /// What the lead offers: every action needs a channel the guide carries the day on. "Watch live" while the best
    /// channel's own airing is on (its own end: an airing that has ended offers none, one the server rolled on for an
    /// overrun does), "Other channels" beside it with more than one; before the airing "Remind me" (or its cancel when
    /// already asked); Record until the airing has ended.
    static func actions(_ lead: CricketLead, now: Date, pendingEventID: String?) -> [Action] {
        let event = event(lead)
        guard let best = event.best, lead.status != .done else { return [] }
        var out: [Action] = []
        switch SportRows.channelAction(event, on: best, now: now) {
        case .play:
            out.append(.watchLive)
            if event.channels.count > 1 { out.append(.otherChannels) }
            out.append(.record(day: nil))
        case .wait:
            let day = lead.days.count > 1 ? (nextDay(lead) ?? dayNumber(lead)) : nil
            out.append(pendingEventID == event.id ? .cancelRemind : .remind(day: day))
            out.append(.record(day: day))
        case .ended:
            break
        }
        return out
    }

    static func label(_ action: Action) -> String {
        switch action {
        case .watchLive: return "Watch live"
        case .otherChannels: return "Other channels"
        case .remind(let day): return day.map { "Remind me · day \($0)" } ?? "Remind me"
        case .cancelRemind: return "Don't remind me"
        case .record(let day): return day.map { "Record day \($0)" } ?? "Record"
        }
    }

    /// The line under the actions: the channel, and before the airing when it starts ("Day 5 · Sat 7:30 pm on Fox Cricket").
    static func channelLine(_ lead: CricketLead, now: Date, calendar: Calendar = .current) -> String {
        let event = event(lead)
        guard let best = event.best else { return lead.status == .done ? "" : "Not in guide yet" }
        if SportRows.channelAction(event, on: best, now: now) == .wait {
            let at = when(event.start(on: best).timeIntervalSince1970 * 1000, now: now, calendar: calendar)
            let day = lead.days.count > 1 ? nextDay(lead).map { "Day \($0) · " } ?? "" : ""
            return "\(day)\(at) on \(best.name)"
        }
        return "on \(best.name)"
    }

    /// An other match's status: "LIVE", "Resumes Sat 10:30 am", the start, "Finished".
    static func otherStatus(_ other: CricketOther, now: Date, calendar: Calendar = .current) -> String {
        switch other.status {
        case .live: return "LIVE"
        case .onBreak: return other.nextStart.map { "Resumes \(when($0, now: now, calendar: calendar))" } ?? "Break"
        case .scheduled: return (other.nextStart ?? other.start).map { when($0, now: now, calendar: calendar) } ?? "Upcoming"
        case .done: return "Finished"
        }
    }

    /// Whether selecting an other match plays it now: its best channel airs it at `now` (its own times).
    static func othersPlaysNow(_ other: CricketOther, now: Date) -> Bool {
        let event = event(other)
        guard event.best != nil, other.status != .done else { return false }
        return SportRows.playsChannelNow(event, now: now)
    }
}
