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

    func testLegacyUnscopedKeysAreRetiredAndOthersKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pigtv.tests.resume.\(UUID().uuidString)"))
        let scoped = try XCTUnwrap(Recording.localResumeKey(42, address: try ServerAddress("http://127.0.0.1:3000"), accountID: 1))
        defaults.set(900.0, forKey: "pigtv.resume.42")
        defaults.set(900.0, forKey: scoped)
        defaults.set(true, forKey: "pigtv.recordings.autoSkip")
        XCTAssertEqual(Recording.retireLegacyResumeKeys(in: defaults), 1)
        XCTAssertNil(defaults.object(forKey: "pigtv.resume.42"), "an unscoped position is never read again")
        XCTAssertEqual(defaults.double(forKey: scoped), 900)
        XCTAssertTrue(defaults.bool(forKey: "pigtv.recordings.autoSkip"))
    }

    @MainActor
    func testRecordingsProgressReadsOnlyThisAccountsPositions() throws {
        let address = try ServerAddress("http://127.0.0.1:3999")
        let first = APIClient(address: address, token: "a", accountID: 1)
        let second = APIClient(address: address, token: "b", accountID: 2)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":424242,"title":"T","status":"completed","duration_sec":3600}"#.utf8))
        let key = try XCTUnwrap(first.localResumeKey(424242))
        UserDefaults.standard.set(600.0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertNotNil(BrowseModel(client: first, accountID: 1).progress(for: recording).fraction)
        XCTAssertNil(BrowseModel(client: second, accountID: 2).progress(for: recording).fraction, "another login sees nothing")
    }
}
