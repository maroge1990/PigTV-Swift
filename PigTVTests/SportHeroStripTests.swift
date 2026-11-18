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

    // #262: on iOS 17 (no scroll geometry) the scrolled distance comes from a probe at the content's top, measured in the
    // ScrollView's frame: at rest it is at 0, scrolled up it goes negative, pulled down (the bounce) positive.
    func testOnIOS17TheProbeAtTheContentsTopGivesTheScrolledDistance() {
        XCTAssertEqual(PigScrollProbe.scrolled(probeTop: 0), 0, "at rest")
        XCTAssertEqual(PigScrollProbe.scrolled(probeTop: -249), 249, "scrolled up 249 pt")
        XCTAssertLessThan(PigScrollProbe.scrolled(probeTop: 40), 0, "the top bounce is not a scroll")
        XCTAssertTrue(SportHeroStrip.shows(scrolled: PigScrollProbe.scrolled(probeTop: -249), bannerHeight: 320, stripHeight: 72))
        XCTAssertFalse(SportHeroStrip.shows(scrolled: PigScrollProbe.scrolled(probeTop: -248), bannerHeight: 320, stripHeight: 72))
    }

    // #316: the strip takes the width it is given and never more, however long its words. Before, its row's minimum
    // width (the fixed LIVE pill, padding, truncated words) could exceed the offer, and the strip claimed it: on the
    // iPhone the page's column grew by a third of a point and the header above it moved sideways as the strip appeared.
    @MainActor
    func testTheStripNeverClaimsMoreWidthThanItIsGiven() {
        let hero = SportBannerHero(kicker: "LIVE · PREMIER LEAGUE", live: true, title: "Manchester United v Tottenham Hotspur",
                                   line: "2–1 · Second half · 67 minutes")
        let strip = SportHeroStrip(hero: hero, items: [item("Arsenal", "Sat 11:30 pm"), item("Sixers", "Tue 7:15 pm")], selected: nil)
        let host = UIHostingController(rootView: SportHeroStripView(strip: strip))
        for width in [120.0, 370.0, 370.5] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertLessThanOrEqual(size.width, width + 0.001, "offered \(width) pt, it took \(size.width)")
        }
    }

    // #346: the width offered is rounded down to whole pixels (on the iPhone the strip took 370.67 pt of 370.5).
    func testTheStripsWidthIsTheWholePixelsThatFitTheOffer() {
        XCTAssertEqual(StripWidth.width(offered: 370.5, scale: 3), 370 + 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(StripWidth.width(offered: 370.5, scale: 2), 370.5, accuracy: 1e-9)
        XCTAssertEqual(StripWidth.width(offered: 390, scale: 3), 390, accuracy: 1e-9, "a whole-pixel offer is kept")
        XCTAssertEqual(StripWidth.width(offered: 120, scale: 1), 120)
    }

    // #278 ("seen on the way"): on the iPhone the strip's LIVE pill was a red bar with no word in it, because a long title
    // and line took the room and left the pill's text none. The pill must keep its word at a narrow width.
    @MainActor
    func testTheLivePillKeepsItsWordWhenTheTitleIsLong() throws {
        let hero = SportBannerHero(kicker: "LIVE · PREMIER LEAGUE", live: true, title: "Manchester United v Tottenham Hotspur",
                                   line: "2–1 · Second half · 67 minutes")
        let strip = SportHeroStrip(hero: hero, items: [item("Arsenal", "Sat 11:30 pm"), item("Sixers", "Tue 7:15 pm")], selected: nil)
        let view = SportHeroStripView(strip: strip).frame(width: 390).environment(\.colorScheme, .dark)
        let pill = try Self.pixels(view, attach: self)
        let box = try XCTUnwrap(pill.dangerBox(), "the pill is drawn")
        // The pill's middle: its word's strokes are not pill-coloured; a bar with no word is all pill-coloured.
        let x0 = box.minX + (box.maxX - box.minX) / 4, x1 = box.maxX - (box.maxX - box.minX) / 4
        let y0 = box.minY + (box.maxY - box.minY) / 4, y1 = box.maxY - (box.maxY - box.minY) / 4
        var strokes = 0
        for y in y0...y1 { for x in x0...x1 where !pill.isDanger(x, y) { strokes += 1 } }
        XCTAssertGreaterThan(strokes, 20, "the pill says LIVE (pill \(box.maxX - box.minX + 1) px wide)")
        // #313 item 5: the strokes above would also pass for an ellipsis ("L…" or "…"). The word's ink is as wide as the
        // whole word drawn alone, in the same font, on the same red.
        let word = Text(strip.liveWord).font(SportHeroStripMetrics.detail.weight(.heavy)).foregroundStyle(Color.pigOnAccent)
            .lineLimit(1).fixedSize().padding(8).background(Color.pigDanger).environment(\.colorScheme, .dark)
        let reference = try Self.pixels(word, attach: nil)
        let whole = try XCTUnwrap(reference.ink(in: try XCTUnwrap(reference.dangerBox())), "the word alone has ink")
        let drawn = try XCTUnwrap(pill.ink(in: box), "the pill has ink")
        XCTAssertGreaterThanOrEqual(Double(drawn.width), Double(whole.width) * 0.9,
                                    "the pill's word is the whole word (\(drawn.width) px of ink, the word alone \(whole.width) px)")
        XCTAssertGreaterThanOrEqual(Double(drawn.count), Double(whole.count) * 0.8,
                                    "as much ink as the whole word (\(drawn.count) px, the word alone \(whole.count) px)")
    }

    /// A render's pixels, for finding the brand red (`pigDanger`, dark) and the ink on it.
    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int
        let red: [CGFloat]

        func isDanger(_ x: Int, _ y: Int) -> Bool {
            let o = (y * width + x) * 4
            let d = abs(Int(data[o]) - Int(red[0] * 255)) + abs(Int(data[o + 1]) - Int(red[1] * 255)) + abs(Int(data[o + 2]) - Int(red[2] * 255))
            return d < 30
        }

        /// The bounding box of the red pixels.
        func dangerBox() -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height { for x in 0..<width where isDanger(x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            return maxX > minX ? (minX, maxX, minY, maxY) : nil
        }

        /// The ink inside the red: per row, the pixels between that row's first and last red pixel that are not red (so a
        /// capsule's rounded ends never count). Nil when there is none.
        func ink(in box: (minX: Int, maxX: Int, minY: Int, maxY: Int)) -> (width: Int, count: Int)? {
            var minX = Int.max, maxX = -1, count = 0
            for y in box.minY...box.maxY {
                guard let first = (box.minX...box.maxX).first(where: { isDanger($0, y) }),
                      let last = (box.minX...box.maxX).last(where: { isDanger($0, y) }), last > first else { continue }
                for x in first...last where !isDanger(x, y) {
                    count += 1; minX = min(minX, x); maxX = max(maxX, x)
                }
            }
            return maxX >= minX ? (maxX - minX + 1, count) : nil
        }
    }

    @MainActor
    private static func pixels<V: View>(_ view: V, attach test: XCTestCase?) throws -> Pixels {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.uiImage)
        if let test {
            let shot = XCTAttachment(image: rendered); shot.lifetime = .keepAlways; shot.name = "strip"; test.add(shot)
        }
        let image = try XCTUnwrap(rendered.cgImage)
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color.pigDanger).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Pixels(data: data, width: width, height: height, red: [r, g, b])
    }

    /// #339: the page's content rests below the header's fade, with room for a focused card's lift and ring, so the first
    /// row is neither blurred by the fade at rest nor clipped by it when focused.
    func testTheFirstRowRestsClearOfTheTopFadeAndFitsItsFocusLift() {
        let reach = PigFocusLift.card.maxGrowth + PigFocus.ringWidth
        XCTAssertGreaterThanOrEqual(SportPageTopMask.clearance, SportPageTopMask.fade + reach,
                                    "a focused first-row card would reach into the fade")
        XCTAssertGreaterThan(SportPageTopMask.clearance, SportPageTopMask.fade, "the content rests inside the fade")
    }
}
