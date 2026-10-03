import Foundation

// C-I (server 0147–0149, flag `sportsEvents`): sport events. The server
// recognises sport per programme and groups the channels showing the same
// event; `GET /api/sports/events?hours=N` answers
// `{now, events: [{id, title, league, start, end, live, channels: [...]}]}`
// with times in **milliseconds**, live events first, channels best first.
// Decoding is tolerant: an event or channel that does not decode is dropped,
// an unknown quality is nil. The bucketing and text are pure (`SportRows`,
// tests `SportRowsTests`).

/// "UHD" | "HD" | "SD"; anything else decodes as nil.
nonisolated enum SportQuality: String, Sendable, Equatable {
    case uhd = "UHD", hd = "HD", sd = "SD"
}

/// One channel showing an event.
nonisolated struct SportEventChannel: Decodable, Identifiable, Equatable, Sendable {
    let sourceId: Int
    let rawID: String
    var stableId: String? = nil
    let name: String
    var number: Int? = nil
    var logo: String? = nil
    var quality: SportQuality? = nil

    var id: String { "\(sourceId):\(rawID)" }
    var identityKey: String { stableId.map { "\(sourceId):s:\($0)" } ?? id }

    enum CodingKeys: String, CodingKey { case sourceId, rawID = "id", stableId, name, number, logo, quality }

    init(sourceId: Int, rawID: String, stableId: String? = nil, name: String, number: Int? = nil,
         logo: String? = nil, quality: SportQuality? = nil) {
        self.sourceId = sourceId; self.rawID = rawID; self.stableId = stableId; self.name = name
        self.number = number; self.logo = logo; self.quality = quality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(Int.self, forKey: .sourceId)
        rawID = try c.decodeLenientString(.rawID)
        name = try c.decode(String.self, forKey: .name)
        stableId = try? c.decodeLenientString(.stableId)
        number = (try? c.decodeIfPresent(Int.self, forKey: .number)) ?? nil
        logo = ((try? c.decodeIfPresent(String.self, forKey: .logo)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        quality = ((try? c.decodeIfPresent(String.self, forKey: .quality)) ?? nil)
            .flatMap { SportQuality(rawValue: $0.uppercased()) }
    }
}

/// Build 31: the server also lists replays of identifiable games
/// (`kind: "replay"`); anything else, or no `kind`, is a live event.
nonisolated enum SportEventKind: String, Sendable, Equatable {
    case event, replay
}

/// One event, with the channels showing it (best first).
nonisolated struct SportEvent: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let league: String
    /// Milliseconds since 1970.
    let startTime: Double
    let endTime: Double
    let channels: [SportEventChannel]
    var kind: SportEventKind = .event

    var isReplay: Bool { kind == .replay }
    var start: Date { Date(timeIntervalSince1970: startTime / 1000) }
    var end: Date { Date(timeIntervalSince1970: endTime / 1000) }
    var best: SportEventChannel? { channels.first }
    func isLive(at now: Date) -> Bool { start <= now && now < end }

    /// The event as a guide programme on one of its channels (Record).
    var programme: GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: startTime, endTime: endTime)
    }

    enum CodingKeys: String, CodingKey { case id, title, league, start, end, channels, kind }

    init(id: String, title: String, league: String, startTime: Double, endTime: Double, channels: [SportEventChannel],
         kind: SportEventKind = .event) {
        self.id = id; self.title = title; self.league = league
        self.startTime = startTime; self.endTime = endTime; self.channels = channels; self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        title = try c.decode(String.self, forKey: .title)
        let league = ((try? c.decodeIfPresent(String.self, forKey: .league)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.league = (league?.isEmpty == false ? league : nil) ?? "Sport"
        startTime = try c.decode(Double.self, forKey: .start)
        endTime = try c.decode(Double.self, forKey: .end)
        channels = ((try? c.decodeIfPresent(LossyList<SportEventChannel>.self, forKey: .channels)) ?? nil)?.items ?? []
        kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil)
            .flatMap { SportEventKind(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) } ?? .event
    }
}

/// The `sports/events` answer. Events with no playable channel, or that do
/// not decode, are left out.
nonisolated struct SportEventsResponse: Decodable, Sendable {
    let now: Double?
    let events: [SportEvent]

    enum CodingKeys: String, CodingKey { case now, events }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = (try? c.decodeIfPresent(Double.self, forKey: .now)) ?? nil
        let all = try c.decode(LossyList<SportEvent>.self, forKey: .events).items
        events = all.filter { !$0.channels.isEmpty && $0.endTime > $0.startTime }
    }
}

