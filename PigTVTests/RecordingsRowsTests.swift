import XCTest
@testable import PigTV

// The resume helper (server values vs this device's key), the Recordings
// page's continue-watching list and the needs-attention count.
final class RecordingsRowsTests: XCTestCase {
    private func recording(_ id: Int, status: String = "completed", started: Double = 1000, duration: Double? = 3600,
                           position: Double? = nil, watched: Bool? = nil) -> Recording {
        var json: [String: Any] = ["id": id, "title": "R\(id)", "started_at": started, "status": status]
        if let duration { json["duration_sec"] = duration }
        if let position { json["position_sec"] = position }
        if let watched { json["watched"] = watched }
        return try! JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func schedule(_ id: Int, _ status: String) -> ScheduledRecording {
        let json = #"{"id":\#(id),"title":"S","channel_name":"C","program_start":1,"program_end":2,"status":"\#(status)"}"#
        return try! JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    func testServerValuesWinWhenTheFeatureIsOn() {
        let item = recording(1, position: 900, watched: false)
        let progress = item.progress(serverPositions: true) { _ in 3000 }
        XCTAssertEqual(progress.fraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertFalse(progress.watched)
    }

    func testServerWatchedHasNoFraction() {
        let item = recording(1, position: 900, watched: true)
        XCTAssertEqual(item.progress(serverPositions: true) { _ in 0 }, RecordingProgress(fraction: nil, watched: true))
    }

    func testServerModeIgnoresTheLocalKey() {
        let item = recording(1)
        XCTAssertEqual(item.progress(serverPositions: true) { _ in 1800 }, .none)
    }

    func testLocalKeyIsUsedWithoutTheFeature() {
        let item = recording(7, position: 3000, watched: true) // server fields ignored
        let progress = item.progress(serverPositions: false) { $0 == 7 ? 1800 : 0 }
        XCTAssertEqual(progress.fraction ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertFalse(progress.watched)
    }

    func testLocalPositionNearTheEndCountsAsWatchedAndTinyOnesAsNothing() {
        let item = recording(7)
        XCTAssertEqual(item.progress(serverPositions: false) { _ in 3590 }, RecordingProgress(fraction: nil, watched: true))
        XCTAssertEqual(item.progress(serverPositions: false) { _ in 5 }, .none)
        XCTAssertEqual(item.progress(serverPositions: false) { _ in 0 }, .none)
    }

    func testOnlyCompletedRecordingsHaveProgress() {
        let live = recording(2, status: "recording", position: 900)
        XCTAssertEqual(live.progress(serverPositions: true) { _ in 0 }, .none)
    }

    func testContinueWatchingKeepsPartlyWatchedNewestFirst() {
        let old = recording(1, started: 100, position: 600)
        let new = recording(2, started: 900, position: 1200)
        let watched = recording(3, started: 500, position: 3500, watched: true)
        let untouched = recording(4, started: 800)
        let live = recording(5, status: "recording", started: 950, position: 600)
        let list = RecordingsRows.continueWatching([old, watched, untouched, new, live]) {
            $0.progress(serverPositions: true) { _ in 0 }
        }
        XCTAssertEqual(list.map(\.id), [2, 1])
    }

    func testAFailedRecordingOfAListedProblemScheduleIsNotCountedTwice() {
        func failed(_ id: Int, scheduled: Int?) -> Recording {
            var json: [String: Any] = ["id": id, "title": "F", "status": "failed"]
            if let scheduled { json["scheduled_id"] = scheduled }
            return try! JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let schedules = [schedule(1, "failed"), schedule(2, "missed"), schedule(3, "scheduled")]
        let rows = [failed(10, scheduled: 1), failed(11, scheduled: 2), failed(12, scheduled: 3), failed(13, scheduled: nil), failed(14, scheduled: 99)]
        // 10 and 11 belong to listed problem schedules; 3 is still active, 99 is unknown, 13 has none.
        XCTAssertEqual(RecordingsRows.failedRecordings(rows, schedules: schedules).map(\.id), [12, 13, 14])
        XCTAssertEqual(rows[0].scheduled_id, 1)
    }

    func testProblemCountsAndTitle() {
        let schedules = [schedule(1, "failed"), schedule(2, "missed"), schedule(3, "scheduled"), schedule(4, "completed")]
        XCTAssertEqual(RecordingsRows.problemSchedules(schedules).map(\.id), [1, 2])
        XCTAssertEqual(RecordingsRows.failedRecordings([recording(1), recording(2, status: "failed")], schedules: schedules).map(\.id), [2])
        XCTAssertNil(RecordingsRows.attentionTitle(failedSchedules: 0, missedSchedules: 0, failedRecordings: 0))
        XCTAssertEqual(RecordingsRows.attentionTitle(failedSchedules: 0, missedSchedules: 0, failedRecordings: 1), "1 recording failed")
        XCTAssertEqual(RecordingsRows.attentionTitle(failedSchedules: 2, missedSchedules: 0, failedRecordings: 1), "3 recordings failed")
        XCTAssertEqual(RecordingsRows.attentionTitle(failedSchedules: 1, missedSchedules: 1, failedRecordings: 0), "2 recordings failed or were missed")
        XCTAssertEqual(RecordingsRows.attentionTitle(failedSchedules: 0, missedSchedules: 1, failedRecordings: 0), "1 recording failed or was missed")
    }
}
