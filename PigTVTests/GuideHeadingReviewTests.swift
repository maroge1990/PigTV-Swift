import UIKit
import XCTest
@testable import PigTV

/// maroge1990/PigTV#372, Codex review of Apple 404 (five mediums): a placeholder programme title or a bracketed name made a
/// channel a heading; a zap list saved from the small first page, the server's Search, a saved favourite on the Top Shelf
/// and Now / Jump to could still reach a channel the Guide now draws as a heading. Only APIs that 404 had, so each test
/// runs against it and fails there.
@MainActor
final class GuideHeadingReviewTests: XCTestCase {
    private static let hour = 3_600_000.0
    private static let start = (Date().timeIntervalSince1970 * 1000 / (2 * hour)).rounded(.down) * 2 * hour - 2 * hour

    private func channel(_ id: String, _ name: String, _ titles: [String], number: Int? = nil) -> GuideChannel {
        GuideChannel(rawID: id, sourceId: 1, name: name, logo: nil, category: nil, programmes: titles.enumerated().map { index, title in
            GuideProgramme(title: title, description: nil, startTime: Self.start + Double(index) * 2 * Self.hour,
                           endTime: Self.start + Double(index + 1) * 2 * Self.hour)
        }, number: number)
    }

    private func divider(_ id: String, _ name: String = "### SPORTS ###", number: Int? = nil) -> GuideChannel {
        channel(id, name, Array(repeating: "⬇️⬇️⬇️⬇️⬇️⬇️", count: 4), number: number)
    }

    private func ordinary(_ id: String, _ name: String, number: Int? = nil) -> GuideChannel {
        channel(id, name, ["News at Six", "Film: The Long Road", "Late Show", "Weather"], number: number)
    }

    private func browse(_ rows: [GuideChannel], client: APIClient? = nil) throws -> BrowseModel {
        let model = BrowseModel(client: try client ?? APIClient(address: ServerAddress("http://tv.local:3000"), token: "t"))
        model.guide = rows
        return model
    }

    // MARK: 1. The rule

