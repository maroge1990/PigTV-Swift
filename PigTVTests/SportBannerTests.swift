import XCTest
@testable import PigTV

// D-43 (1 Nov): the banner's list shows four items (three on the television since Apple 199, #279) and scrolls in place, with a "5 more · …" line; one item runs the
// banner full width. Before Apple 97 there is no banner: none of these types exist.
final class SportBannerTests: XCTestCase {
    private let names = ["Liverpool", "Oscar Piastri", "Green Bay Packers", "Australia", "Alex de Minaur",
                         "Min Woo Lee", "Arsenal", "Tom Nolan", "Collingwood", "Chelsea"]

    func testFourItemsShowThenTheMoreLine() {
        let window = SportBannerWindow(count: names.count, visible: 4)
        XCTAssertEqual(window.range, 0..<4)
        XCTAssertEqual(window.below, 6)
        XCTAssertEqual(window.moreLine(names: names), "6 more · Alex de Minaur, Min Woo Lee, Arsenal …")
    }

    func testMovingDownScrollsTheWindowOneRowAtATime() {
        var window = SportBannerWindow(count: names.count, visible: 4)
        for index in 0..<4 { window = window.focusing(index) }
        XCTAssertEqual(window.start, 0, "within the window nothing moves")
        window = window.focusing(4)
        XCTAssertEqual(window.range, 1..<5, "the fifth row scrolls in, the first out")
        XCTAssertEqual(window.moreLine(names: names), "5 more · Min Woo Lee, Arsenal, Tom Nolan …")
        window = window.focusing(9)
        XCTAssertEqual(window.range, 6..<10)
        XCTAssertNil(window.moreLine(names: names), "nothing below")
        window = window.focusing(8)
        XCTAssertEqual(window.start, 6, "moving up inside the window keeps it")
        window = window.focusing(2)
        XCTAssertEqual(window.range, 2..<6, "above the window: it scrolls up to show it at the top")
        XCTAssertEqual(window.moreLine(names: names), "4 more · Arsenal, Tom Nolan, Collingwood …")
    }

    func testAShortListHasNoMoreLineAndNeverScrolls() {
        let window = SportBannerWindow(count: 3, visible: 4).focusing(2)
        XCTAssertEqual(window.range, 0..<3)
        XCTAssertNil(window.moreLine(names: Array(names.prefix(3))))
        XCTAssertEqual(SportBannerWindow(count: 6, visible: 4).focusing(5).moreLine(names: Array(names.prefix(6))), nil)
        XCTAssertEqual(SportBannerWindow(count: 6, visible: 4).moreLine(names: Array(names.prefix(6))), "2 more · Alex de Minaur, Min Woo Lee",
                       "three or fewer named without the ellipsis")
        XCTAssertEqual(SportBannerWindow(count: 6, start: 9, visible: 4).start, 2, "a start past the end is clamped")
    }

    /// #279 (Apple 199): the television shows three 56 pt rows of 23 pt text in the 250 pt banner, the rest behind the
    /// "more" line; touch keeps four.
    func testTheTelevisionShowsThreeRows() {
        #if os(tvOS)
        XCTAssertEqual(SportBannerWindow.visible, 3)
        #else
        XCTAssertEqual(SportBannerWindow.visible, 4)
        #endif
        var window = SportBannerWindow(count: names.count, visible: 3)
        XCTAssertEqual(window.range, 0..<3)
        XCTAssertEqual(window.moreLine(names: names), "7 more · Australia, Alex de Minaur, Min Woo Lee …")
        window = window.focusing(3)
        XCTAssertEqual(window.range, 1..<4, "the fourth row scrolls in, the first out")
        XCTAssertEqual(SportBannerWindow(count: 4, visible: 3).moreLine(names: Array(names.prefix(4))), "1 more · Australia")
    }

    func testOneItemRunsTheBannerFullWidth() {
        XCTAssertTrue(SportBannerLayout.fullWidth(itemCount: 0), "no follows: no list")
        XCTAssertTrue(SportBannerLayout.fullWidth(itemCount: 1), "one league: no list and no line")
        XCTAssertFalse(SportBannerLayout.fullWidth(itemCount: 2))
    }

    func testTheBackdropIsTheDarkMapInDarkMode() {
        XCTAssertEqual(SportBannerBackdrop.map(light: "/api/logo/m?size=3840", dark: "/api/logo/md?size=3840").path(dark: true),
                       "/api/logo/md?size=3840")
        XCTAssertEqual(SportBannerBackdrop.map(light: "/api/logo/m?size=3840", dark: nil).path(dark: true),
                       "/api/logo/m?size=3840", "no dark map: the light one")
        XCTAssertEqual(SportBannerBackdrop.badge("/api/logo/espn-gb").path(dark: true), "/api/logo/espn-gb")
    }

    func testTheCircuitInfoDecodesTheDarkMap() throws {
        let info = try JSONDecoder().decode(F1CircuitInfo.self, from: Data(#"{"map":"/api/logo/m?size=3840","mapDark":"/api/logo/md?size=3840"}"#.utf8))
        XCTAssertEqual(info.mapDark, "/api/logo/md?size=3840")
        XCTAssertNil(try JSONDecoder().decode(F1CircuitInfo.self, from: Data(#"{"map":"/api/logo/m","mapDark":""}"#.utf8)).mapDark)
    }
}
