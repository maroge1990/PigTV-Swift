#if DEBUG
import Foundation
import UIKit

/// #362: a production-shaped TV Guide for the speed tests (PIGTV_UI_TEST_SCREEN=guide with
/// PIGTV_UI_TEST_GUIDE_SHAPE=production; PIGTV_UI_TEST_CHANNELS, default 1,250). Each channel has a programme for every
/// hour of the loaded day (lengths cycle 30–90 minutes, 8 in 8 hours, so about 25 a day), descriptions of 150–300
/// characters, some new episodes, a logo of its own and one of 40 categories (three of them sport).
///
/// Nothing here touches a network. The app's own client talks to `ProductionGuideServer`, a URLProtocol in the client's
/// session that answers like the server, so logos take the real path (the artwork session, the disk store, the
/// thumbnail decode, the decoded-logo cache; only the bytes are drawn here) and, with PIGTV_UI_TEST_GUIDE_PAGED=1, the
/// guide arrives through the real paging (`library/guide/version`, then `library/guide` pages of 500, each after the
/// first PIGTV_UI_TEST_GUIDE_PAGE_DELAY_MS later, default 1000). Without paging the rows are put in place at once, as a finished
/// load leaves them, and a forward extension still goes through the same pages. Every programme is a pure function of
/// its channel and its time, so any window or slice the app asks for agrees with any other.
nonisolated enum ProductionGuideFixture {
    static let defaultChannels = 1250
    static let pageSize = 500
    static let host = "127.0.0.1"
    static let port = 3000
    static let address = "http://127.0.0.1:3000"
    static let logoPrefix = "/api/logo/fixture-prod-"

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var requested: Bool { environment["PIGTV_UI_TEST_GUIDE_SHAPE"] == "production" }
    static var paged: Bool { environment["PIGTV_UI_TEST_GUIDE_PAGED"] == "1" }
    static var channelCount: Int {
        environment["PIGTV_UI_TEST_CHANNELS"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? defaultChannels
    }
    static var pageDelay: TimeInterval {
        (environment["PIGTV_UI_TEST_GUIDE_PAGE_DELAY_MS"].flatMap(Double.init) ?? 1000) / 1000
    }

    /// Where a loaded day starts, as the app opens it (`GuideNavigation`: the half hour, two hours back).
    static func window(now: Date = Date()) -> Date {
        GuideNavigation.rounded(now).addingTimeInterval(-GuideNavigation.leadIn)
    }

    // MARK: Categories

    static let categoryNames = [
        "Sport", "Football", "Motorsport", "News", "Business", "Movies", "Drama", "Comedy", "Documentary", "Kids",
        "Music", "Lifestyle", "Food", "Travel", "Science", "History", "Nature", "Entertainment", "Reality", "Crime",
        "Faith", "Shopping", "Local", "Regional", "International", "UK", "USA", "Australia", "New Zealand", "Canada",
        "Ireland", "India", "Asia", "Europe", "Latin", "Arabic", "4K", "Radio", "Classic TV", "Learning"]
    static let sportCategories = 3

    static func categoryID(_ index: Int) -> String { "pcat\(index % categoryNames.count)" }

    static func categories(count: Int = channelCount) -> [Category] {
        categoryNames.indices.map { index in
            let members = count > index ? (count - 1 - index) / categoryNames.count + 1 : 0
            return Category(rawID: "pcat\(index)", sourceId: 1, name: categoryNames[index], channelCount: members,
                            sport: index < sportCategories)
        }
    }

    // MARK: Channels and programmes

    private static let brands = [
        "Sky Sports Main Event", "Fox Footy", "beIN Sports", "ESPN", "TSN", "Eurosport", "BBC One", "BBC Two", "ITV",
        "Channel 4", "Channel 5", "Sky Atlantic", "Sky Cinema Premiere", "HBO", "Showtime", "Film4", "TCM", "AMC",
        "Discovery", "National Geographic", "History", "Animal Planet", "CNN International", "Sky News", "BBC News",
        "Al Jazeera English", "Bloomberg", "CNBC", "Nickelodeon", "Cartoon Network", "CBeebies", "Disney Junior",
        "MTV", "VH1", "Comedy Central", "Food Network", "Travel Channel", "HGTV", "Crime+Investigation", "ABC",
        "Nine", "Seven", "Ten", "SBS", "TVNZ 1", "Three", "CBC", "RTÉ One", "Star Plus", "Sony Max"]

    static func name(_ index: Int) -> String {
        let brand = brands[index % brands.count]
        return index < brands.count ? brand : "\(brand) \(index / brands.count + 1)"
    }

    static func logoPath(_ index: Int) -> String { "\(logoPrefix)\(index)" }

    static func channel(_ index: Int, from: Double, to: Double) -> GuideChannel {
        GuideChannel(rawID: "p\(index)", sourceId: 1, name: name(index), logo: logoPath(index), category: categoryID(index),
                     programmes: programmes(channel: index, from: from, to: to), stableId: "prod-\(index)",
                     number: 101 + index, quality: index % 12 == 0 ? "UHD" : index % 9 == 0 ? "SD" : "HD")
    }

    /// Every channel, with the programmes overlapping `window` … `window` + a loaded day.
    static func channels(count: Int = channelCount, window: Date) -> [GuideChannel] {
        let from = window.timeIntervalSince1970 * 1000
        let to = from + GuideNavigation.loadedDuration * 1000
        return (0..<count).map { channel($0, from: from, to: to) }
    }

    /// Programme lengths in minutes: 8 programmes in 8 hours, the cycle shifted per channel by a quarter hour step.
    static let cycleMinutes: [Double] = [60, 30, 90, 60, 45, 75, 60, 60]
    private static let minute = 60_000.0

    /// The programmes overlapping `from` ..< `to` (epoch ms), as the server answers a window.
    static func programmes(channel: Int, from: Double, to: Double) -> [GuideProgramme] {
        let cycle = cycleMinutes.reduce(0, +) * minute
        let offset = Double((channel * 17) % 32) * 15 * minute
        let first = ((from - offset) / cycle).rounded(.down)
        var t = offset + first * cycle
        var k = Int(first) * cycleMinutes.count
        var result: [GuideProgramme] = []
        while t < to {
            let end = t + cycleMinutes[((k % cycleMinutes.count) + cycleMinutes.count) % cycleMinutes.count] * minute
            if end > from { result.append(programme(channel: channel, k: k, start: t, end: end)) }
            t = end
            k += 1
        }
        return result
    }

    private static let titles = [
        "Live: Premier League", "Super Rugby Highlights", "AFL: Round 12", "Golf Central", "F1: Practice 2", "NRL 360",
        "Test Cricket: Day 3", "The Back Page", "The World Tonight", "Business Live", "Weather Watch", "The Briefing",
        "Newsnight", "The Long Way Home", "Northern Lights", "A Quiet Harbour", "Midnight Express Train", "Paper Moons",
        "Grand Designs", "MasterChef", "Location, Location", "Bluey", "Hey Duggee", "Octonauts", "Planet Earth",
        "Deep Oceans", "Air Crash Investigation", "Gold Rush", "Top Gear", "QI", "Would I Lie to You?", "Taskmaster",
        "Line of Duty", "Vera", "Midsomer Murders", "Coronation Street", "Neighbours", "Home and Away", "Antiques Roadshow",
        "Gardeners' World"]

    private static let sentences = [
        "A fresh look at the week's biggest stories with guests from around the country.",
        "The team heads north, where an old rivalry threatens to spill over before the final whistle.",
        "Experts weigh in on what went wrong, and what has to change before next season begins.",
        "An unexpected visitor turns a quiet weekend into something nobody in the village will forget.",
        "Filmed over three years, this is the story of one family and the land they refuse to leave.",
        "Highlights, interviews and analysis from every match of the round, with the goals that mattered.",
        "Behind the scenes with the people who keep the city moving through the longest night of the year.",
        "Two strangers, one shared secret and a train that never seems to reach its last stop.",
        "The presenters take on a challenge that goes badly wrong in the most entertaining way possible.",
        "From the archives: a classic episode restored, with a new introduction from the original cast.",
        "Our panel debates the questions that divided the nation this week, and takes your calls.",
        "In a remote valley, a small crew attempts something that has never been filmed before.",
    ]

    /// 150–300 characters: the title, then sentences until there are 150, cut back to a word under 300.
    static func description(channel: Int, k: Int, title: String) -> String {
        var text = title.hasSuffix("?") ? title : "\(title)."
        var n = abs(channel &* 31 &+ k)
        while text.count < 150 {
            text += " " + sentences[n % sentences.count]
            n += 5
        }
        if text.count > 300 {
            let cut = text.prefix(299)
            text = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
        }
        return text
    }

    static func programme(channel: Int, k: Int, start: Double, end: Double) -> GuideProgramme {
        let title = titles[abs(channel &* 7 &+ k) % titles.count]
        let episode = k % 3 == 0 ? "S\(1 + channel % 9) E\(1 + abs(k) % 22)" : nil
        return GuideProgramme(title: title, description: description(channel: channel, k: k, title: title),
                              startTime: start, endTime: end, isNew: k % 5 == 0 ? true : nil,
                              subtitle: episode != nil && k % 2 == 0 ? "Part \(1 + abs(k) % 4)" : nil, episode: episode)
    }

    // MARK: What the fixture server answers

    private struct Page: Encodable {
        let total: Int
        let channels: [GuideChannel]
        let nextCursor: String?
    }

    /// `library/guide`: the channels from `cursor` (an offset), `limit` at a time, with the programmes of start ..< end.
    static func pageJSON(query: [String: String], total: Int) -> Data {
        let from = query["start"].flatMap(Double.init) ?? window().timeIntervalSince1970 * 1000
        let to = query["end"].flatMap(Double.init) ?? from + GuideNavigation.loadedDuration * 1000
        let limit = query["limit"].flatMap(Int.init) ?? pageSize
        let first = min(max(0, query["cursor"].flatMap(Int.init) ?? 0), total)
        let last = min(total, first + limit)
        let page = Page(total: total, channels: (first..<last).map { channel($0, from: from, to: to) },
                        nextCursor: last < total ? String(last) : nil)
        return (try? JSONEncoder().encode(page)) ?? Data("{}".utf8)
    }

    /// A channel's logo: its name on a coloured plate, a 400 × 225 PNG (the size of a typical provider logo).
    static func logoPNG(_ index: Int) -> Data {
        let size = CGSize(width: 400, height: 225)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            let plate = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 36)
            UIColor(hue: CGFloat(index % 36) / 36, saturation: 0.7, brightness: 0.7, alpha: 1).setFill()
            UIBezierPath(roundedRect: plate, cornerRadius: size.height * 0.1).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: UIColor(hue: 0, saturation: 0, brightness: 1, alpha: 1), .paragraphStyle: style]
            let text = name(index).uppercased() as NSString
            let bounds = text.boundingRect(with: CGSize(width: plate.width - 24, height: plate.height),
                                           options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            text.draw(with: CGRect(x: plate.minX + 12, y: plate.midY - bounds.height / 2, width: plate.width - 24,
                                   height: bounds.height), options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
        }
    }

    /// A session whose requests to the fixture address are answered by `ProductionGuideServer`.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProductionGuideServer.self] + (configuration.protocolClasses ?? [])
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

/// #360 (C2, C3): figures about guide loading measured in the app on the production fixture (DEBUG, launch variable
/// PIGTV_UI_TEST_GUIDE_FIGURES=1, read by GuidePerfUITests through the probe's JSON): what a second guide costs while a
/// refresh holds the old one on screen (C2's swap), in MB of heap in use.
nonisolated enum ProductionGuideFigures {
    static var requested: Bool { ProcessInfo.processInfo.environment["PIGTV_UI_TEST_GUIDE_FIGURES"] == "1" }

    static func measure(channels count: Int = defaultCount) -> [String: Double] {
        let window = ProductionGuideFixture.window()
        guard let json = try? JSONEncoder().encode(ProductionGuideFixture.channels(count: count, window: window)),
              let first = try? JSONDecoder().decode([GuideChannel].self, from: json) else { return [:] }
        let before = footprint()
        let second = (try? JSONDecoder().decode([GuideChannel].self, from: json)) ?? []
        let after = footprint()
        var figures: [String: Double] = [
            "secondGuideMB": (Double(after) - Double(before)) / 1_048_576,
            "guideJSONMB": Double(json.count) / 1_048_576,
            "guideChannels": Double(second.count),
            "guideProgrammes": Double(second.reduce(0) { $0 + $1.programmes.count }),
        ]
        figures["firstGuideChannels"] = Double(first.count)
        return figures
    }

    static let defaultCount = ProductionGuideFixture.defaultChannels

    /// Heap bytes in use in every malloc zone (no mach globals: the app builds in Swift 6 mode).
    static func footprint() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.size_in_use)
    }
}

