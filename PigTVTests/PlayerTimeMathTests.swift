import XCTest
@testable import PigTV

// C-E: Start over and the programme timeline under an hours-long window.
final class PlayerTimeMathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProgrammeFraction() {
        let start = now.addingTimeInterval(-1800), end = now.addingTimeInterval(1800)
        XCTAssertEqual(PlayerTimeMath.fraction(of: now, from: start, to: end), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlayerTimeMath.fraction(of: start.addingTimeInterval(-60), from: start, to: end), 0)
        XCTAssertEqual(PlayerTimeMath.fraction(of: end.addingTimeInterval(60), from: start, to: end), 1)
        XCTAssertEqual(PlayerTimeMath.fraction(of: now, from: start, to: start), 0)
    }

    func testBehindTextSwitchesToHoursAndMinutes() {
        XCTAssertEqual(PlayerTimeMath.behindText(45), "0:45")
        XCTAssertEqual(PlayerTimeMath.behindText(3599), "59:59")
        XCTAssertEqual(PlayerTimeMath.behindText(3600), "1 h 00 min")
        XCTAssertEqual(PlayerTimeMath.behindText(2 * 3600 + 5 * 60 + 40), "2 h 05 min")
        XCTAssertEqual(PlayerTimeMath.behindText(.nan), "0:00")
    }
}
