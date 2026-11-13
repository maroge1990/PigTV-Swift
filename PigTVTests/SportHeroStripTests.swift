import XCTest
import SwiftUI
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

    // #278 ("seen on the way"): on the iPhone the strip's LIVE pill was a red bar with no word in it, because a long title
    // and line took the room and left the pill's text none. The pill must keep its word at a narrow width.
    @MainActor
    func testTheLivePillKeepsItsWordWhenTheTitleIsLong() throws {
        let hero = SportBannerHero(kicker: "LIVE · PREMIER LEAGUE", live: true, title: "Manchester United v Tottenham Hotspur",
                                   line: "2–1 · Second half · 67 minutes")
        let strip = SportHeroStrip(hero: hero, items: [item("Arsenal", "Sat 11:30 pm"), item("Sixers", "Tue 7:15 pm")], selected: nil)
        let view = SportHeroStripView(strip: strip).frame(width: 390).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color.pigDanger).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let red = [r, g, b]
        func isDanger(_ x: Int, _ y: Int) -> Bool {
            let o = (y * width + x) * 4
            let d = abs(Int(data[o]) - Int(red[0] * 255)) + abs(Int(data[o + 1]) - Int(red[1] * 255)) + abs(Int(data[o + 2]) - Int(red[2] * 255))
            return d < 30
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width where isDanger(x, y) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        XCTAssertGreaterThan(maxX, minX, "the pill is drawn")
        // The pill's middle: its word's strokes are not pill-coloured; a bar with no word is all pill-coloured.
        let x0 = minX + (maxX - minX) / 4, x1 = maxX - (maxX - minX) / 4, y0 = minY + (maxY - minY) / 4, y1 = maxY - (maxY - minY) / 4
        var strokes = 0
        for y in y0...y1 { for x in x0...x1 where !isDanger(x, y) { strokes += 1 } }
        XCTAssertGreaterThan(strokes, 20, "the pill says LIVE (pill \(maxX - minX + 1) px wide)")
    }
}
