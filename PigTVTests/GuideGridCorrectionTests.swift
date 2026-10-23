import XCTest
@testable import PigTV

/// A4 (build 48): a guide correction with the same shape - same channels, same programme counts,
/// same first start, the clock unchanged - but a new title and a later end. ba10988 made the store
/// serve the new revision; the grid itself classified the update as an append with nothing to
/// append and redrew nothing until the next clock tick. The real GuideGridViewController in a
/// window; the visible cell must show the new title and the new width at once, and stay the same
/// cell (reconfigured, not reloaded), so focus on it is kept.
@MainActor
final class GuideGridCorrectionTests: XCTestCase {
    private func channel(_ id: String, title: String, start: Date, minutes: Double) -> GuideChannel {
        let s = start.timeIntervalSince1970 * 1000
        return GuideChannel(rawID: id, sourceId: 1, name: "Channel \(id)", logo: nil, category: "Sport", programmes: [
            GuideProgramme(title: title, description: nil, startTime: s, endTime: s + minutes * 60_000),
            GuideProgramme(title: "After \(id)", description: nil, startTime: s + minutes * 60_000, endTime: s + (minutes + 60) * 60_000)])
    }

    func testASameShapeCorrectionShowsAtOnceInTheSameCell() throws {
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        let start = Date().addingTimeInterval(-10 * 60)
        let before = [channel("a", title: "Match Day", start: start, minutes: 60), channel("b", title: "News", start: start, minutes: 60)]
        controller.applyForTesting(rows: before, revision: GuideGridRevision(programmes: 1, loadedAt: nil))
        controller.view.layoutIfNeeded()
        let old = try XCTUnwrap(controller.visibleProgrammesForTesting().first { $0.section == 0 && $0.title == "Match Day" })

        // The correction: same shape and first start; a new title and 30 minutes more.
        let after = [channel("a", title: "Match Day - Extra Time", start: start, minutes: 90), before[1]]
        controller.applyForTesting(rows: after, revision: GuideGridRevision(programmes: 2, loadedAt: nil))

        // The same index path (the row's first programme): its frame's start may be clipped differently.
        let now = try XCTUnwrap(controller.visibleProgrammesForTesting().first { $0.section == 0 && $0.item == old.item })
        XCTAssertEqual(now.title, "Match Day - Extra Time", "the visible text is the correction's, at once")
        // 30 minutes longer: its end moves right by half of the next programme's 60-minute width.
        let hour = try XCTUnwrap(controller.visibleProgrammesForTesting().first { $0.section == 1 && $0.title == "After b" }).frame.width
        XCTAssertEqual(now.frame.maxX - old.frame.maxX, hour / 2, accuracy: 6, "and the cell ends at the new end, at once") // (cells sit a few points apart)
        XCTAssertTrue(now.cell === old.cell, "the same cell, reconfigured rather than reloaded: focus on it is kept")
        XCTAssertEqual(controller.visibleProgrammesForTesting().first { $0.section == 1 }?.title, "News", "other rows untouched")
    }
}