/// An array that skips elements that fail to decode.
nonisolated struct LossyList<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    private struct Skip: Decodable {}
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) { items.append(item) }
            else { _ = try? container.decode(Skip.self) }
        }
        self.items = items
    }
}

private extension KeyedDecodingContainer {
    /// A string that may arrive as a number (ids).
    nonisolated func decodeLenientString(_ key: Key) throws -> String {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "no string or number"))
    }
}

/// What the Sport tab and Home draw, in time order.
nonisolated struct SportBuckets: Equatable, Sendable {
    /// On now (start ≤ now < end).
    var live: [SportEvent] = []
    /// Starting within the next hour.
    var soon: [SportEvent] = []
    /// Later today (the device's calendar day), after the next hour.
    var later: [SportEvent] = []
    /// Build 32 (72 h horizon): tomorrow, after the next hour.
    var tomorrow: [SportEvent] = []
    /// Build 32: each later day in the window ("Saturday", "Sunday"), in order.
    var days: [SportDay] = []
    /// Build 31: replays (`kind == "replay"`) that have not ended: on now
    /// first, then by start. Never in the buckets above or on Home.
    var replays: [SportEvent] = []

    /// Every event and replay (the league chips count and filter them all).
    var all: [SportEvent] { live + soon + later + tomorrow + days.flatMap(\.events) + replays }
    var isEmpty: Bool { all.isEmpty }
}

/// Build 32: one day's events after tomorrow, titled with its weekday.
nonisolated struct SportDay: Equatable, Sendable {
    /// The day's start in the device's calendar.
    var day: Date
    /// "Saturday".
    var title: String
    var events: [SportEvent]
}

/// Everything the Sport tab draws, built once per (events, minute): the
/// buckets, the chips and each league's filtered rows. Equatable so an
/// unchanged rebuild is not republished.
nonisolated struct SportSnapshot: Equatable, Sendable {
    /// The start of the minute the rows were built at.
    var clock: Date
    var buckets = SportBuckets()
    var leagues: [String] = []
    var leagueCounts: [String: Int] = [:]
    var byLeague: [String: SportBuckets] = [:]

    func rows(league: String?) -> SportBuckets {
        guard let league else { return buckets }
        return byLeague[league] ?? SportRows.filter(buckets, league: league)
    }
}

