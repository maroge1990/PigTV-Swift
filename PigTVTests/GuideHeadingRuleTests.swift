import UIKit
import XCTest
@testable import PigTV

/// maroge1990/PigTV#372: the rule that makes a divider channel a section heading (GuideHeading), where rows sit when some
/// are headings (GuideGridRowGeometry), and the grid's store. The grid itself and the consumers: GuideHeadingTests.
final class GuideHeadingRuleTests: XCTestCase {
    private static let hour = 3_600_000.0
    private static let start = 1_800_000_000_000.0

    private func programmes(_ titles: [String]) -> [GuideProgramme] {
        titles.enumerated().map { index, title in
            GuideProgramme(title: title, description: nil, startTime: Self.start + Double(index) * 2 * Self.hour,
                           endTime: Self.start + Double(index + 1) * 2 * Self.hour)
        }
    }

    private func channel(_ id: String, _ name: String, _ titles: [String]) -> GuideChannel {
        GuideChannel(rawID: id, sourceId: 1, name: name, logo: nil, category: nil, programmes: programmes(titles))
    }

    private func divider(_ id: String, _ name: String = "### SPORTS ###") -> GuideChannel {
        channel(id, name, Array(repeating: "⬇️⬇️⬇️⬇️⬇️⬇️", count: 4))
    }

    private func ordinary(_ id: String) -> GuideChannel {
        channel(id, "Channel \(id)", ["News at Six", "Film: The Long Road", "Late Show", "Weather"])
    }

    // MARK: The rule

    func testADecoratedNameWithSymbolProgrammesIsAHeading() {
        let symbols = ["⬇️⬇️⬇️⬇️", "→ → →", "!!!", "•", "", "━━━━", "🏆🏆", "* * *"]
        let cases: [(String, String)] = [
            ("### SPORTS ###", "SPORTS"), ("━━ Movies ━━", "Movies"), ("  *** Kids & Family ***  ", "Kids & Family"),
            ("===NEWS===", "NEWS"), ("••• Music •••", "Music"), ("⚽️ FOOTBALL ⚽️", "FOOTBALL"), ("★ UK ★", "UK"),
            ("|| Sports 24/7 ||", "Sports 24/7"),
            // Letters in any script.
            ("••• スポーツ •••", "スポーツ"), ("## Спорт ##", "Спорт"), ("── رياضة ──", "رياضة"), ("== 体育 ==", "体育"),
        ]
        for (name, label) in cases {
            XCTAssertEqual(GuideHeading.label(name: name, titles: symbols), label, name)
            XCTAssertEqual(GuideHeading.label(of: channel("x", name, symbols)), label, name)
        }
    }

