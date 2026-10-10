import XCTest
@testable import PigTV

// Resume position: server vs local source, the Resume / Start over question
// and when a position is worth saving.
final class RecordingResumeTests: XCTestCase {
    func testServerAnswerWinsWhenTheFeatureIsOn() {
        let server = RecordingPosition(position_sec: 900, watched: false)
        let picked = RecordingResume.source(featureOn: true, server: server, local: 3000)
        XCTAssertEqual(picked.position, 900)
        XCTAssertFalse(picked.watched)
    }

    func testLocalKeyIsUsedWithoutTheFeatureOrWhenTheServerDidNotAnswer() {
        let server = RecordingPosition(position_sec: 900, watched: true)
        XCTAssertEqual(RecordingResume.source(featureOn: false, server: server, local: 3000).position, 3000)
        XCTAssertFalse(RecordingResume.source(featureOn: false, server: server, local: 3000).watched)
        XCTAssertEqual(RecordingResume.source(featureOn: true, server: nil, local: 3000).position, 3000)
    }

    func testServerNullsMeanNothingRemembered() {
        let picked = RecordingResume.source(featureOn: true, server: RecordingPosition(position_sec: nil, watched: nil), local: 3000)
        XCTAssertEqual(picked.position, 0)
        XCTAssertNil(RecordingResume.prompt(position: picked.position, watched: picked.watched, duration: 3600, featureOn: true))
    }

    func testPromptNeedsMoreThanTenSecondsAndNotWatched() {
        XCTAssertEqual(RecordingResume.prompt(position: 600, watched: false, duration: 3600, featureOn: true), 600)
        XCTAssertNil(RecordingResume.prompt(position: 10, watched: false, duration: 3600, featureOn: true))
        XCTAssertNil(RecordingResume.prompt(position: 600, watched: true, duration: 3600, featureOn: true))
        XCTAssertNil(RecordingResume.prompt(position: .nan, watched: false, duration: 3600, featureOn: true))
    }

    func testLocalPositionNearTheEndIsNotOfferedButTheServerDecidesItsOwn() {
        XCTAssertNil(RecordingResume.prompt(position: 3590, watched: false, duration: 3600, featureOn: false))
        XCTAssertEqual(RecordingResume.prompt(position: 3590, watched: false, duration: 3600, featureOn: true), 3590)
        XCTAssertEqual(RecordingResume.prompt(position: 600, watched: false, duration: nil, featureOn: false), 600)
    }

    func testClockFormat() {
        XCTAssertEqual(RecordingResume.clock(65), "1:05")
        XCTAssertEqual(RecordingResume.clock(3909), "1:05:09")
        XCTAssertEqual(RecordingResume.clock(-4), "0:00")
    }

    func testNeverSavesZeroOrJunk() {
        XCTAssertFalse(RecordingResume.shouldSave(0))
        XCTAssertFalse(RecordingResume.shouldSave(-1))
        XCTAssertFalse(RecordingResume.shouldSave(.nan))
        XCTAssertTrue(RecordingResume.shouldSave(0.5))
        XCTAssertFalse(RecordingResume.dueForPeriodicSave(now: 0, lastSaved: nil))
    }

    func testPeriodicSavesEveryTenSeconds() {
        XCTAssertTrue(RecordingResume.dueForPeriodicSave(now: 3, lastSaved: nil))
        XCTAssertFalse(RecordingResume.dueForPeriodicSave(now: 12, lastSaved: 3))
        XCTAssertTrue(RecordingResume.dueForPeriodicSave(now: 13, lastSaved: 3))
        XCTAssertTrue(RecordingResume.dueForPeriodicSave(now: 5, lastSaved: 300), "a rewind counts")
    }

    func testPositionReplyDecodes() throws {
        let reply = try JSONDecoder().decode(RecordingPosition.self, from: Data(#"{"position_sec":812.5,"watched":false,"updated_at":"2026-10-10T01:02:03Z"}"#.utf8))
        XCTAssertEqual(reply, RecordingPosition(position_sec: 812.5, watched: false))
    }
}