/// #362: the fixture's server, inside the app's URL loading (DEBUG only). `library/guide` and its version, the
/// channels' logos and an empty favourites list; anything else is a 404 at once, so nothing reaches the network.
nonisolated final class ProductionGuideServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var channelCount = ProductionGuideFixture.defaultChannels
    nonisolated(unsafe) static var pageDelay: TimeInterval = 0
    /// A LAN round trip for each logo.
    nonisolated(unsafe) static var logoDelay: TimeInterval = 0.02
    private let lock = NSLock()
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == ProductionGuideFixture.host && request.url?.port == ProductionGuideFixture.port
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Status, body and content type for a request (pure but for the logo drawing; unit-tested).
    static func answer(for url: URL) -> (status: Int, body: Data, type: String) {
        let path = url.path
        if path == "/api/library/guide/version" { return (200, Data(#"{"version":"fixture-production-1"}"#.utf8), "application/json") }
        if path == "/api/library/guide" {
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value }
            return (200, ProductionGuideFixture.pageJSON(query: query, total: channelCount), "application/json")
        }
        if path == "/api/library/favourites" { return (200, Data("[]".utf8), "application/json") }
        if path.hasPrefix(ProductionGuideFixture.logoPrefix),
           let index = Int(path.dropFirst(ProductionGuideFixture.logoPrefix.count)), index >= 0 {
            return (200, ProductionGuideFixture.logoPNG(index), "image/png")
        }
        return (404, Data(#"{"error":"not in the fixture"}"#.utf8), "application/json")
    }

    override func startLoading() {
        guard let url = request.url else { return }
        // The first page at once (its own encoding is the wait); each later page (a cursor) after `pageDelay`.
        let delay = url.path == "/api/library/guide" ? (url.query?.contains("cursor=") == true ? Self.pageDelay : 0)
            : url.path.hasPrefix(ProductionGuideFixture.logoPrefix) ? Self.logoDelay : 0
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [self] in
            let answer = Self.answer(for: url)
            lock.withLock {
                guard !cancelled else { return }
                let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": answer.type, "Content-Length": String(answer.body.count)])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: answer.body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { lock.withLock { cancelled = true } }
}
#endif
