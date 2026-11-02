import XCTest
@testable import PigTV

/// Codex batch 4 (high): the Guide's "Cancel recording" commits after its 10 s Undo. If another change (a schedule, a
/// rule) was still in flight then, `cancel` returned at once and no DELETE was sent, though the toast had said
/// "cancelled". The committed cancel waits for that change and then sends it.
@MainActor
final class RecordingCancelCommittedTests: XCTestCase {
    func testACommittedCancelWaitsForAChangeInFlightInsteadOfBeingDropped() async throws {
        let log = Locked<[String]>([])
        let http = try LocalHTTPServer { request in
            log.value.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("DELETE", "/api/recordings/scheduled/9"):
                return .json(#"{"id":9,"title":"News","program_start":1,"program_end":2,"status":"cancelled"}"#)
            case ("GET", "/api/recordings/scheduled"), ("GET", "/api/recordings"):
                return .json("[]")
            default:
                return .notFound
            }
        }
        defer { http.stop() }
        let model = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let schedule = try JSONDecoder().decode(ScheduledRecording.self,
            from: Data(#"{"id":9,"title":"News","program_start":1,"program_end":2,"status":"scheduled"}"#.utf8))
        model.mutationBusy = true // another change in flight when the Undo runs out
        let committed = Task { await model.cancelCommitted(schedule) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(log.value.contains("DELETE /api/recordings/scheduled/9"), "nothing is sent while the other change runs")
        model.mutationBusy = false
        await committed.value
        XCTAssertTrue(log.value.contains("DELETE /api/recordings/scheduled/9"), "the cancel is sent once it is free: \(log.value)")
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.mutationBusy)
    }
}
