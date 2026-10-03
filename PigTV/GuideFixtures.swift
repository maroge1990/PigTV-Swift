#if DEBUG
import Foundation
import UIKit

// Synthetic guide data for offline UI iteration (the R14 block-slide work has
// no server in the simulator). Launch with PIGTV_UI_TEST_SCREEN=guide.
enum GuideFixtures {
    static func categories() -> [Category] {
        let base = [Category(rawID: "sports", sourceId: 1, name: "Sports", channelCount: 6, sport: true),
         Category(rawID: "movies", sourceId: 1, name: "Movies", channelCount: 4),
         Category(rawID: "news", sourceId: 1, name: "News", channelCount: 3),
         Category(rawID: "kids", sourceId: 1, name: "Kids", channelCount: 1)]
        guard ProcessInfo.processInfo.environment["PIGTV_UI_TEST_LONG_CATEGORIES"] == "1" else { return base }
        return base + (1...16).map { Category(rawID: "review-\($0)", sourceId: 1, name: "Category \($0)", channelCount: 0) }
    }

    // Build 33: how far past "now" the fixture's synthetic programmes reach
    // — comfortably past a single loaded day (`GuideNavigation.loadedDuration`,
    // 24 h), so the offline "moves right past 24 h" UI test has next-day
    // programmes to navigate into with no real server to extend from. Kept
    // modest so the 1 000-channel perf fixtures stay about as heavy as before.
    static let forwardHorizon: TimeInterval = 26 * 3600

    private static let names: [(String, String)] = [
        ("Sky Sports Main Event", "sports"), ("TSN 1", "sports"), ("Fox Footy 504", "sports"),
        ("ESPN", "sports"), ("Sky Sports F1", "sports"), ("beIN Sports 1", "sports"),
        ("HBO", "movies"), ("Sky Cinema Premiere", "movies"), ("Film4", "movies"), ("TCM", "movies"),
        ("BBC News", "news"), ("Sky News", "news"), ("CNN International", "news"),
        ("CBeebies", "kids")]

    static func channels(logos: Bool = false) -> [GuideChannel] {
        let step = 1000.0 // ms per second
        let now = Date().timeIntervalSince1970 * step
        let hour = 3600.0 * step
        // Programme titles cycle so cells read differently as you scroll.
        let titles = ["Live Match", "Studio Analysis", "Highlights", "Press Conference",
                      "Classic Replay", "Feature Film", "The Headlines", "Documentary",
                      "Talk Show", "Late Bulletin", "Morning Show", "Weekend Special"]
        return names.enumerated().map { index, entry in
            let (name, category) = entry
            var programmes: [GuideProgramme] = []
            // One channel deliberately has no EPG (placeholder test).
            if index != 9 {
                // Start six hours ago so finished programmes exist to the left.
                var t = (now - 6 * hour).rounded()
                var k = index
                while t < now + forwardHorizon * step {
                    // Channel 2 carries a long (3h) live sports programme spanning now.
                    let longLive = (index == 2 && t <= now && t + 3 * hour > now)
                    let lengths = [0.5, 1.0, 1.5, 2.0]
                    let length = longLive ? 3.0 : lengths[k % lengths.count]
                    // Real EPGs often start a minute or two off the half hour.
                    let end = t + length * hour - (k % 3 == 0 ? 90 * step : 0)
                    programmes.append(GuideProgramme(title: logos ? homeTitle(category, k) : "\(titles[k % titles.count]) \(index + 1)",
                        description: "Synthetic programme for layout testing on \(name). It runs for \(Int(length * 60)) minutes.",
                        startTime: t, endTime: end))
                    // Providers sometimes list a programme twice (merged EPG
                    // sources); the grid must still navigate past it (R19).
                    if k % 2 == 0 {
                        programmes.append(GuideProgramme(title: "\(titles[k % titles.count]) \(index + 1)",
                            description: nil, startTime: t, endTime: end))
                    }
                    t = end
                    k += 1
                }
            }
            return GuideChannel(rawID: "ch\(index)", sourceId: 1, name: name,
                                logo: logos ? logoKey(index) : nil, category: category, programmes: programmes,
                                number: 501 + index)
        }
    }

