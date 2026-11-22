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
}