    func testNearMissesAreOrdinaryChannels() {
        let symbols = ["⬇️⬇️⬇️", "⬇️⬇️⬇️"]
        // A decorated name with real programme titles (any letter or digit in any one title).
        XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: ["⬇️⬇️", "Live Match"]))
        XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: ["⬇️ 2 ⬇️"]), "a digit")
        XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: ["⬇️ ニュース ⬇️"]), "a non-Latin title")
        XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: ["★ ٣ ★"]), "an Arabic-Indic digit")
        // A decorated name with no programmes: it keeps its "No programme information" row.
        XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: [String]()))
        XCTAssertNil(GuideHeading.label(of: channel("x", "### SPORTS ###", [])))
        // Symbol programmes under a name that is not wrapped in decoration.
        for name in ["Sky Sports 1", "### SPORTS", "SPORTS ###", "|UK| Sports", "Sports (HD)", "1 ### SPORTS ###",
                     "### SPORTS ### 2", "Sport"] {
            XCTAssertNil(GuideHeading.label(name: name, titles: symbols), name)
        }
        // Decoration around no letter at all.
        for name in ["### 2026 ###", "######", "★", "  ", "", "## 1 ##"] {
            XCTAssertNil(GuideHeading.label(name: name, titles: symbols), name)
        }
    }

    func testPlayableLeavesOutHeadingsOnly() {
        let rows = [divider("h1"), ordinary("a"), channel("e", "### EMPTY ###", []), divider("h2"), ordinary("b")]
        XCTAssertEqual(GuideHeading.playable(rows).map(\.id), ["1:a", "1:e", "1:b"])
    }

    // MARK: Row geometry

    func testWithoutHeadingsTheGeometryIsThePlainOne() {
        let m = GuideGridMetrics()
        let g = GuideGridRowGeometry(headings: [], metrics: m)
        for row in 0..<2_000 {
            XCTAssertEqual(g.minY(row), GuideGridMath.rowMinY(row, metrics: m))
            XCTAssertEqual(g.height(row), m.rowHeight)
        }
        XCTAssertEqual(g.contentHeight(count: 1_250), GuideGridMath.rowMinY(1_250, metrics: m))
        for (minY, maxY) in [(0.0, 900.0), (-50, 30), (79.5, 80), (12_345, 13_400), (99_000, 120_000), (500, 400)] {
            XCTAssertEqual(g.rows(in: CGFloat(minY), CGFloat(maxY), count: 1_250),
                           GuideGridMath.rows(in: CGFloat(minY), CGFloat(maxY), count: 1_250, metrics: m), "\(minY)…\(maxY)")
        }
        for y in [0.0, 1, 79, 80, 81, 4_000.5] {
            XCTAssertEqual(g.firstRow(atOrBelow: CGFloat(y), count: 1_250), Int((CGFloat(y) / m.rowHeight).rounded(.up)))
        }
        XCTAssertEqual(g.nearestChannel(to: 7, count: 10), 7)
    }

    func testHeadingsAreHalfARow() {
        let g = GuideGridRowGeometry(headings: [0, 5, 6, 10], metrics: GuideGridMetrics())
        XCTAssertEqual([0, 1, 5, 6, 7, 10, 11].map(g.minY), [0, 40, 360, 400, 440, 680, 720])
        XCTAssertEqual([0, 1, 5, 6, 7].map(g.height), [40, 80, 40, 40, 80])
        XCTAssertEqual(g.contentHeight(count: 12), 800)
        XCTAssertEqual(g.rows(in: 0, 39.5, count: 12), 0..<1)
        XCTAssertEqual(g.rows(in: 360, 440, count: 12), 5..<8)
        XCTAssertEqual(g.rows(in: 700, 5_000, count: 12), 10..<12)
        XCTAssertEqual(g.rows(in: 800, 900, count: 12), 0..<0, "below the content")
        XCTAssertEqual(g.row(at: 395, count: 12), 5)
        XCTAssertEqual(g.row(at: 400, count: 12), 6)
        XCTAssertEqual(g.firstRow(atOrBelow: 41, count: 12), 2)
        XCTAssertEqual(g.firstRow(atOrBelow: 40, count: 12), 1)
        XCTAssertTrue(g.isHeading(6))
        XCTAssertFalse(g.isHeading(7))
        // The nearest channel: down first, else up; nil when only headings.
        XCTAssertEqual(g.nearestChannel(to: 0, count: 12), 1)
        XCTAssertEqual(g.nearestChannel(to: 5, count: 12), 7)
        XCTAssertEqual(g.nearestChannel(to: 10, count: 11), 9, "a heading on the last row: the row above")
        XCTAssertNil(GuideGridRowGeometry(headings: [0, 1]).nearestChannel(to: 0, count: 2))
    }

    // MARK: The store

    @MainActor
    func testAHeadingRowIsOneUnfocusableBandInTheStore() {
        let store = GuideGridStore()
        store.setRows([divider("h", "━━ Movies ━━"), ordinary("a"), channel("e", "### EMPTY ###", [])])
        XCTAssertEqual(store.geometry.headings, [0])
        XCTAssertEqual(store.headingLabel(0), "Movies")
        XCTAssertEqual(store.itemCount(in: 0), 1, "the band alone")
        XCTAssertNil(store.programme(at: IndexPath(item: 1, section: 0)))
        XCTAssertNil(store.indexPath(section: 0, start: nil), "nothing in a heading is a focus target")
        XCTAssertFalse(store.isHeading(2), "no programmes: an ordinary row")
        XCTAssertTrue(store.isPlaceholder(IndexPath(item: 1, section: 2)))
        XCTAssertEqual(store.itemCount(in: 1), 5)
    }
}
