import XCTest
@testable import PigTV

// A4.4: the iPhone "On now" list's per-row now/next/progress.
final class OnNowRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String, _ start: TimeInterval, _ end: TimeInterval) -> GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    func testNowNextAndProgress() {
        // Unordered, with a finished programme and a later one.
        let list = [programme("Later", 3600, 7200), programme("Now", -900, 2700),
                    programme("Earlier", -4500, -900), programme("Next", 2700, 3600)]
        let row = OnNowRow.make(programmes: list, now: now)
        XCTAssertEqual(row.current?.title, "Now")
        XCTAssertEqual(row.next?.title, "Next")
        XCTAssertEqual(row.progress, 0.25, accuracy: 0.0001)
    }

    func testGapAndEmpty() {
        // Nothing on now: no progress, and next is the first programme after now.
        let row = OnNowRow.make(programmes: [programme("Gone", -600, -60), programme("Soon", 600, 1200),
                                             programme("Broken", 300, 300)], now: now)
        XCTAssertNil(row.current)
        XCTAssertEqual(row.next?.title, "Soon", "zero-length entries are skipped")
        XCTAssertEqual(row.progress, 0)
        XCTAssertEqual(OnNowRow.make(programmes: [], now: now), OnNowRow(current: nil, next: nil, progress: 0))
    }
}