    func testPlaceholderTitlesAndBracketedNamesAreNotHeadings() throws {
        // A placeholder schedule: one short title, a dash, a dot, nothing.
        for titles in [["—"], ["-"], ["."], [""], ["—", "—"], ["••"]] {
            XCTAssertNil(GuideHeading.label(name: "### SPORTS ###", titles: titles), "\(titles)")
        }
        // Brackets that belong to a region or a quality, even under a divider-like schedule.
        for name in ["[UK] BBC One (HD)", "(UK) Sky Sports [FHD]", "[US] ESPN 2 [720p]", "|UK| Sky (Backup)"] {
            XCTAssertNil(GuideHeading.label(name: name, titles: ["—"]), name)
            XCTAssertNil(GuideHeading.label(name: name, titles: ["⬇️⬇️⬇️"]), name)
        }
        // Dividers still are.
        XCTAssertEqual(GuideHeading.label(name: "### SPORTS ###", titles: ["⬇️⬇️⬇️"]), "SPORTS")
        XCTAssertEqual(GuideHeading.label(name: "━━ SPORTS ━━", titles: ["━━━━━━━━"]), "SPORTS")
        XCTAssertEqual(GuideHeading.label(name: "【SPORTS】", titles: ["* * *"]), "SPORTS")
        // The production-sized fixture's dividers (14 symbols a title) still qualify, and only they.
        let window = Date()
        let rows = ProductionGuideFixture.channels(count: 120, window: window)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(GuideHeading.isHeading(row), ProductionGuideFixture.rowKind(index) == .divider, row.name)
        }
    }

    // MARK: 2. The zap list

    /// Playback began on the small first page, where the divider had no programmes yet: the whole guide then makes it a
    /// heading, and channel up/down, the player's list and Go to number pass over it.
    func testAZapListSavedBeforeARowBecameAHeadingSkipsIt() throws {
        let a = ordinary("a", "A", number: 1), b = ordinary("b", "B", number: 3)
        let preview = channel("d", "### SPORTS ###", [], number: 2)
        let model = try browse([a, preview, b])
        let app = AppModel()
        app.configureClientForTesting(model.client, browse: model)
        app.beginPlayback(model.asChannel(a))
        app.zapList = model.playableChannels(model.guide)
        XCTAssertEqual(app.zapList.map(\.name), ["A", "### SPORTS ###", "B"], "no programmes yet: a channel")
        model.guide = [a, divider("d", number: 2), b]
        XCTAssertEqual(app.playerChannels.map(\.name), ["A", "B"], "the player's list")
        XCTAssertNil(app.channel(number: 2), "Go to number")
        app.zap(1)
        XCTAssertEqual(app.playback?.channel.name, "B", "channel up passes over the new heading")
        app.zap(-1)
        XCTAssertEqual(app.playback?.channel.name, "A", "and down")
    }

    // MARK: 3. The server's Search

    func testTheServersSearchLeavesOutTheGuidesHeadings() async throws {
        let dividerJSON = "{\"id\":\"d\",\"sourceId\":1,\"name\":\"### SPORTS ###\"}"
        let sportsJSON = "{\"id\":\"s\",\"sourceId\":1,\"name\":\"Sports One\"}"
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func hit(_ channel: String) -> String {
            "{\"channel\":\(channel),\"title\":\"Sports tonight\",\"start\":\(now - 60_000),\"end\":\(now + 3_600_000)}"
        }
        let body = "{\"q\":\"sports\",\"channels\":[\(dividerJSON),\(sportsJSON)],\"programmes\":[\(hit(dividerJSON)),\(hit(sportsJSON))]}"
        let server = try FakePigTVServer(routes: .init(answer: { request in
            request.path == "/api/library/search" ? LocalHTTPServer.Response.json(body) : nil
        }))
        defer { server.http.stop() }
        let model = try browse([divider("d"), ordinary("s", "Sports One")], client: try server.client())
        let runner = GuideSearchPage.runner(for: model)
        runner.update("sports")
        let end = Date().addingTimeInterval(5)
        while runner.searched == nil && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        let results = try XCTUnwrap(runner.results)
        XCTAssertEqual(results.source, .server)
        XCTAssertEqual(results.channels.map(\.id), ["1:s"], "the heading is not a channel to watch")
        XCTAssertEqual(results.programmes.map(\.channel.id), ["1:s"], "nor its programmes")
    }

    // MARK: 4. The Top Shelf

    func testAFavouriteThatIsAHeadingNeverReachesTheTopShelf() throws {
        let model = try browse([divider("d"), ordinary("a", "Film One"), ordinary("b", "Film Two")])
        model.favourites = [model.asChannel(model.guide[0])]
        let snapshot = try XCTUnwrap(model.topShelfSnapshot(now: Date()))
        XCTAssertEqual(snapshot.channels.map(\.name), ["Film One", "Film Two"], "the line-up instead")
        model.favourites = [model.asChannel(model.guide[0]), model.asChannel(model.guide[2])]
        XCTAssertEqual(try XCTUnwrap(model.topShelfSnapshot(now: Date())).channels.map(\.name), ["Film Two"])
    }

    // MARK: 5. Now and Jump to

    /// The last focused row turns into a heading while focus is on the header; Now then focuses its nearest channel.
    func testNowFocusesTheNearestChannelWhenTheRememberedRowBecameAHeading() throws {
        #if !os(tvOS)
        throw XCTSkip("focus claims are the TV's")
        #else
        var rows = (0..<10).map { ordinary("c\($0)", "Channel \($0)") }
        rows[2] = channel("d", "### SPORTS ###", []) // no programmes yet: a channel
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 1, loadedAt: nil))
        controller.view.layoutIfNeeded()
        controller.reportFocusForTesting(section: 2) // focused there, then focus went up to the header
        rows[2] = divider("d")
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 2, loadedAt: nil))
        let collection = try XCTUnwrap(controller.collectionView)
        let layout = try XCTUnwrap(collection.collectionViewLayout as? GuideGridLayout)
        let model = try browse(rows)
        let view = GuideGridView(rows: rows, rowsVersion: 1, model: model, origin: layout.origin,
                                 loadedDuration: layout.loadedDuration, clock: Date(), scheduled: [], recording: [],
                                 request: GuideGridRequest(viewport: Date(), focus: true), resetToken: 0,
                                 actions: GuideGridActions(select: { _, _ in }, play: { _ in }, focusChanged: { _, _ in },
                                                           viewportChanged: { _ in }))
        controller.update(from: view)
        let target = try XCTUnwrap(controller.indexPathForPreferredFocusedView(in: collection), "Now set a focus target")
        XCTAssertEqual(target.section, 3, "the channel under the heading, not the heading")
        #endif
    }
}
