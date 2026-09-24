import XCTest
@testable import PigTV

// C-E: Start over and the programme timeline under an hours-long window.
final class TimeshiftMathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRangeDatesFromCurrentDate() throws {
        // A 3 h window (media times 100…10 900 s); the picture is 20 min
        // behind the edge and its program date is 20 min before now.
        let current = 10_900.0 - 1200
        let window = try XCTUnwrap(TimeshiftMath.rangeDates(currentDate: now.addingTimeInterval(-1200),
                                                            currentTime: current, rangeStart: 100, rangeEnd: 10_900))
        XCTAssertEqual(window.lowerBound, now.addingTimeInterval(-10_800))
        XCTAssertEqual(window.upperBound, now)
        XCTAssertNil(TimeshiftMath.rangeDates(currentDate: now, currentTime: .nan, rangeStart: 0, rangeEnd: 10))
        XCTAssertNil(TimeshiftMath.rangeDates(currentDate: now, currentTime: 5, rangeStart: 10, rangeEnd: 0))
    }

    func testStartOverNeedsTheProgrammeStartInsideTheWindow() {
        let window = now.addingTimeInterval(-10_800)...now
        XCTAssertTrue(TimeshiftMath.canStartOver(programmeStart: now.addingTimeInterval(-3600), window: window))
        XCTAssertTrue(TimeshiftMath.canStartOver(programmeStart: window.lowerBound, window: window))
        // Began before the window (a 4 h film): the start is gone.
        XCTAssertFalse(TimeshiftMath.canStartOver(programmeStart: now.addingTimeInterval(-14_400), window: window))
        // Not started yet.
        XCTAssertFalse(TimeshiftMath.canStartOver(programmeStart: now.addingTimeInterval(60), window: window))
        // A short (old-style) window of a few minutes rarely holds a start.
        let short = now.addingTimeInterval(-300)...now
        XCTAssertFalse(TimeshiftMath.canStartOver(programmeStart: now.addingTimeInterval(-1800), window: short))
    }

    func testProgrammeFraction() {
        let start = now.addingTimeInterval(-1800), end = now.addingTimeInterval(1800)
        XCTAssertEqual(TimeshiftMath.fraction(of: now, from: start, to: end), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TimeshiftMath.fraction(of: start.addingTimeInterval(-60), from: start, to: end), 0)
        XCTAssertEqual(TimeshiftMath.fraction(of: end.addingTimeInterval(60), from: start, to: end), 1)
        XCTAssertEqual(TimeshiftMath.fraction(of: now, from: start, to: start), 0)
    }

    func testBehindTextSwitchesToHoursAndMinutes() {
        XCTAssertEqual(TimeshiftMath.behindText(45), "0:45")
        XCTAssertEqual(TimeshiftMath.behindText(3599), "59:59")
        XCTAssertEqual(TimeshiftMath.behindText(3600), "1 h 00 min")
        XCTAssertEqual(TimeshiftMath.behindText(2 * 3600 + 5 * 60 + 40), "2 h 05 min")
        XCTAssertEqual(TimeshiftMath.behindText(.nan), "0:00")
    }
}