nonisolated enum SportRows {
    /// The start of `date`'s minute: the granularity the rows are drawn at.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// The buckets plus the chips and per-league rows, from one pass.
    static func snapshot(_ events: [SportEvent], now: Date, calendar: Calendar = .current) -> SportSnapshot {
        let buckets = buckets(events, now: now, calendar: calendar)
        let all = buckets.all
        let leagues = leagues(all)
        var byLeague: [String: SportBuckets] = [:]
        for league in leagues { byLeague[league] = filter(buckets, league: league) }
        return SportSnapshot(clock: now, buckets: buckets, leagues: leagues, leagueCounts: leagueCounts(all),
                             byLeague: byLeague)
    }

    /// "Starting soon" looks this far ahead.
    static let soonWindow: TimeInterval = 3600
    /// "Watch when it starts" just plays when the event is this close.
    static let watchNowWindow: TimeInterval = 300
    static let homeLimit = 20

    /// Live, soon, later today, tomorrow and each later day (the device's
    /// calendar days), each by start time (ties keep the server's order);
    /// replays on their own, on now first; ended ones are dropped.
    static func buckets(_ events: [SportEvent], now: Date, soonWindow: TimeInterval = soonWindow,
                        calendar: Calendar = .current) -> SportBuckets {
        let ordered = events.enumerated().sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }.map(\.element)
        var result = SportBuckets()
        let horizon = now.addingTimeInterval(soonWindow)
        let today = calendar.startOfDay(for: now)
        var upcomingReplays: [SportEvent] = []
        for event in ordered where event.end > now {
            if event.isReplay {
                if event.start <= now { result.replays.append(event) } else { upcomingReplays.append(event) }
                continue
            }
            if event.start <= now { result.live.append(event); continue }
            if event.start <= horizon { result.soon.append(event); continue }
            let day = calendar.startOfDay(for: event.start)
            switch calendar.dateComponents([.day], from: today, to: day).day ?? 0 {
            case ...0: result.later.append(event)
            case 1: result.tomorrow.append(event)
            default:
                if let index = result.days.firstIndex(where: { $0.day == day }) {
                    result.days[index].events.append(event)
                } else {
                    result.days.append(SportDay(day: day, title: weekday(day, calendar: calendar), events: [event]))
                }
            }
        }
        result.days.sort { $0.day < $1.day }
        result.replays += upcomingReplays
        return result
    }

    /// "Saturday" in the calendar's time zone and the user's language.
    static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Distinct leagues, most events first (ties: first seen first).
    static func leagues(_ events: [SportEvent]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for event in events {
            if counts[event.league] == nil { order.append(event.league) }
            counts[event.league, default: 0] += 1
        }
        return order.enumerated().sorted { (-(counts[$0.element] ?? 0), $0.offset) < (-(counts[$1.element] ?? 0), $1.offset) }.map(\.element)
    }

    /// Event counts by league (for chip badges).
    static func leagueCounts(_ events: [SportEvent]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.league, default: 0] += 1
        }
        return counts
    }

    /// Only one league's events (nil: all).
    static func filter(_ buckets: SportBuckets, league: String?) -> SportBuckets {
        guard let league else { return buckets }
        let days = buckets.days.map { SportDay(day: $0.day, title: $0.title, events: $0.events.filter { $0.league == league }) }
        return SportBuckets(live: buckets.live.filter { $0.league == league },
                            soon: buckets.soon.filter { $0.league == league },
                            later: buckets.later.filter { $0.league == league },
                            tomorrow: buckets.tomorrow.filter { $0.league == league },
                            days: days.filter { !$0.events.isEmpty },
                            replays: buckets.replays.filter { $0.league == league })
    }

    /// Home's "Sport now & next": live events, then those within the hour.
    static func nowAndNext(_ buckets: SportBuckets, limit: Int = homeLimit) -> [SportEvent] {
        Array((buckets.live + buckets.soon).prefix(limit))
    }

    /// 0…1 through the event.
    static func progress(_ event: SportEvent, now: Date) -> Double {
        let length = event.end.timeIntervalSince(event.start)
        guard length > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(event.start) / length))
    }

    /// "12 min", "1 h 5 min", "2 h" (rounded up, so 30 s is "1 min").
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "starts in 12 min" (or "starting now").
    static func startsIn(_ event: SportEvent, now: Date) -> String {
        let seconds = event.start.timeIntervalSince(now)
        return seconds > 0 ? "starts in \(span(seconds))" : "starting now"
    }

    /// "ends in 40 min" (or "ended").
    static func endsIn(_ event: SportEvent, now: Date) -> String {
        let seconds = event.end.timeIntervalSince(now)
        return seconds > 0 ? "ends in \(span(seconds))" : "ended"
    }

    /// The card's time line: "Live · ends in 40 min" ("On now · …" for a
    /// replay), "8:30 pm · in 25 min" today, or "Sat 1:30 pm" on a later
    /// day (build 32).
    static func timing(_ event: SportEvent, now: Date, calendar: Calendar = .current) -> String {
        if event.isLive(at: now) { return "\(event.isReplay ? "On now" : "Live") · \(endsIn(event, now: now))" }
        if event.end <= now { return "Ended" }
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        guard calendar.isDate(event.start, inSameDayAs: now) else {
            var day = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated)
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            return "\(event.start.formatted(day)) \(event.start.formatted(time))"
        }
        let seconds = event.start.timeIntervalSince(now)
        return "\(event.start.formatted(time)) · in \(span(seconds))"
    }

    /// "+2 more channels" (nil with one channel).
    static func moreChannels(_ event: SportEvent) -> String? {
        let extra = event.channels.count - 1
        guard extra > 0 else { return nil }
        return extra == 1 ? "+1 more channel" : "+\(extra) more channels"
    }

    /// Build 33: whether choosing a channel for this event plays it at
    /// once — live, or starting within `watchNowWindow` — or should offer a
    /// choice (Record / Watch when it starts) instead. One rule shared by
    /// the event page's primary action, its channel list and the long-press
    /// channel picker, so all three agree.
    static func playsChannelNow(_ event: SportEvent, now: Date) -> Bool {
        event.isLive(at: now) || event.start.timeIntervalSince(now) <= watchNowWindow
    }
}
