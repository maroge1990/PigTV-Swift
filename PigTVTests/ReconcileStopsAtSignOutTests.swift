import XCTest
@testable import PigTV

// #357 (Codex review of 359-360, medium): the reads that settle a refused (or unanswered) cancellation ran in an
// untracked task that outlived sign-out and an account switch, so they went on asking the old server with the old token.
// They are now tracked per schedule and cancelled when the session is retired (`retirePrivateCaches`, which sign-out
// and every session replacement call).
@MainActor
final class ReconcileStopsAtSignOutTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    func testSigningOutDuringReconciliationSendsNoMoreReads() async throws {
        let refused = Locked(false)
        let row: @Sendable (String) -> String = { [start] status in
            #"{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"\#(status)","gameId":"espn:afl:B"}"#
        }
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json("[\(row(refused.value ? "cancelling" : "scheduled"))]")
            case ("POST", "/api/recordings/schedule"):
                refused.value = true
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":5}"#, status: 409)
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        browse.reconcileRetry = .milliseconds(50)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made)
        let reads = { http.requests(path: "/api/recordings/scheduled").count }
        let atRefusal = reads()
        for _ in 0..<500 where reads() < atRefusal + 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(reads(), atRefusal + 2, "reconciling")

        browse.retirePrivateCaches() // signed out
        try await Task.sleep(for: .milliseconds(300)) // a read already asked for may still land
        let afterSignOut = reads()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(reads(), afterSignOut, "no further reads on the old session")
    }
}
