import XCTest
@testable import PigTV

// #264 (Mark, 9 Nov 2026, option B): the Sport front page's banner shrinks to a strip pinned under the header once the
// page scrolls past it. The strip says the hero's game and up to three other follows, the hero's own follow left out;
// it shows only once the banner has scrolled under it. Before Apple 190 there was no strip (the banner scrolled away).
final class SportHeroStripTests: XCTestCase {
    private let hero = SportBannerHero(kicker: "LIVE · NFL · YOUR TEAM", live: true, title: "Packers v Bears", line: "7–3 · Quarter 2 · 5:00")
    private func item(_ title: String, _ trailing: String) -> SportBannerItem {
        SportBannerItem(id: title, title: title, trailing: trailing, live: false)
    }

    func testTheStripSaysTheHeroAndTheOtherFollows() {
        let items = [item("Oscar Piastri", "Race · Sat 2:27 pm"), item("Green Bay Packers", "LIVE · v Bears"),
                     item("Arsenal", "Sat 11:30 pm"), item("Sixers", "Tue 7:15 pm"), item("Ferrari", "Sun 3:00 am")]
        let strip = SportHeroStrip(hero: hero, items: items, selected: 1)
        XCTAssertTrue(strip.live)
        XCTAssertEqual(strip.title, "Packers v Bears")
        XCTAssertEqual(strip.line, "7–3 · Quarter 2 · 5:00")
        XCTAssertEqual(strip.others, "Oscar Piastri Race · Sat 2:27 pm  ·  Arsenal Sat 11:30 pm  ·  Sixers Tue 7:15 pm",
                       "three others, the hero's own follow left out")
    }

    func testOneFollowLeavesNoOthers() {
        XCTAssertNil(SportHeroStrip(hero: hero, items: [item("Green Bay Packers", "LIVE")], selected: 0).others)
        XCTAssertNil(SportHeroStrip(hero: hero, items: [], selected: nil).others)
    }

    func testItShowsOnlyOnceTheBannerHasScrolledUnderIt() {
        XCTAssertFalse(SportHeroStrip.shows(scrolled: 0, bannerHeight: 320, stripHeight: 72))
        XCTAssertFalse(SportHeroStrip.shows(scrolled: 248, bannerHeight: 320, stripHeight: 72))
        XCTAssertTrue(SportHeroStrip.shows(scrolled: 249, bannerHeight: 320, stripHeight: 72))
        XCTAssertFalse(SportHeroStrip.shows(scrolled: 500, bannerHeight: 0, stripHeight: 72), "no banner, no strip")
    }
}