    /// Build 31: PIGTV_UI_TEST_CHANNELS=<n> enlarges the fixture guides to
    /// n channels (copies of the 14 with new ids, names and numbers), to
    /// measure tab switching on a realistic lineup (~1,000 channels).
    static var requestedCount: Int? {
        ProcessInfo.processInfo.environment["PIGTV_UI_TEST_CHANNELS"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    static func enlarged(_ base: [GuideChannel], to count: Int?) -> [GuideChannel] {
        guard let count, count > base.count, !base.isEmpty else { return base }
        return base + (base.count..<count).map { index in
            let source = base[index % base.count]
            return GuideChannel(rawID: "ch\(index)", sourceId: source.sourceId, name: "\(source.name) \(index / base.count + 1)",
                                logo: source.logo, category: source.category, programmes: source.programmes,
                                number: 501 + index)
        }
    }

    // MARK: Home fixture (PIGTV_UI_TEST_SCREEN=home)

    /// Plausible titles per category for the Home screenshots.
    private static func homeTitle(_ category: String, _ k: Int) -> String {
        let pool: [String]
        switch category {
        case "sports": pool = ["LIVE: Premier League", "Super Rugby Highlights", "AFL: Round 12 Live", "Golf Central",
                               "F1: Practice 2 Live", "NRL 360", "Test Cricket: Day 3", "The Back Page"]
        case "movies": pool = ["The Long Way Home", "Northern Lights", "A Quiet Harbour", "Midnight Express Train", "Paper Moons"]
        case "news": pool = ["The World Tonight", "Business Live", "Weather Watch", "The Briefing", "Newsnight"]
        default: pool = ["Bluey", "Hey Duggee", "Octonauts", "Peppa Pig"]
        }
        return pool[k % pool.count]
    }

    private static func logoKey(_ index: Int) -> String { "fixture-logo-\(index)" }

    /// Synthetic wordmark logos (a coloured tile with the channel's name),
    /// put straight into ChannelArtwork's cache so nothing is fetched.
    @MainActor static func preloadLogos() {
        let colours: [UIColor] = [
            UIColor(red: 0.05, green: 0.28, blue: 0.62, alpha: 1), UIColor(red: 0.78, green: 0.10, blue: 0.14, alpha: 1),
            UIColor(red: 0.10, green: 0.55, blue: 0.30, alpha: 1), UIColor(red: 0.85, green: 0.20, blue: 0.10, alpha: 1),
            UIColor(red: 0.60, green: 0.05, blue: 0.10, alpha: 1), UIColor(red: 0.42, green: 0.14, blue: 0.62, alpha: 1),
            UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1), UIColor(red: 0.12, green: 0.36, blue: 0.70, alpha: 1),
            UIColor(red: 0.55, green: 0.12, blue: 0.40, alpha: 1), UIColor(red: 0.70, green: 0.55, blue: 0.10, alpha: 1),
            UIColor(red: 0.62, green: 0.08, blue: 0.08, alpha: 1), UIColor(red: 0.00, green: 0.40, blue: 0.60, alpha: 1),
            UIColor(red: 0.80, green: 0.10, blue: 0.12, alpha: 1), UIColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 1)]
        let size = CGSize(width: 320, height: 180)
        for (index, entry) in names.enumerated() {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 22)
                colours[index % colours.count].setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 22).fill()
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let text = entry.0.uppercased() as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 30, weight: .heavy), .foregroundColor: UIColor.white,
                    .paragraphStyle: style]
                let bounds = text.boundingRect(with: CGSize(width: rect.width - 24, height: rect.height),
                                               options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
                text.draw(with: CGRect(x: rect.minX + 12, y: rect.midY - bounds.height / 2,
                                       width: rect.width - 24, height: bounds.height),
                          options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            }
            ChannelArtwork.preload(image, for: logoKey(index))
        }
    }

    /// Build 32, the Top Shelf cards fixture: logos at other sizes than the
    /// guide's 320 px thumbnails. Fox Footy (the first favourite) is a
    /// large "full size" logo (drawn capped to the card's logo box), Sky
    /// Sports Main Event a small 160 px one (kept small, never enlarged),
    /// HBO a dark wordmark on a transparent background (put on a plate).
    @MainActor static func topShelfLogo(_ logo: String) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func tile(_ size: CGSize, _ colour: UIColor, _ text: String, font: CGFloat, clear: Bool = false) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let rect = CGRect(origin: .zero, size: size)
                if !clear {
                    colour.setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: size.height * 0.12).fill()
                }
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: font, weight: .heavy),
                    .foregroundColor: clear ? colour : UIColor.white, .paragraphStyle: style]
                let bounds = (text as NSString).boundingRect(with: rect.size, options: .usesLineFragmentOrigin,
                                                             attributes: attributes, context: nil)
                (text as NSString).draw(with: CGRect(x: 0, y: rect.midY - bounds.height / 2, width: rect.width, height: bounds.height),
                                        options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            }
        }
        switch logo {
        case logoKey(2): return tile(CGSize(width: 1200, height: 540), UIColor(red: 0.10, green: 0.55, blue: 0.30, alpha: 1),
                                     "FOX FOOTY", font: 150)
        case logoKey(0): return tile(CGSize(width: 160, height: 72), UIColor(red: 0.05, green: 0.28, blue: 0.62, alpha: 1),
                                     "SKY SPORTS", font: 22)
        case logoKey(6): return tile(CGSize(width: 600, height: 240), UIColor(white: 0.08, alpha: 1), "HBO", font: 170, clear: true)
        default: return nil
        }
    }

    static func favourites(from guide: [GuideChannel]) -> [GuideChannel] {
        [2, 0, 6, 10, 7, 4, 13].compactMap { guide.indices.contains($0) ? guide[$0] : nil }
    }

    static func recent(from guide: [GuideChannel]) -> [GuideChannel] {
        [2, 11, 0, 8, 5, 12, 3].compactMap { guide.indices.contains($0) ? guide[$0] : nil }
    }

    @MainActor static func lastWatched(from guide: [GuideChannel]) -> LastWatched? {
        guard guide.indices.contains(2) else { return nil }
        let row = guide[2]
        return LastWatched(sourceId: row.sourceId, rawID: row.rawID, name: row.name, number: row.number,
                           logo: row.logo, category: row.category, stableId: row.stableId)
    }

    /// A programme later today on channel 0, with a schedule for it.
    static func scheduledProgramme(in guide: [GuideChannel]) -> (channel: GuideChannel, programme: GuideProgramme) {
        let channel = guide[0]
        let now = Date()
        let later = channel.programmes.filter { $0.start > now.addingTimeInterval(2 * 3600) }.sorted { $0.start < $1.start }
        return (channel, later.first ?? channel.programmes[0])
    }

    @MainActor static func addSchedules(to model: BrowseModel) {
        let target = scheduledProgramme(in: model.guide)
        let json = #"[{"id":90,"title":"\#(target.programme.title)","channel_name":"\#(target.channel.name)","program_start":\#(Int64(target.programme.startTime)),"program_end":\#(Int64(target.programme.endTime)),"status":"scheduled"}]"#
        model.schedules = (try? JSONDecoder().decode([ScheduledRecording].self, from: Data(json.utf8))) ?? []
    }

    static func markers() -> RecordingMarkers? {
        try? JSONDecoder().decode(RecordingMarkers.self, from: Data(#"{"status":"completed","markers":[{"id":1,"startMs":612000,"endMs":795000,"type":"ad"},{"id":2,"startMs":1420000,"endMs":1590000,"type":"ad"},{"id":3,"startMs":2210000,"endMs":2365000,"type":"ad"}]}"#.utf8))
    }

    static func recordings() -> [Recording] {
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 3_600_000.0
        let rows = [
            #"{"id":31,"title":"Grand Final Replay","channel_name":"Fox Footy 504","started_at":\#(now - 0.6 * hour),"status":"recording","duration_sec":2100}"#,
            #"{"id":30,"title":"The Headlines","channel_name":"BBC News","started_at":\#(now - 20 * hour),"status":"completed","duration_sec":1800,"file_size_bytes":1288490188,"ad_detect_status":"completed"}"#,
            #"{"id":29,"title":"Feature Film: The Long Way Home","channel_name":"HBO","started_at":\#(now - 30 * hour),"status":"completed","duration_sec":6900}"#,
            #"{"id":28,"title":"Documentary: Deep Oceans","channel_name":"Sky News","started_at":\#(now - 52 * hour),"status":"completed","duration_sec":3300}"#,
            #"{"id":27,"title":"Classic Replay","channel_name":"Sky Sports Main Event","started_at":\#(now - 75 * hour),"status":"completed","duration_sec":5400}"#,
            #"{"id":26,"title":"Weekend Special","channel_name":"TCM","started_at":\#(now - 4 * hour),"status":"scheduled"}"#]
        return rows.compactMap { try? JSONDecoder().decode(Recording.self, from: Data($0.utf8)) }
    }

    // MARK: Sport fixture (C-I, PIGTV_UI_TEST_SCREEN=sport)

    /// Plausible events on the fixture's sport channels: three live (one on
    /// three channels), three starting within the hour, one later on.
    static func sportEvents(from guide: [GuideChannel]) -> [SportEvent] {
        // On the five minutes, as real kick-off times are.
        let now = (Date().timeIntervalSince1970 / 300).rounded(.down) * 300_000
        let minute = 60_000.0
        func on(_ index: Int, _ quality: SportQuality?) -> SportEventChannel? {
            guard guide.indices.contains(index) else { return nil }
            let row = guide[index]
            return SportEventChannel(sourceId: row.sourceId, rawID: row.rawID, stableId: row.stableId, name: row.name,
                                     number: row.number, logo: row.logo, quality: quality)
        }
        /// Minutes from now to `hour` (local) `days` days from today.
        func dayOffset(_ days: Int, hour: Double) -> Double {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
            return (day.addingTimeInterval(hour * 3600).timeIntervalSince1970 * 1000 - now) / minute
        }
        func event(_ id: String, _ title: String, _ league: String, from: Double, minutes: Double,
                   _ channels: [SportEventChannel?], kind: SportEventKind = .event) -> SportEvent {
            SportEvent(id: id, title: title, league: league, startTime: now + from * minute,
                       endTime: now + (from + minutes) * minute, channels: channels.compactMap { $0 }, kind: kind)
        }
        return [
            event("nfl-kc-buf", "Kansas City Chiefs vs Buffalo Bills", "NFL", from: -70, minutes: 200,
                  [on(0, .uhd), on(3, .hd), on(1, .hd)]),
            event("afl-coll-carl", "AFL: Collingwood v Carlton", "AFL", from: -40, minutes: 150, [on(2, .hd)]),
            event("f1-sgp-q", "F1: Singapore Grand Prix Qualifying", "F1", from: -15, minutes: 75, [on(4, .uhd), on(5, .hd)]),
            event("nrl-pf", "NRL Preliminary Final: Storm v Panthers", "NRL", from: 25, minutes: 120,
                  [on(5, .hd), on(1, .hd), on(3, .sd)]),
            event("nfl-phi-dal", "Philadelphia Eagles vs Dallas Cowboys", "NFL", from: 40, minutes: 195, [on(3, .hd), on(0, .hd)]),
            event("afl-bris-geel", "AFL: Brisbane Lions v Geelong Cats", "AFL", from: 55, minutes: 150, [on(2, .hd)]),
            event("nfl-sf-sea", "San Francisco 49ers vs Seattle Seahawks", "NFL", from: 190, minutes: 195, [on(0, .uhd), on(3, .hd)]),
            // Build 32 (72 h): tomorrow and the day after, local time.
            event("afl-tomorrow", "AFL: Sydney Swans v GWS Giants", "AFL", from: dayOffset(1, hour: 13.5), minutes: 150, [on(2, .hd)]),
            event("nfl-tomorrow", "Green Bay Packers vs Chicago Bears", "NFL", from: dayOffset(1, hour: 19), minutes: 195,
                  [on(0, .uhd), on(3, .hd)]),
            event("nrl-day-after", "NRL Grand Final: Storm v Broncos", "NRL", from: dayOffset(2, hour: 19.5), minutes: 150,
                  [on(5, .hd), on(1, .hd)]),
            event("f1-day-after", "F1: Singapore Grand Prix", "F1", from: dayOffset(2, hour: 22), minutes: 120, [on(4, .uhd)]),
            // Build 31: replays (their own section; never on Home).
            event("rp-gb-nyj", "Packers v Jets · Week 2", "NFL", from: -35, minutes: 180, [on(1, .hd)], kind: .replay),
            event("rp-afl-gf", "AFL Grand Final 2025", "AFL", from: 95, minutes: 180, [on(2, .hd), on(5, .sd)], kind: .replay),
        ]
    }

    /// Production-sized sport fixture: `count` events (default 215) with ~71%
    /// marked as replays, remaining spread across live, soon, later, and
    /// future days. Uses 8 distinct leagues and reuses guide's sport channels.
    /// Deterministic: no randomness. Selected when PIGTV_UI_TEST_SPORT_EVENTS
    /// env var is set to a number.
    static func largeSportEvents(from guide: [GuideChannel], count: Int = 215, now date: Date = Date()) -> [SportEvent] {
        // On the five minutes, as real kick-off times are; `date` lets a test fix the clock.
        let now = (date.timeIntervalSince1970 / 300).rounded(.down) * 300_000
        let minute = 60_000.0
        let leagues = ["NFL", "AFL", "NRL", "F1", "MLB", "NBA", "Cricket", "Rugby"]
        let titles = ["Match", "Championship", "Final", "Playoff", "Quarter-Final", "Semi-Final",
                     "Classic", "Special", "Live Coverage", "Qualifying", "Practice", "Sprint"]
        let qualities: [SportQuality] = [.uhd, .hd, .sd]

        func on(_ index: Int, _ quality: SportQuality?) -> SportEventChannel? {
            guard guide.indices.contains(index) else { return nil }
            let row = guide[index]
            return SportEventChannel(sourceId: row.sourceId, rawID: row.rawID, stableId: row.stableId, name: row.name,
                                     number: row.number, logo: row.logo, quality: quality)
        }

        func dayOffset(_ days: Int, hour: Double) -> Double {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
            return (day.addingTimeInterval(hour * 3600).timeIntervalSince1970 * 1000 - now) / minute
        }

        func event(_ id: String, _ title: String, _ league: String, from: Double, minutes: Double,
                   _ channels: [SportEventChannel?], kind: SportEventKind = .event) -> SportEvent {
            SportEvent(id: id, title: title, league: league, startTime: now + from * minute,
                       endTime: now + (from + minutes) * minute, channels: channels.compactMap { $0 }, kind: kind)
        }

        var events: [SportEvent] = []
        let replayCount = Int((Double(count) * 0.71).rounded())
        let nonReplayCount = count - replayCount

        // Distribute non-replay events across time buckets (count: 62 for 215 total)
        let live = 3, soon = 7, later = 10, tomorrow = 15, day2 = 12, day3 = 10, day4plus = 5

        // Generate live events
        for i in 0..<live {
            let minuteOffset = Double(-10 - i * 20) // started, still on
            let league = leagues[i % leagues.count]
            let title = titles[i % titles.count]
            let channels = [on(i % 6, qualities[i % qualities.count]), on((i + 1) % 6, .hd)]
            events.append(event("live-\(i)", "\(league): \(title)", league, from: minuteOffset, minutes: 150, channels))
        }

        // Generate soon events (within 1 hour)
        for i in 0..<soon {
            let minuteOffset = Double(20 + i * 8)
            let league = leagues[(i + live) % leagues.count]
            let title = titles[(i + live) % titles.count]
            let channels = [on((i + 2) % 6, qualities[(i + 1) % qualities.count])]
            events.append(event("soon-\(i)", "\(league): \(title)", league, from: minuteOffset, minutes: 120, channels))
        }

        // Generate later today events
        for i in 0..<later {
            let minuteOffset = Double(90 + i * 6) // past the hour-long soon window, still today
            let league = leagues[(i + live + soon) % leagues.count]
            let title = titles[(i + live + soon) % titles.count]
            let channels = [on((i + 3) % 6, qualities[i % qualities.count])]
            events.append(event("later-\(i)", "\(league): \(title)", league, from: minuteOffset, minutes: 100, channels))
        }

        // Generate tomorrow events
        for i in 0..<tomorrow {
            let hour = Double(12 + (i % 12))
            let league = leagues[(i + live + soon + later) % leagues.count]
            let title = titles[(i + live + soon + later) % titles.count]
            let channels = [on((i + 4) % 6, qualities[(i + 2) % qualities.count])]
            events.append(event("tom-\(i)", "\(league): \(title)", league, from: dayOffset(1, hour: hour), minutes: 120, channels))
        }

        // Generate day+2 events
        for i in 0..<day2 {
            let hour = Double(12 + (i % 12))
            let league = leagues[(i + live + soon + later + tomorrow) % leagues.count]
            let title = titles[(i + live + soon + later + tomorrow) % titles.count]
            let channels = [on((i + 5) % 6, qualities[i % qualities.count])]
            events.append(event("day2-\(i)", "\(league): \(title)", league, from: dayOffset(2, hour: hour), minutes: 150, channels))
        }

        // Generate day+3 events
        for i in 0..<day3 {
            let hour = Double(14 + (i % 10))
            let league = leagues[(i + live + soon + later + tomorrow + day2) % leagues.count]
            let title = titles[(i + live + soon + later + tomorrow + day2) % titles.count]
            let channels = [on(i % 6, qualities[(i + 1) % qualities.count])]
            events.append(event("day3-\(i)", "\(league): \(title)", league, from: dayOffset(3, hour: hour), minutes: 100, channels))
        }

        // Generate day+4+ events
        for i in 0..<day4plus {
            let hour = Double(15 + (i % 9))
            let league = leagues[(i + live + soon + later + tomorrow + day2 + day3) % leagues.count]
            let title = titles[(i + live + soon + later + tomorrow + day2 + day3) % titles.count]
            let channels = [on((i + 1) % 6, qualities[i % qualities.count])]
            events.append(event("day4-\(i)", "\(league): \(title)", league, from: dayOffset(4, hour: hour), minutes: 110, channels))
        }

        // The buckets above hold 62, the live feed's share at 215. Other sizes keep the
        // ~71 % replay ratio: trim, or spread the extra over the following days.
        if events.count > nonReplayCount { events.removeLast(events.count - nonReplayCount) }
        for i in 0..<max(0, nonReplayCount - events.count) {
            let league = leagues[i % leagues.count]
            let title = titles[i % titles.count]
            events.append(event("extra-\(i)", "\(league): \(title)", league,
                                from: dayOffset(2 + i % 3, hour: Double(10 + i % 12)), minutes: 120, [on(i % 6, .hd)]))
        }

        // Generate replay events (remaining to reach `count`)
        for i in 0..<replayCount {
            let minuteOffset = Double(-1 - (i % 60)) // started, so listed under Replays
            let league = leagues[(i + nonReplayCount) % leagues.count]
            let title = titles[(i + nonReplayCount) % titles.count]
            let channels = [on((i % 6), qualities[(i + 2) % qualities.count])]
            events.append(event("rp-\(i)", "\(league): \(title) Replay", league, from: minuteOffset, minutes: 240, channels, kind: .replay))
        }

        return events
    }

    static func user() -> User {
        (try? JSONDecoder().decode(User.self, from: Data(#"{"id":1,"username":"tester","role":"user"}"#.utf8)))
            ?? (try! JSONDecoder().decode(User.self, from: Data(#"{"id":0,"username":"","role":""}"#.utf8)))
    }
}
#endif
