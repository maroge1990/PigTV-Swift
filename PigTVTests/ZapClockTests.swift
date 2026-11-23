import XCTest
@testable import PigTV

// #36 (Apple 400): zapMs, the press to the first `.playing`, once per play.
@MainActor
final class ZapClockTests: XCTestCase {
    private let press = Date(timeIntervalSince1970: 1_800_000_000)

    func testItRunsFromThePressToTheFirstPlaying() {
        var clock = ZapClock()
        clock.pressed(at: press)
        XCTAssertEqual(clock.playing(at: press.addingTimeInterval(6.1234)), 6123)
    }

    func testItReportsOncePerPlay() {
        var clock = ZapClock()
        clock.pressed(at: press)
        XCTAssertEqual(clock.playing(at: press.addingTimeInterval(2)), 2000)
        XCTAssertNil(clock.playing(at: press.addingTimeInterval(9)), "a reconnect's playing is not a zap")
        clock.pressed(at: press.addingTimeInterval(20)) // Try again after it played: still the one play
        XCTAssertNil(clock.playing(at: press.addingTimeInterval(21)))
    }

    func testANewPressBeforeThePictureRestartsIt() {
        var clock = ZapClock()
        clock.pressed(at: press)
        clock.pressed(at: press.addingTimeInterval(30)) // Try again after a failed start
        XCTAssertEqual(clock.playing(at: press.addingTimeInterval(31.5)), 1500)
    }

    func testAPlayThatNeverPlaysOrWasNeverPressedReportsNothing() {
        let never = ZapClock()
        XCTAssertNil(never.pressedAt)
        XCTAssertFalse(never.reported)
        var unpressed = ZapClock()
        XCTAssertNil(unpressed.playing(at: press))
        var early = ZapClock()
        early.pressed(at: press)
        XCTAssertEqual(early.playing(at: press.addingTimeInterval(-1)), 0, "a clock step back is never negative")
    }

    func testTheEventCarriesZapMsOnlyWhenMeasured() throws {
        var event = PlaybackEvent(event: "play-start")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("zapMs"))
        event.zapMs = 4210
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains(#""zapMs":4210"#))
    }
}
