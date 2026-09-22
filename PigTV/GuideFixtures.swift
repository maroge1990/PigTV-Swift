#if DEBUG
import Foundation

// Synthetic guide data for offline UI iteration (the R14 block-slide work has
// no server in the simulator). Launch with PIGTV_UI_TEST_SCREEN=guide.
enum GuideFixtures {
    static func categories() -> [Category] {
        [Category(rawID: "sports", sourceId: 1, name: "Sports", channelCount: 6),
         Category(rawID: "movies", sourceId: 1, name: "Movies", channelCount: 4),
         Category(rawID: "news", sourceId: 1, name: "News", channelCount: 3),
         Category(rawID: "kids", sourceId: 1, name: "Kids", channelCount: 1)]
    }

    private static let names: [(String, String)] = [
        ("Sky Sports Main Event", "sports"), ("TSN 1", "sports"), ("Fox Footy 504", "sports"),
        ("ESPN", "sports"), ("Sky Sports F1", "sports"), ("beIN Sports 1", "sports"),
        ("HBO", "movies"), ("Sky Cinema Premiere", "movies"), ("Film4", "movies"), ("TCM", "movies"),
        ("BBC News", "news"), ("Sky News", "news"), ("CNN International", "news"),
        ("CBeebies", "kids")]

    static func channels() -> [GuideChannel] {
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
                while t < now + 18 * hour {
                    // Channel 2 carries a long (3h) live sports programme spanning now.
                    let longLive = (index == 2 && t <= now && t + 3 * hour > now)
                    let lengths = [0.5, 1.0, 1.5, 2.0]
                    let length = longLive ? 3.0 : lengths[k % lengths.count]
                    let end = t + length * hour
                    programmes.append(GuideProgramme(title: "\(titles[k % titles.count]) \(index + 1)",
                        description: "Synthetic programme for layout testing on \(name). It runs for \(Int(length * 60)) minutes.",
                        startTime: t, endTime: end))
                    t = end
                    k += 1
                }
            }
            return GuideChannel(rawID: "ch\(index)", sourceId: 1, name: name,
                                logo: nil, category: category, programmes: programmes)
        }
    }

    static func user() -> User {
        (try? JSONDecoder().decode(User.self, from: Data(#"{"id":1,"username":"tester","role":"user"}"#.utf8)))
            ?? (try! JSONDecoder().decode(User.self, from: Data(#"{"id":0,"username":"","role":""}"#.utf8)))
    }
}
#endif
