import XCTest
@testable import PigTV

/// #12 (D-42, server 0410), maroge1990/PigTV#200: "Record this one instead" POSTs `recordings/scheduled/<id>/choose`
/// and reloads the schedules; a 404 (already started, or gone) says so; other failures use the app's message. A local
/// server stands in for PigTV (as RecordingClashTests). Before this change BrowseModel had no `choose`.
@MainActor
final class RecordingChooseTests: XCTestCase {
    private func server(choose status: Int, log: Locked<[String]>) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            log.value.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/scheduled/9/choose"):
                return status == 200 ? .json(#"{"id":9,"title":"Cricket","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[5]}"#)
                    : .json(#"{"error":"Schedule not found or already started"}"#, status: status)
            case ("GET", "/api/recordings/scheduled"):
                return .json(#"[{"id":9,"title":"Cricket","channel_name":"Fox Cricket","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[5]},{"id":5,"title":"Footy","channel_name":"Fox Footy","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[9],"beatenBy":[9]}]"#)
            case ("GET", "/api/recordings"):
                return .json("[]")
            default:
                return .notFound
            }
        }
    }

    private func model(_ http: LocalHTTPServer) throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
    }

    private var loser: ScheduledRecording {
        get throws { try JSONDecoder().decode(ScheduledRecording.self, from: Data(RecordingClashWinnerTests.loser.utf8)) }
    }

    func testChoosingPostsToTheScheduleAndReloads() async throws {
        let log = Locked<[String]>([])
        let http = try server(choose: 200, log: log)
        defer { http.stop() }
        let model = try model(http)
        await model.choose(try loser)
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.actionMessage, "no message: the reload shows it")
        XCTAssertEqual(log.value.first, "POST /api/recordings/scheduled/9/choose")
        XCTAssertTrue(log.value.contains("GET /api/recordings/scheduled"), "the schedules are reloaded: \(log.value)")
        XCTAssertEqual(model.schedules.first { $0.id == 5 }?.beatenBy, [9], "the reload shows the other one waiting")
        XCTAssertFalse(model.mutationBusy)
    }

    func testChoosingOneThatStartedSaysSoAndReloads() async throws {
        let log = Locked<[String]>([])
        let http = try server(choose: 404, log: log)
        defer { http.stop() }
        let model = try model(http)
        await model.choose(try loser)
        XCTAssertEqual(model.actionError, "That recording has already started or no longer exists.")
        XCTAssertTrue(log.value.contains("GET /api/recordings/scheduled"), "the schedules are reloaded: \(log.value)")
    }

    func testAnotherFailureUsesTheAppsMessage() async throws {
        let log = Locked<[String]>([])
        let http = try server(choose: 500, log: log)
        defer { http.stop() }
        let model = try model(http)
        await model.choose(try loser)
        XCTAssertEqual(model.actionError, UserMessage.text(for: PigTVError.http(500)))
    }
}
