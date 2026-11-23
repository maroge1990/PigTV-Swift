import UIKit
import XCTest
@testable import PigTV

/// maroge1990/PigTV#372: divider channels (a decorated name, programmes titled with symbols) are drawn as slim section
/// headings in the TV Guide (Mark's option A), never take focus or play, and are left out of every channel list built from
/// the Guide's rows: the grid's layout and focus rules on the real controller, a reload that turns a row into a heading,
/// and the consumers. Only APIs the app had before #372 (so the file runs against the old code and fails there); the rule,
/// the row geometry and the store are in GuideHeadingRuleTests.
@MainActor
final class GuideHeadingTests: XCTestCase {
    private static let hour = 3_600_000.0
    private static let start = (Date().timeIntervalSince1970 * 1000 / (2 * hour)).rounded(.down) * 2 * hour - 2 * hour

    private func programmes(_ titles: [String]) -> [GuideProgramme] {
        titles.enumerated().map { index, title in
            GuideProgramme(title: title, description: nil, startTime: Self.start + Double(index) * 2 * Self.hour,
                           endTime: Self.start + Double(index + 1) * 2 * Self.hour)
        }
    }

    private func channel(_ id: String, _ name: String, _ titles: [String], number: Int? = nil) -> GuideChannel {
        GuideChannel(rawID: id, sourceId: 1, name: name, logo: nil, category: nil, programmes: programmes(titles), number: number)
    }

    private func divider(_ id: String, _ name: String = "### SPORTS ###") -> GuideChannel {
        channel(id, name, Array(repeating: "⬇️⬇️⬇️⬇️⬇️⬇️", count: 4))
    }

    private func ordinary(_ id: String, _ name: String? = nil, number: Int? = nil) -> GuideChannel {
        channel(id, name ?? "Channel \(id)", ["News at Six", "Film: The Long Road", "Late Show", "Weather"], number: number)
    }

    // MARK: The grid

