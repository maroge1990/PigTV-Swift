import XCTest
@testable import PigTV

// Resume position: server vs local source, the Resume / Start over question
// and when a position is worth saving.
final class RecordingResumeTests: XCTestCase {
    func testResumeFraction() {
        XCTAssertEqual(Recording.resumeFraction(position: 900, duration: 1800), 0.5)
        XCTAssertNil(Recording.resumeFraction(position: 5, duration: 1800), "barely started")
        XCTAssertNil(Recording.resumeFraction(position: 1790, duration: 1800), "finished")
        XCTAssertNil(Recording.resumeFraction(position: 900, duration: nil))
    }

    func testServerAnswerWins() {
        let server = RecordingPosition(position_sec: 900, watched: false)
        let picked = RecordingResume.source(server: server, local: 3000)
        XCTAssertEqual(picked.position, 900)
        XCTAssertFalse(picked.watched)
    }

    func testLocalKeyIsUsedWhenTheServerDidNotAnswer() {
        XCTAssertEqual(RecordingResume.source(server: nil, local: 3000).position, 3000)
        XCTAssertFalse(RecordingResume.source(server: nil, local: 3000).watched)
    }

    func testServerNullsMeanNothingRemembered() {
        let picked = RecordingResume.source(server: RecordingPosition(position_sec: nil, watched: nil), local: 3000)
        XCTAssertEqual(picked.position, 0)
        XCTAssertNil(RecordingResume.prompt(position: picked.position, watched: picked.watched))
    }

    func testPromptNeedsMoreThanTenSecondsAndNotWatched() {
        XCTAssertEqual(RecordingResume.prompt(position: 600, watched: false), 600)
        XCTAssertNil(RecordingResume.prompt(position: 10, watched: false))
        XCTAssertNil(RecordingResume.prompt(position: 600, watched: true))
        XCTAssertNil(RecordingResume.prompt(position: .nan, watched: false))
        XCTAssertEqual(RecordingResume.prompt(position: 3590, watched: false), 3590, "the server decides when it is watched")
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

    // MARK: A1 (build 47): this device's saved positions are per server and account

    func testLocalKeysAreScopedToServerAndAccount() throws {
        let home = try ServerAddress("http://192.168.1.235:3000")
        let other = try ServerAddress("http://10.0.0.2:3000")
        let key = { (address: ServerAddress, account: Int?) in Recording.localResumeKey(42, address: address, accountID: account) }
        XCTAssertNotNil(key(home, 1))
        XCTAssertNotEqual(key(home, 1), key(other, 1), "recording 42 on another server is another recording")
        XCTAssertNotEqual(key(home, 1), key(home, 2), "another login on the same server")
        XCTAssertEqual(key(home, 1), key(try ServerAddress("http://192.168.1.235:3000/"), 1), "the canonical address")
        XCTAssertNil(key(home, nil), "no account: nothing local")
        XCTAssertFalse(key(home, 1)!.contains("192.168"), "the address is not in the key")
        XCTAssertTrue(key(home, 1)!.hasSuffix(".42"))
    }

    /// #17: "Play from live" joins a recording being made 30 s behind its playlist's end (the live player's hold), never
    /// before the start; nothing seekable yet is nil (the start).
    func testPlayFromLiveJoinsThirtySecondsBehindTheEdge() {
        XCTAssertEqual(RecordingLiveEdge.target([(0, 7200)]), 7170, "a two-hour game: half a minute from its live edge")
        XCTAssertEqual(RecordingLiveEdge.target([(0, 12)]), 0, "younger than the hold: from its start")
        XCTAssertEqual(RecordingLiveEdge.target([(0, 40), (100, 400)]), 370, "the last range")
        XCTAssertNil(RecordingLiveEdge.target([]))
        XCTAssertNil(RecordingLiveEdge.target([(0, .nan)]))
        XCTAssertEqual(RecordingLiveEdge.title, "Play from live")
    }
}
