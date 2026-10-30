import Foundation

// C-P (server 0340, flag `sportPages`; #21): the Formula 1 page. `GET /api/sports/pages/f1` answers
// `{available, updatedAt, weekend, results, standings}` from ESPN's free feeds plus PigTV's own C-I channels per
// session (each with its own airing times, #20). Fields the feed does not give are null, never guessed: the results
// carry no points (0343), so the page draws no points column for them. Decoding is tolerant: a session, row or
// channel that does not decode is dropped. Spoilers are the client's: the server always sends results, `top` and
// standings, and the household's spoiler-free switch (`sports/pages/preferences`, 0346) hides them here.
// The presentation rules are pure (`F1PageText`, tests `F1PageTests`).

nonisolated struct F1Page: Decodable, Equatable, Sendable {
    var available: Bool
    var weekend: F1Weekend?
    var results: F1Results?
    var standings: F1Standings?

    enum CodingKeys: String, CodingKey { case available, weekend, results, standings }

    init(available: Bool, weekend: F1Weekend? = nil, results: F1Results? = nil, standings: F1Standings? = nil) {
        self.available = available; self.weekend = weekend; self.results = results; self.standings = standings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        weekend = (try? c.decodeIfPresent(F1Weekend.self, forKey: .weekend)) ?? nil
        results = (try? c.decodeIfPresent(F1Results.self, forKey: .results)) ?? nil
        standings = (try? c.decodeIfPresent(F1Standings.self, forKey: .standings)) ?? nil
    }
}

nonisolated struct F1Weekend: Decodable, Equatable, Sendable {
    enum Phase: String, Sendable { case before, during, after }
    var round: Int?
    var rounds: Int?
    var name: String
    var circuit: String?
    var city: String?
    var country: String?
    var phase: Phase
    var info: F1CircuitInfo?
    var sessions: [F1Session]

    enum CodingKeys: String, CodingKey { case round, rounds, name, circuit, city, country, phase, info, sessions }

    init(round: Int?, rounds: Int?, name: String, circuit: String?, city: String?, country: String?, phase: Phase,
         info: F1CircuitInfo?, sessions: [F1Session]) {
        self.round = round; self.rounds = rounds; self.name = name; self.circuit = circuit; self.city = city
        self.country = country; self.phase = phase; self.info = info; self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        round = (try? c.decodeIfPresent(Int.self, forKey: .round)) ?? nil
        rounds = (try? c.decodeIfPresent(Int.self, forKey: .rounds)) ?? nil
        name = try c.decode(String.self, forKey: .name)
        circuit = (try? c.decodeIfPresent(String.self, forKey: .circuit)) ?? nil
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? nil
        country = (try? c.decodeIfPresent(String.self, forKey: .country)) ?? nil
        phase = ((try? c.decodeIfPresent(String.self, forKey: .phase)) ?? nil).flatMap(Phase.init(rawValue:)) ?? .before
        info = (try? c.decodeIfPresent(F1CircuitInfo.self, forKey: .info)) ?? nil
        sessions = ((try? c.decodeIfPresent(LossyList<F1Session>.self, forKey: .sessions)) ?? nil)?.items
            .sorted { $0.startTime < $1.startTime } ?? []
    }
}

