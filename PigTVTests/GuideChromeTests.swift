import XCTest
@testable import PigTV

// D-44 (Apple 106): the TV Guide's chips and focus strip.
final class GuideChromeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 08:00 UTC
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func programme(_ title: String, _ start: TimeInterval, _ end: TimeInterval, description: String? = nil) -> GuideProgramme {
        GuideProgramme(title: title, description: description, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    private let sports = Category(rawID: "sports", sourceId: 1, name: "Sports", channelCount: 2, sport: true)
    private let news = Category(rawID: "news", sourceId: 1, name: "News", channelCount: 1)

    func testChipsAreAllFavouritesSportThenTheCategories() {
        XCTAssertEqual(GuideChips.make(categories: [sports, news]).map(\.title), ["All", "Favourites", "Sport", "News"],
                       "a lone sport category is the Sport chip, not listed twice")
        let espn = Category(rawID: "espn", sourceId: 1, name: "ESPN", channelCount: 1, sport: true)
        XCTAssertEqual(GuideChips.make(categories: [sports, news, espn]).map(\.title),
                       ["All", "Favourites", "Sport", "Sports", "News", "ESPN"])
        XCTAssertEqual(GuideChips.make(categories: [news]).map(\.title), ["All", "Favourites", "News"],
                       "no Sport chip without a sport category")
    }

    func testTheSportChipShowsEverySportCategory() {
        let espn = Category(rawID: "espn", sourceId: 1, name: "ESPN", channelCount: 1, sport: true)
        let guide = [GuideChannel(rawID: "a", sourceId: 1, name: "Fox", logo: nil, category: "sports", programmes: []),
                     GuideChannel(rawID: "b", sourceId: 1, name: "ABC", logo: nil, category: "news", programmes: []),
                     GuideChannel(rawID: "c", sourceId: 1, name: "ESPN 2", logo: nil, category: "ESPN", programmes: [])]
        let categories = GuideChips.categories(for: GuideChips.sport, in: [sports, news, espn])
        XCTAssertEqual(GuideRowFilter.rows(from: guide, categories: categories, search: "", onlyFavourites: false,
                                           favouriteKeys: []).map(\.rawID), ["a", "c"])
        XCTAssertNil(GuideChips.categories(for: "all", in: [sports, news]))
        XCTAssertTrue(GuideChips.isSelected(GuideChip(id: GuideChips.sport, title: "Sport"), filter: sports.id, in: [sports, news]),
                      "a stored filter on the lone sport category selects the Sport chip")
    }

    func testTheStripReadsTheFocusedProgramme() {
        let live = programme("Australia v India · 1st Test, Day 1", -600, 3000, description: "Live from Perth Stadium.")
        let text = GuideStripText.make(channel: "Fox Cricket", number: 501, programme: live, scheduled: true,
                                       recordingNow: true, now: now, hint: "hint", calendar: utc)
        XCTAssertEqual(text.title, "Australia v India · 1st Test, Day 1")
        XCTAssertEqual(text.times, live.timeRange)
        XCTAssertEqual(text.detail, "Fox Cricket 501 · Recording · Live from Perth Stadium.")
        XCTAssertTrue(text.recording, "the red dot goes with the word")
        let later = programme("Four Corners", 3600, 7200)
        let plain = GuideStripText.make(channel: "ABC TV", number: nil, programme: later, scheduled: false,
                                        recordingNow: false, now: now, hint: "hint", calendar: utc)
        XCTAssertEqual(plain.detail, "ABC TV")
        XCTAssertFalse(plain.recording)
        let tomorrow = programme("Rage", 20 * 3600, 21 * 3600)
        XCTAssertTrue(GuideStripText.make(channel: "ABC TV", number: nil, programme: tomorrow, scheduled: true,
                                          recordingNow: false, now: now, hint: "", calendar: utc).times?.hasPrefix("Tomorrow ") == true)
        XCTAssertEqual(GuideStripText.make(channel: nil, number: nil, programme: nil, scheduled: false, recordingNow: false,
                                           now: now, hint: "Select a programme").detail, "Select a programme")
        let tile = GuideStripText.make(channel: "ABC TV", number: 2, programme: nil, current: live, scheduled: false,
                                       recordingNow: false, now: now, hint: "")
        XCTAssertEqual(tile.title, "ABC TV")
        XCTAssertEqual(tile.detail, "On now · Australia v India · 1st Test, Day 1")
    }
}
