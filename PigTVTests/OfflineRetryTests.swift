import XCTest
@testable import PigTV

/// D-44 batch 6 (Apple 132): the Offline screen's ring counts down the 20 seconds to the next retry.
final class OfflineRetryTests: XCTestCase {
    func testTheRingCountsDownTwentySecondsFromTheLastAttempt() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(RetryCountdown.remaining(from: start, now: start), 20)
        XCTAssertEqual(RetryCountdown.remaining(from: start, now: start.addingTimeInterval(5.5)), 15, "whole seconds, rounded up")
        XCTAssertEqual(RetryCountdown.remaining(from: start, now: start.addingTimeInterval(25)), 0)
        XCTAssertEqual(RetryCountdown.fraction(from: start, now: start), 1)
        XCTAssertEqual(RetryCountdown.fraction(from: start, now: start.addingTimeInterval(5)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(RetryCountdown.fraction(from: start, now: start.addingTimeInterval(30)), 0)
        XCTAssertEqual(RetryCountdown.text(14), "Trying again in 14 seconds")
        XCTAssertEqual(RetryCountdown.text(1), "Trying again in 1 second")
    }
}
