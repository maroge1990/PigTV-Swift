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
            case ("DELETE", "/api/recordings/31"):
                return .json(#"{"error":"Recording not found"}"#, status: 500)
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

    /// One test's UserDefaults: a "process" is a model with a new log on the same defaults.
    private lazy var defaults = UserDefaults(suiteName: "pigtv.undo.\(UUID().uuidString)")!

    private func model(_ http: LocalHTTPServer) throws -> BrowseModel {
        let model = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        model.removalLog = PendingRemovalLog(defaults: defaults)
        return model
    }

    private func deletes(_ log: Locked<[String]>, _ path: String) -> Int { log.value.filter { $0 == "DELETE \(path)" }.count }

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
        XCTAssertEqual(model.removalLog.all().map(\.id), [7], "and stays in the log, to be sent again")
    }

    /// Codex 5b round 1 (high): a removal committed as the app went to the background was only an in-memory task; a
    /// process killed before it ran lost it. It is in the log before anything is sent, and the next process sends it
    /// once; the first process, if it was not killed after all, finds it done and sends nothing.
    func testACommittedRemovalSurvivesAKilledProcessAndIsSentOnce() async throws {
        let log = Locked<[String]>([])
        let http = try server(log)
        defer { http.stop() }
        let first = try model(http)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        first.recordings = [recording]
        let presenter = presenter()
        first.deleteWithUndo(recording, presenter: presenter)
        first.mutationBusy = true // the send is held, as when the system suspends the app
        presenter.commitPendingUndo()
        XCTAssertEqual(first.removalLog.all().map(\.id), [30], "written before the toast went")
        // The process is killed; the next launch has a new model and log on the same defaults.
        let second = try model(http)
        second.replayPendingRemovals()
        await waitUntil { second.removalLog.all().isEmpty && !second.mutationBusy }
        XCTAssertEqual(deletes(log, "/api/recordings/30"), 1, "the next process sends it")
        XCTAssertTrue(second.removalLog.all().isEmpty, "confirmed, so it leaves the log")
        second.replayPendingRemovals()
        first.mutationBusy = false
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(deletes(log, "/api/recordings/30"), 1, "never sent twice: \(log.value)")
    }

    /// The item already gone (the server's "Recording not found", a 404 to the client) counts as done.
    func testAReplayedRemovalOfSomethingAlreadyGoneClearsIt() async throws {
        let log = Locked<[String]>([])
        let http = try server(log)
        defer { http.stop() }
        let model = try model(http)
        let scope = CacheScope(address: model.client.address, accountID: 1).digest
        model.removalLog.add(PendingRemoval(kind: .recording, id: 31, scope: scope))
        model.removalLog.add(PendingRemoval(kind: .recording, id: 99, scope: "another account"))
        model.replayPendingRemovals()
        await waitUntil { model.removalLog.pending(scope: scope).isEmpty }
        XCTAssertEqual(deletes(log, "/api/recordings/31"), 1)
        XCTAssertTrue(model.removalLog.pending(scope: scope).isEmpty, "gone counts as done")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.removalLog.all().map(\.id), [99], "another account's removal waits for that account")
        XCTAssertEqual(deletes(log, "/api/recordings/99"), 0)
    }

    /// Codex 5b round 1 (medium): the mask was cleared once the DELETE returned, but its own refresh returned at once
    /// while another was running; that older refresh, fetched before the delete, brought the recording back. Nor may a
    /// refresh that fails after the delete show it again. It stays hidden until a refresh that began after it loads.
    func testADeletedRecordingStaysGoneThroughAStaleRefreshAndAFailedOne() async throws {
        let log = Locked<[String]>([])
        let deleted = Locked(false)
        let failing = Locked(false)
        let staleRequests = Locked(0)
        let http = try LocalHTTPServer { request in
            log.value.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("DELETE", "/api/recordings/30"):
                deleted.value = true
                return .json(#"{"success":true}"#)
            case ("GET", "/api/recordings"):
                if failing.value { return .json(#"{"error":"busy"}"#, status: 500) }
                let body = deleted.value ? "[]" : #"[{"id":30,"title":"The Headlines","status":"completed"}]"#
                var response = LocalHTTPServer.Response.json(body)
                if !deleted.value { staleRequests.value += 1; response.delay = 0.8 } // fetched before the delete, answered after
                return response
            case ("GET", "/api/recordings/scheduled"):
                return .json("[]")
            default:
                return .notFound
            }
        }
        defer { http.stop() }
        let model = try model(http)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        model.recordings = [recording]
        func shown() -> Bool { !RecordingsHome.shelf(model.recordings, hidden: model.recordingStore.pendingRemovals).isEmpty }
        let stale = Task { await model.loadRecordings(quietly: true) }
        await waitUntil { staleRequests.value == 1 }
        let presenter = presenter()
        model.deleteWithUndo(recording, presenter: presenter)
        presenter.commitPendingUndo()
        await waitUntil { deleted.value && model.removalLog.all().isEmpty }
        await stale.value
        XCTAssertTrue(deleted.value)
        XCTAssertFalse(shown(), "the refresh fetched before the delete brought it back")
        XCTAssertFalse(model.recordings.contains { $0.id == 30 }, "nor is it in the list it loaded")

        // A failed refresh after it: still gone.
        failing.value = true
        model.recordings = [recording] // as a list loaded before the delete would still hold it
        await model.loadRecordings()
        XCTAssertNotNil(model.recordingsError)
        XCTAssertFalse(shown(), "a failed refresh showed it again")

        // A refresh that began after the delete and loaded: settled.
        failing.value = false
        await model.loadRecordings()
        XCTAssertTrue(model.recordingStore.pendingRemovals.isEmpty)
        XCTAssertFalse(shown())
    }
}