nonisolated struct F1CircuitInfo: Decodable, Equatable, Sendable {
    var length: String?
    var laps: Int?
    var turns: Int?
    var lapRecord: String?
    var lapRecordYear: Int?
    var map: String?

    enum CodingKeys: String, CodingKey { case length, laps, turns, lapRecord, lapRecordYear, map }

    init(length: String? = nil, laps: Int? = nil, turns: Int? = nil, lapRecord: String? = nil, lapRecordYear: Int? = nil,
         map: String? = nil) {
        self.length = length; self.laps = laps; self.turns = turns; self.lapRecord = lapRecord
        self.lapRecordYear = lapRecordYear; self.map = map
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        length = (try? c.decodeIfPresent(String.self, forKey: .length)) ?? nil
        laps = (try? c.decodeIfPresent(Int.self, forKey: .laps)) ?? nil
        turns = (try? c.decodeIfPresent(Int.self, forKey: .turns)) ?? nil
        lapRecord = (try? c.decodeIfPresent(String.self, forKey: .lapRecord)) ?? nil
        lapRecordYear = (try? c.decodeIfPresent(Int.self, forKey: .lapRecordYear)) ?? nil
        map = ((try? c.decodeIfPresent(String.self, forKey: .map)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }
}

nonisolated struct F1Session: Decodable, Equatable, Identifiable, Sendable {
    enum Status: String, Sendable { case scheduled, live, done }
    struct Top: Decodable, Equatable, Sendable {
        /// "fastest" | "pole" | "winner".
        var kind: String
        var driver: String
    }
    /// C-I's session id: "practice 1" … "race".
    var id: String
    var name: String
    /// Milliseconds since 1970.
    var startTime: Double
    var endTime: Double
    var status: Status
    var top: Top?
    var channels: [SportEventChannel]

    var start: Date { Date(timeIntervalSince1970: startTime / 1000) }
    var end: Date { Date(timeIntervalSince1970: endTime / 1000) }

    enum CodingKeys: String, CodingKey { case id, name, start, end, status, top, channels }

    init(id: String, name: String, startTime: Double, endTime: Double, status: Status, top: Top? = nil,
         channels: [SportEventChannel] = []) {
        self.id = id; self.name = name; self.startTime = startTime; self.endTime = endTime; self.status = status
        self.top = top; self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? id.capitalized
        let start = try c.decode(Double.self, forKey: .start)
        startTime = start
        let end = (try? c.decodeIfPresent(Double.self, forKey: .end)) ?? nil
        endTime = end.flatMap { $0 > start ? $0 : nil } ?? start + 3_600_000
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil).flatMap(Status.init(rawValue:)) ?? .scheduled
        top = (try? c.decodeIfPresent(Top.self, forKey: .top)) ?? nil
        channels = ((try? c.decodeIfPresent(LossyList<SportEventChannel>.self, forKey: .channels)) ?? nil)?.items ?? []
    }
}

nonisolated struct F1Results: Decodable, Equatable, Sendable {
    /// "race" (the last finished race) | "grid" (qualifying's order during a weekend).
    var kind: String
    var title: String
    var rows: [F1ResultRow]

    enum CodingKeys: String, CodingKey { case kind, title, rows }

    init(kind: String, title: String, rows: [F1ResultRow]) { self.kind = kind; self.title = title; self.rows = rows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "race"
        title = (try? c.decode(String.self, forKey: .title)) ?? (kind == "grid" ? "Starting grid" : "Last race")
        rows = ((try? c.decodeIfPresent(LossyList<F1ResultRow>.self, forKey: .rows)) ?? nil)?.items ?? []
    }
}

nonisolated struct F1ResultRow: Decodable, Equatable, Sendable {
    var pos: Int
    var driver: String
    var team: String?
    var teamColor: String?

    enum CodingKeys: String, CodingKey { case pos, driver, team, teamColor }

    init(pos: Int, driver: String, team: String? = nil, teamColor: String? = nil) {
        self.pos = pos; self.driver = driver; self.team = team; self.teamColor = teamColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pos = try c.decode(Int.self, forKey: .pos)
        driver = try c.decode(String.self, forKey: .driver)
        team = (try? c.decodeIfPresent(String.self, forKey: .team)) ?? nil
        teamColor = (try? c.decodeIfPresent(String.self, forKey: .teamColor)) ?? nil
    }
}

nonisolated struct F1Standings: Decodable, Equatable, Sendable {
    var afterRound: Int?
    var drivers: [F1StandingRow]
    var constructors: [F1StandingRow]

    enum CodingKeys: String, CodingKey { case afterRound, drivers, constructors }

    init(afterRound: Int?, drivers: [F1StandingRow], constructors: [F1StandingRow]) {
        self.afterRound = afterRound; self.drivers = drivers; self.constructors = constructors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        afterRound = (try? c.decodeIfPresent(Int.self, forKey: .afterRound)) ?? nil
        drivers = ((try? c.decodeIfPresent(LossyList<F1StandingRow>.self, forKey: .drivers)) ?? nil)?.items ?? []
        constructors = ((try? c.decodeIfPresent(LossyList<F1StandingRow>.self, forKey: .constructors)) ?? nil)?.items ?? []
    }
}

nonisolated struct F1StandingRow: Decodable, Equatable, Sendable {
    var pos: Int
    var name: String
    var team: String?
    var teamColor: String?
    var points: Double?

    enum CodingKeys: String, CodingKey { case pos, name, team, teamColor, points }

    init(pos: Int, name: String, team: String? = nil, teamColor: String? = nil, points: Double? = nil) {
        self.pos = pos; self.name = name; self.team = team; self.teamColor = teamColor; self.points = points
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pos = try c.decode(Int.self, forKey: .pos)
        name = try c.decode(String.self, forKey: .name)
        team = (try? c.decodeIfPresent(String.self, forKey: .team)) ?? nil
        teamColor = (try? c.decodeIfPresent(String.self, forKey: .teamColor)) ?? nil
        points = (try? c.decodeIfPresent(Double.self, forKey: .points)) ?? nil
    }
}

/// The household's sport page preferences (server 0346): one for every device and account.
nonisolated struct SportPagePreferences: Codable, Equatable, Sendable {
    var spoilerFree = false
    /// The followed driver on the F1 page (nil: nobody).
    var f1Following: String?

    enum CodingKeys: String, CodingKey { case spoilerFree, following }
    private enum Pages: String, CodingKey { case f1 = "F1" }

    init(spoilerFree: Bool = false, f1Following: String? = nil) {
        self.spoilerFree = spoilerFree; self.f1Following = f1Following
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spoilerFree = (try? c.decode(Bool.self, forKey: .spoilerFree)) ?? false
        let pages = try? c.nestedContainer(keyedBy: Pages.self, forKey: .following)
        f1Following = ((try? pages?.decodeIfPresent(String.self, forKey: .f1)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spoilerFree, forKey: .spoilerFree)
        var pages = c.nestedContainer(keyedBy: Pages.self, forKey: .following)
        try pages.encode(f1Following, forKey: .f1)
    }
}

/// What the page says, from the data, the clock and the preferences. Pure.
nonisolated enum F1PageText {
    /// "Mexico City Grand Prix" → "Mexico City GP" (event titles, as C-I writes them).
    static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Grand Prix", with: "GP").trimmingCharacters(in: .whitespaces)
    }

    /// "ROUND 21 OF 25", or nil without a round.
    static func roundLine(_ weekend: F1Weekend) -> String? {
        guard let round = weekend.round else { return nil }
        return weekend.rounds.map { "ROUND \(round) OF \($0)" } ?? "ROUND \(round)"
    }

    /// "Autódromo Hermanos Rodríguez · Mexico City, Mexico" from whatever the feed gave.
    static func placeLine(_ weekend: F1Weekend) -> String {
        let place = [weekend.city, weekend.country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        return [weekend.circuit ?? "", place].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The four circuit stats, values never wrapping (DESIGN.md › Sport pages); a missing one says "—".
    static func stats(_ info: F1CircuitInfo?) -> [(label: String, value: String)] {
        [("Length", info?.length ?? "—"), ("Laps", info?.laps.map(String.init) ?? "—"),
         ("Turns", info?.turns.map(String.init) ?? "—"), ("Lap record", info?.lapRecord ?? "—")]
    }

    /// The session the hero speaks about: the live one, else the next to start, else nil (the weekend is over).
    static func focusSession(_ weekend: F1Weekend, now: Date) -> F1Session? {
        weekend.sessions.first { live($0, now: now) } ?? weekend.sessions.first { $0.status != .done && $0.start > now }
    }

    /// Live: the feed says so, or the clock is inside its time (the feed lags a few minutes).
    static func live(_ session: F1Session, now: Date) -> Bool {
        session.status == .live || (session.status != .done && session.start <= now && now < session.end)
    }

    /// A session's pill: "LIVE", "Next", the top driver ("Pole · Antonelli") once done, "Finished" with spoilers
    /// hidden, or nothing for a later session.
    enum Pill: Equatable { case live, next, done(String), none }
    static func pill(_ session: F1Session, in weekend: F1Weekend, now: Date, spoilerFree: Bool) -> Pill {
        if live(session, now: now) { return .live }
        if session.status == .done || session.end <= now {
            guard !spoilerFree, let top = session.top else { return .done("Finished") }
            let word = ["pole": "Pole", "winner": "Winner", "fastest": "Fastest"][top.kind] ?? "Top"
            return .done("\(word) · \(surname(top.driver))")
        }
        return focusSession(weekend, now: now)?.id == session.id ? .next : .none
    }

    static func surname(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }

    /// "Sat 31 Oct · 5:30 am" in the device's zone.
    static func when(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        // The template's own comma ("Sat, 31 Oct") goes: the mock-ups read "Sat 31 Oct".
        let day = formatter.string(from: date).replacingOccurrences(of: ",", with: "")
        return "\(day) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// "in 14 h", "in 35 min", "in 2 days".
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "in \(hours) h" }
        return "in \(hours / 24) days"
    }

    /// The hero's headline: "Race is live", "Practice 1 in 14 h · Sat 5:30 am", or the weekend being over.
    static func headline(_ weekend: F1Weekend, now: Date) -> String {
        guard let session = focusSession(weekend, now: now) else { return "Weekend finished" }
        if live(session, now: now) { return "\(session.name) is live" }
        let time = session.start.formatted(date: .omitted, time: .shortened)
        let day = session.start.formatted(.dateTime.weekday(.abbreviated))
        return "\(session.name) \(countdown(to: session.start, now: now)) · \(day) \(time)"
    }

    /// The session as a C-I event (title "Mexico City GP · Practice 1", league F1), so Watch, Record, "Watch when it
    /// starts" and the channel picker work exactly as on the Sport tab, on each channel's own times (#20).
    static func event(_ session: F1Session, in weekend: F1Weekend) -> SportEvent {
        SportEvent(id: "f1:\(weekend.round.map(String.init) ?? weekend.name):\(session.id)",
                   title: "\(shortName(weekend.name)) · \(session.name)", league: "F1",
                   startTime: session.startTime, endTime: session.endTime, channels: session.channels)
    }

    /// "Last race · United States GP · Mon 26 Oct"-style title stays the server's; the note under the standings.
    static func standingsNote(_ standings: F1Standings, weekend: F1Weekend?) -> String? {
        guard let after = standings.afterRound else { return nil }
        return weekend?.rounds.map { "After round \(after) of \($0)" } ?? "After round \(after)"
    }

    /// Standings points as the feed gives them ("365", "12.5").
    static func points(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Everyone the page can offer to follow: the drivers' standings, then anyone else in the results, unique.
    static func drivers(_ page: F1Page) -> [String] {
        var seen = Set<String>()
        return ((page.standings?.drivers.map(\.name) ?? []) + (page.results?.rows.map(\.driver) ?? []))
            .filter { seen.insert($0).inserted }
    }
}
