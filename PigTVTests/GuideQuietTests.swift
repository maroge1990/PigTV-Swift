import SwiftUI
import XCTest
@testable import PigTV

/// maroge1990/PigTV#360 (speed programme, batch 2): the Guide's quiet paths, on the real views in a window. A focus move
/// must not re-evaluate GuideView.body (G1); the 30 s clock tick must not either, nor reconfigure cells whose drawing did
/// not change (G5); rows that arrive while focus is moving wait for it to be still (the cheap half of G2).
@MainActor
final class GuideQuietTests: XCTestCase {
    private var window: UIWindow?
    private var savedFilter: Any?

    override func setUp() async throws {
        savedFilter = UserDefaults.standard.object(forKey: "pigtv.guide.filter")
        UserDefaults.standard.set("all", forKey: "pigtv.guide.filter")
        GuidePerf.resetForTests()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        UserDefaults.standard.set(savedFilter, forKey: "pigtv.guide.filter")
        GuidePerf.resetForTests()
    }

    private func spin(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func until(_ what: String, timeout: TimeInterval = 10, _ ok: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(ok(), what)
    }

    private func gridController(in view: UIViewController) -> GuideGridViewController? {
        if let grid = view as? GuideGridViewController { return grid }
        for child in view.children { if let found = gridController(in: child) { return found } }
        return nil
    }

    /// The Guide (the offline fixture) in a window, its grid filled.
    private func hostGuide() async throws -> (AppModel, GuideGridViewController) {
        #if os(iOS)
        // The iPhone upright shows the On now list, not the grid (GuideLayout.usesOnNowList).
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("the iPhone's Guide has no grid") }
        #endif
        let app = AppModel()
        app.injectGuideFixture()
        let model = try XCTUnwrap(app.browse)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: GuideView(app: app, model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        var grid: GuideGridViewController?
        try await until("the grid shows its rows") {
            grid = gridController(in: host)
            return (grid?.rowCountForTesting ?? 0) > 0
        }
        try await spin(0.5) // the first screen's reveal steps and the shell settle
        return (app, try XCTUnwrap(grid))
    }

    // MARK: G1

    /// A focus move tells GuideView (`focusChanged`), which used to write `@State` focus and an `@AppStorage` key, so
    /// every move re-evaluated the whole body (header, chips, the grid's update). Now nothing the body observes changes.
    func testAFocusMoveDoesNotReevaluateTheGuidesBody() async throws {
        let (_, grid) = try await hostGuide()
        let before = GuidePerf.bodyEvaluationsForTesting
        for section in 1...6 {
            grid.reportFocusForTesting(section: section)
            try await spin(0.1)
        }
        try await spin(0.3)
        XCTAssertEqual(GuidePerf.bodyEvaluationsForTesting - before, 0, "focus moves re-evaluated GuideView.body")
    }

    // MARK: G5

    /// Review of 377: the long-press menu card drew its items from a time taken when GuideView.body last ran, and since
    /// 377 the 30 s tick no longer runs it, so a card left open past its programme's end kept offering to record a
    /// programme that had finished. The card now reads the clock: the tick after the end takes the RECORD items away.
    func testAMenuLeftOpenPastItsProgrammesEndDropsTheRecordItemsAtTheTick() async throws {
        let (_, grid) = try await hostGuide()
        GuideView.menuItemsForTesting = nil
        let programme = try XCTUnwrap(grid.openMenuForTesting(section: 0), "row 0 has a programme on now or later")
        try await until("the menu card is drawn with its RECORD items") {
            GuideView.menuItemsForTesting?.contains(where: \.isRecordSection) == true
        }
        NotificationCenter.default.post(name: GuideView.clockTickForTesting, object: programme.end.addingTimeInterval(1))
        try await spin(0.5)
        let items = try XCTUnwrap(GuideView.menuItemsForTesting)
        XCTAssertEqual(items.filter(\.isRecordSection), [],
                       "the card still offers to record a programme that finished before the tick: \(items.map(\.id))")
        XCTAssertTrue(items.contains(.schedule), "the rest of the card stays")
        // Chosen between two ticks, after the end: a RECORD item does nothing (the card is redrawn without it).
        let subject = ProgrammeMenuSubject(channelName: "Channel", programme: programme)
        XCTAssertTrue(GuideView.stillOffered(.recordThis(), subject, now: programme.end.addingTimeInterval(-1)))
        XCTAssertFalse(GuideView.stillOffered(.recordThis(), subject, now: programme.end.addingTimeInterval(1)))
        XCTAssertFalse(GuideView.stillOffered(.recordEvery(title: "Record every new episode"), subject, now: programme.end))
        XCTAssertTrue(GuideView.stillOffered(.schedule, subject, now: programme.end.addingTimeInterval(1)))
    }

    /// Codex sign-off of 380: the iPhone's On now menu shows "Change recording" with the status it had when it opened; the
    /// Guide rebuilds the subject when it is chosen, and a schedule refresh may have moved "Recording scheduled" to
    /// "Recording now" meanwhile. The programme is still on air, so the choice must run: only its end can take it away.
    func testAChangeRecordingChosenAfterTheStatusChangedStillRuns() {
        let now = Date()
        let programme = GuideProgramme(title: "On air", description: nil, startTime: (now - 600).timeIntervalSince1970 * 1000,
                                       endTime: (now + 1800).timeIntervalSince1970 * 1000)
        let shown = ProgrammeMenuItem.changeRecording(status: "Recording scheduled")
        let rebuilt = ProgrammeMenuSubject(channelName: "Channel", programme: programme, recordingStatus: "Recording now")
        XCTAssertTrue(GuideView.stillOffered(shown, rebuilt, now: now),
                      "a Change recording chosen on a programme still on air did nothing (its status changed meanwhile)")
        XCTAssertTrue(GuideView.stillOffered(.recordThis(), rebuilt, now: now), "an action on a programme that has not ended always runs")
        XCTAssertFalse(GuideView.stillOffered(shown, rebuilt, now: programme.end.addingTimeInterval(1)), "ended: nothing runs")
    }

    private func channel(_ id: String, _ programmes: [(start: Date, end: Date)]) -> GuideChannel {
        GuideChannel(rawID: id, sourceId: 1, name: "Channel \(id)", logo: nil, category: "News", programmes: programmes.enumerated().map {
            GuideProgramme(title: "\(id) \($0.offset)", description: nil, startTime: $0.element.start.timeIntervalSince1970 * 1000,
                           endTime: $0.element.end.timeIntervalSince1970 * 1000)
        })
    }

    /// The 30 s tick used to give every visible programme cell a new `clock`, so all of them rebuilt their SwiftUI content.
    /// Now only cells whose drawing depends on the time and changed are configured again: the on-air programmes (their
    /// progress bar) and a roll-over (the one that finished dims, the next goes on air).
    func testTheClockTickReconfiguresOnlyTheCellsWhoseDrawingChanged() throws {
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let now = Date()
        var rows = (0..<5).map { channel("c\($0)", [(now - 600, now + 3000), (now + 3000, now + 6600)]) }
        // Its programme ends 10 s from now: at the tick it has finished and the next one is on air.
        rows.append(channel("roll", [(now - 1200, now + 10), (now + 10, now + 3600)]))
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 1, loadedAt: nil))
        controller.setClockForTesting(now)
        let tick = now + 30
        let visible = controller.visibleProgrammesForTesting()
        let rowsShown = Set(visible.map(\.section))
        XCTAssertEqual(rowsShown.count, rows.count, "every row is on screen")
        func onAir(_ cell: (section: Int, item: Int, title: String?, frame: CGRect, cell: UICollectionViewCell), at time: Date) -> Bool {
            guard let title = cell.title, let p = rows[cell.section].programmes.first(where: { $0.title == title }) else { return false }
            return p.isLive(at: time)
        }
        // Drawn differently at the tick: on air then (the bar moved, or it went on air), or on air before and finished now.
        let changed = visible.filter { onAir($0, at: tick) || onAir($0, at: now) }.count
        XCTAssertGreaterThan(visible.count, changed, "some visible cells do not depend on the time (later programmes)")
        let before = GuidePerf.cellConfigurationsForTesting
        controller.setClockForTesting(tick)
        XCTAssertEqual(GuidePerf.cellConfigurationsForTesting - before, changed,
                       "the tick reconfigured \(GuidePerf.cellConfigurationsForTesting - before) cells; \(changed) changed what they draw")
    }

    // MARK: G8

    /// A grid of `count` rows in a window, the clock at `now`, laid out.
    private func hostGrid(rows count: Int, now: Date) throws -> (GuideGridViewController, GuideGridLayout) {
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let rows = (0..<count).map { channel("v\($0)", [(now - 600, now + 3000), (now + 3000, now + 6600)]) }
        controller.applyForTesting(rows: rows, revision: GuideGridRevision(programmes: 1, loadedAt: nil))
        controller.setClockForTesting(now)
        let layout = try XCTUnwrap(controller.collectionView.collectionViewLayout as? GuideGridLayout)
        return (controller, layout)
    }

    /// What a laid-out grid shows must not depend on how it got there: every visible row has its tile pinned at the left
    /// edge and its programmes clipped at the channel column, and the now line spans the visible rows from the top.
    private func assertDrawnAsLaidOut(_ grid: UICollectionView, _ layout: GuideGridLayout, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let m = layout.metrics
        let x = grid.contentOffset.x
        let rows = GuideGridMath.rows(in: grid.bounds.minY, grid.bounds.maxY, count: grid.numberOfSections, metrics: m)
        XCTAssertFalse(rows.isEmpty, "\(label): rows on screen", file: file, line: line)
        for row in rows {
            let tile = grid.cellForItem(at: IndexPath(item: 0, section: row))
            XCTAssertEqual(tile?.frame, GuideGridMath.tileFrame(row: row, offsetX: x, metrics: m),
                           "\(label): row \(row)'s tile is pinned", file: file, line: line)
            let programmes = grid.indexPathsForVisibleItems.filter { $0.section == row && $0.item > 0 }
            XCTAssertFalse(programmes.isEmpty, "\(label): row \(row) shows its programmes", file: file, line: line)
            for indexPath in programmes {
                XCTAssertGreaterThanOrEqual(grid.cellForItem(at: indexPath)?.frame.minX ?? -1, GuideGridMath.clipX(offsetX: x, metrics: m),
                                            "\(label): \(indexPath) is clipped at the channel column", file: file, line: line)
            }
        }
        let nowLine = grid.subviews.first { $0 is GuideGridNowLine && !$0.isHidden }
        XCTAssertNotNil(nowLine, "\(label): the now line shows", file: file, line: line)
        XCTAssertEqual(nowLine?.frame.minY, grid.contentOffset.y, "\(label): the now line starts at the top", file: file, line: line)
        XCTAssertEqual(nowLine?.frame.height, grid.bounds.height, "\(label): the now line spans the rows", file: file, line: line)
    }

    /// Every scroll step used to invalidate the whole layout (`shouldInvalidateLayout(forBoundsChange:)` true, the default
    /// context), so UIKit redid every visible element's attributes on each frame of a vertical scroll. Only the now line
    /// follows the vertical offset (the tiles and the clipping follow the horizontal one), so a vertical step now
    /// invalidates the now line alone, and the grid draws exactly as before. Review of 378: counted as the layout's real
    /// work, its `layoutAttributesForElements(in:)` calls (`prepare()` does almost nothing), not as an invalidation flag.
    func testAVerticalScrollDoesNotRedoTheWholeLayout() throws {
        // The clock an hour after the grid's origin: the now line is inside the timeline before and after the sideways step.
        let (controller, layout) = try hostGrid(rows: 80, now: Date() + 3600)
        let grid = try XCTUnwrap(controller.collectionView)
        assertDrawnAsLaidOut(grid, layout, "at the top")
        let steps = 20
        /// The layout's element queries over `steps` small vertical steps (a twentieth of a row each, about a press's scroll frames).
        func queries(from start: CGFloat) -> Int {
            let before = layout.elementQueries
            for step in 1...steps {
                grid.contentOffset.y = start + CGFloat(step) * layout.metrics.rowHeight / 20
                grid.layoutIfNeeded()
            }
            return layout.elementQueries - before
        }
        // The measure itself: with the old whole-layout invalidation (as before Apple 378), every step is a query.
        GuideGridLayout.wholeLayoutOnScroll = true
        let old = queries(from: 0)
        GuideGridLayout.wholeLayoutOnScroll = false
        XCTAssertGreaterThanOrEqual(old, steps, "the old layout is re-queried on every step")
        let now = queries(from: grid.contentOffset.y)
        XCTAssertLessThanOrEqual(now, steps / 4, "vertical scroll steps redid the layout's work: \(now) queries in \(steps) steps")
        for step in 1...8 {
            grid.contentOffset.y = CGFloat(step) * layout.metrics.rowHeight * 2.5
            grid.layoutIfNeeded()
        }
        assertDrawnAsLaidOut(grid, layout, "after scrolling down")
        // Back up past where it started, then sideways: a horizontal step still redoes everything (the tiles follow it).
        grid.contentOffset.y = layout.metrics.rowHeight / 2
        grid.layoutIfNeeded()
        assertDrawnAsLaidOut(grid, layout, "after scrolling back up")
        let sideways = layout.fullPrepares
        controller.collectionView.setX(grid.contentOffset.x + 300)
        grid.layoutIfNeeded()
        XCTAssertGreaterThan(layout.fullPrepares, sideways, "a horizontal step re-lays the pinned column")
        assertDrawnAsLaidOut(grid, layout, "after scrolling sideways")
    }
}