    private func hostGrid(_ rows: [GuideChannel]) -> (GuideGridViewController, UIWindow) {
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 1, loadedAt: nil))
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// First row a heading, a heading beside the row with no programmes, two in a row, one last.
    private var headed: [GuideChannel] {
        [divider("h0", "━━ SPORTS ━━"), ordinary("a"), channel("e", "Empty", []), divider("h1", "*** NEWS ***"), ordinary("b"),
         divider("h2", "=== KIDS ==="), divider("h3", "••• JUNIOR •••"), ordinary("c"), divider("h4", "▼▼ RADIO ▼▼")]
    }

    func testHeadingsAreSlimBandsAcrossTheGridThatNeverTakeFocus() throws {
        let (controller, window) = hostGrid(headed)
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(controller.collectionView)
        let width = collection.bounds.width
        let delegate = try XCTUnwrap(collection.delegate)
        XCTAssertEqual(collection.contentSize.height, 4 * 80 + 5 * 40)
        let expectedY: [CGFloat] = [0, 40, 120, 200, 240, 320, 360, 400, 480]
        for (section, y) in expectedY.enumerated() {
            let item0 = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: section)))
            let heading = [0, 3, 5, 6, 8].contains(section)
            XCTAssertEqual(item0.frame.minY, y + 4, "row \(section)'s top")
            XCTAssertEqual(item0.frame.height, heading ? 32 : 72, "row \(section)'s height")
            XCTAssertEqual(collection.numberOfItems(inSection: section) == 1, heading, "row \(section): a heading is its band alone")
            if heading {
                XCTAssertEqual(item0.frame.minX, collection.contentOffset.x + 4, "the band starts at the channel column")
                XCTAssertEqual(item0.frame.width, width - 8, "and crosses the whole grid")
                // Through the delegate as UIKit asks it (a method the delegate lacks answers UIKit's default, yes).
                let band = IndexPath(item: 0, section: section)
                XCTAssertFalse(delegate.collectionView?(collection, canFocusItemAt: band) ?? true, "row \(section) takes focus")
                XCTAssertFalse(delegate.collectionView?(collection, shouldSelectItemAt: band) ?? true, "row \(section) is selected")
                XCTAssertFalse(delegate.collectionView?(collection, shouldHighlightItemAt: band) ?? true, "row \(section) is pressed")
            } else {
                XCTAssertTrue(delegate.collectionView?(collection, canFocusItemAt: IndexPath(item: 0, section: section)) ?? true)
            }
        }
        // The band is drawn: a heading cell with its label, on screen.
        collection.layoutIfNeeded()
        let band = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 3)))
        XCTAssertEqual(String(describing: type(of: band)), "GuideGridHeadingCell")
        XCTAssertEqual(band.accessibilityLabel, "NEWS", "the label without its decoration")
        // The placeholder beside it stays a full row.
        let placeholder = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 2)))
        XCTAssertEqual(placeholder.frame.height, 72)
    }

    func testAGuideWithoutHeadingsLaysOutExactlyAsBefore() throws {
        let rows = GuideFixtures.channels()
        let (controller, window) = hostGrid(rows)
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(controller.collectionView)
        let layout = try XCTUnwrap(collection.collectionViewLayout as? GuideGridLayout)
        let m = layout.metrics
        XCTAssertEqual(collection.contentSize.height, GuideGridMath.rowMinY(rows.count, metrics: m))
        let all = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(origin: .zero, size: collection.contentSize)))
        var checked = 0
        for attributes in all where attributes.representedElementCategory == .cell {
            let path = attributes.indexPath
            let expected: CGRect
            if path.item == 0 {
                expected = GuideGridMath.tileFrame(row: path.section, offsetX: collection.contentOffset.x, metrics: m)
            } else if let programme = GuideGridStore.items(of: rows[path.section]).dropFirst(path.item - 1).first,
                      !GuideGridStore.items(of: rows[path.section]).isEmpty {
                let full = GuideGridMath.programmeFrame(start: programme.start, end: programme.end, row: path.section,
                                                        origin: layout.origin, metrics: m)
                expected = try XCTUnwrap(GuideGridMath.clipped(full, offsetX: collection.contentOffset.x, metrics: m)).frame
            } else {
                let full = GuideGridMath.placeholderFrame(row: path.section, duration: layout.loadedDuration, metrics: m)
                expected = try XCTUnwrap(GuideGridMath.clipped(full, offsetX: collection.contentOffset.x, metrics: m)).frame
            }
            XCTAssertEqual(attributes.frame, expected, "\(path)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, rows.count * 2)
    }

    /// The small first page gives way to the whole guide (or a channel's programmes arrive) and a row above the screen
    /// becomes a heading: the rows on screen stay where they are.
    func testARowTurningIntoAHeadingLeavesTheScreenStill() throws {
        var rows = (0..<40).map { ordinary("c\($0)") }
        rows[2] = channel("d", "### SPORTS ###", []) // no programmes yet: an ordinary row
        let (controller, window) = hostGrid(rows)
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(controller.collectionView)
        collection.contentOffset.y = 800 // row 10 at the top
        collection.layoutIfNeeded()
        rows[2] = divider("d", "### SPORTS ###")
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 2, loadedAt: nil))
        collection.layoutIfNeeded()
        let band = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 2)))
        XCTAssertEqual(band.frame.height, 32, "row 2 is a heading now")
        let tile = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 10)))
        XCTAssertEqual(tile.frame.minY - collection.contentOffset.y, 4, "row 10 is still at the top of the screen")
    }

    // MARK: The consumers

    private func browse(_ rows: [GuideChannel]) throws -> BrowseModel {
        let model = BrowseModel(client: APIClient(address: try ServerAddress("http://tv.local:3000"), token: "t"))
        model.guide = rows
        return model
    }

    func testThePlayersChannelsSkipHeadings() throws {
        let model = try browse([divider("h0"), ordinary("a", "A", number: 1), divider("h1", "━━ NEWS ━━"), ordinary("b", "B", number: 2)])
        let app = AppModel()
        app.configureClientForTesting(model.client, browse: model)
        XCTAssertEqual(app.playerChannels.map(\.name), ["A", "B"], "the player's list without a zap list")
        app.beginPlayback(model.asChannel(model.guide[1]))
        app.zapList = []
        app.zap(1)
        XCTAssertEqual(app.playback?.channel.name, "B", "channel up passes over the heading")
        app.zap(1)
        XCTAssertEqual(app.playback?.channel.name, "A", "and wraps past the heading on the first row")
    }

    func testGoToNumberNeverPlaysAHeading() throws {
        var heading = divider("h0")
        heading.number = 7
        let model = try browse([heading, ordinary("a", "A", number: 8)])
        let app = AppModel()
        app.configureClientForTesting(model.client, browse: model)
        XCTAssertNil(app.channel(number: 7))
        XCTAssertEqual(app.channel(number: 8)?.name, "A")
    }

    func testSearchAndTheTopShelfSkipHeadings() throws {
        let rows = [divider("h0", "### SPORTS ###"), ordinary("a", "Sports One"), ordinary("b", "Film Four")]
        let results = GuideSearch.run("sports", in: rows, now: Date())
        XCTAssertEqual(results.channels.map(\.id), ["1:a"])
        let symbols = GuideSearch.run("⬇️⬇️", in: rows, now: Date())
        XCTAssertTrue(symbols.programmes.isEmpty, "a heading's symbols are not programmes to find")
        let snapshot = try XCTUnwrap(try browse(rows).topShelfSnapshot(now: Date()))
        XCTAssertEqual(snapshot.channels.map(\.name), ["Sports One", "Film Four"])
    }
}
