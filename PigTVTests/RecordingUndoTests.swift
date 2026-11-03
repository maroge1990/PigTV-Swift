import XCTest
@testable import PigTV

/// Apple 122 (D-44 point 9): delete a recording, cancel a schedule, remove a rule: the item goes at once, the server call
/// waits for the 10 s Undo (or the app going to the background), Undo puts it back without a call, and a committed call
/// that fails puts it back and says why.
@MainActor
final class RecordingUndoTests: XCTestCase {
    private func server(_ log: Locked<[String]>, ruleStatus: Int = 200) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            log.value.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("DELETE", "/api/recordings/30"):
                return .json(#"{"success":true}"#)
            case ("DELETE", "/api/recordings/scheduled/9"):
                return .json(#"{"id":9,"title":"News","program_start":1,"program_end":2,"status":"cancelled"}"#)
            case ("DELETE", "/api/recordings/rules/7"):
                return ruleStatus == 200 ? .json(#"{"success":true,"cancelled":0}"#) : .json(#"{"error":"Share offline"}"#, status: ruleStatus)
            case ("GET", "/api/recordings/scheduled"), ("GET", "/api/recordings"), ("GET", "/api/recordings/rules"):
                return .json("[]")
            default:
                return .notFound
            }
        }
    }

    private func model(_ http: LocalHTTPServer) throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
    }

    /// A presenter whose 10 s never run out by themselves (the test commits or undoes).
    private func presenter() -> AppPresenter {
        let presenter = AppPresenter()
        presenter.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        return presenter
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testDeleteHidesAtOnceAndUndoPutsItBackWithoutACall() async throws {
        let log = Locked<[String]>([])
        let http = try server(log)
        defer { http.stop() }
        let model = try model(http)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        model.recordings = [recording]
        let presenter = presenter()
        model.deleteWithUndo(recording, presenter: presenter)
        XCTAssertEqual(presenter.pendingUndo?.message, "The Headlines deleted with its file")
        XCTAssertTrue(RecordingsHome.shelf(model.recordings, hidden: model.recordingStore.pendingRemovals).isEmpty, "gone at once")
        presenter.undoPending()
        XCTAssertFalse(RecordingsHome.shelf(model.recordings, hidden: model.recordingStore.pendingRemovals).isEmpty, "back on Undo")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(log.value.contains("DELETE /api/recordings/30"), "Undo sends nothing: \(log.value)")
    }

    func testACommittedCancelWaitsForAChangeInFlightThenSendsIt() async throws {
        let log = Locked<[String]>([])
        let http = try server(log)
        defer { http.stop() }
        let model = try model(http)
        let schedule = try JSONDecoder().decode(ScheduledRecording.self,
            from: Data(#"{"id":9,"title":"News","program_start":1,"program_end":2,"status":"scheduled"}"#.utf8))
        model.schedules = [schedule]
        let presenter = presenter()
        model.cancelWithUndo(schedule, presenter: presenter)
        XCTAssertEqual(presenter.pendingUndo?.message, "Recording of News cancelled")
        XCTAssertTrue(model.marks.scheduledKeys.isEmpty, "the guide's mark goes at once")
        model.mutationBusy = true // another change in flight when the app goes to the background
        presenter.commitPendingUndo()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(log.value.contains("DELETE /api/recordings/scheduled/9"), "nothing is sent while the other change runs")
        model.mutationBusy = false
        await waitUntil { log.value.contains("DELETE /api/recordings/scheduled/9") && model.recordingStore.pendingRemovals.isEmpty }
        XCTAssertTrue(log.value.contains("DELETE /api/recordings/scheduled/9"), "sent once it is free: \(log.value)")
        XCTAssertTrue(model.recordingStore.pendingRemovals.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testARuleRemovalThatFailsComesBackAndSaysWhy() async throws {
        let log = Locked<[String]>([])
        let http = try server(log, ruleStatus: 500)
        defer { http.stop() }
        let model = try model(http)
        let rule = try JSONDecoder().decode(RecordingRule.self, from: Data(#"{"id":7,"kind":"series","match":"Gruen","enabled":true}"#.utf8))
        model.recordingStore.rules = [rule]
        let presenter = presenter()
        model.removeRuleWithUndo(rule, presenter: presenter)
        XCTAssertEqual(presenter.pendingUndo?.message, "Rule removed: Series: Gruen")
        XCTAssertTrue(ScheduledRows.rules(model.recordingStore.rules, hidden: model.recordingStore.pendingRemovals).isEmpty)
        presenter.commitPendingUndo()
        await waitUntil { model.recordingStore.pendingRemovals.isEmpty }
        XCTAssertTrue(log.value.contains("DELETE /api/recordings/rules/7"))
        XCTAssertEqual(ScheduledRows.rules(model.recordingStore.rules, hidden: model.recordingStore.pendingRemovals).map(\.id), [7],
                       "a removal the server refused shows the rule again")
        XCTAssertNotNil(model.actionError, "and says why")
    }
}
