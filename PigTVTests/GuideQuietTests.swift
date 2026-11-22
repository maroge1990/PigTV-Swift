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
}
