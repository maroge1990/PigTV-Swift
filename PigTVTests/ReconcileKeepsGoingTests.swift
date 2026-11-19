import XCTest
@testable import PigTV

// #357 (Codex review of 359-360, medium): a cancellation's own reads gave up after `reconcileTries` and left it in
// progress, and only a recordings load (which stops at a failed `/recordings`) or those reads could settle it: with the
// files list down, Record stayed disabled for the session. The reads now go on, less often, while it is unresolved, and
// any accepted scheduled-list read asked for after it was marked settles it.
@MainActor
final class ReconcileKeepsGoingTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    /// A record page whose Record is refused 409 "cancelling" for schedule 5; `status(n)` is the row's status in the
    /// n-th scheduled-list read after the refusal. The files list is down throughout.
    private func refused(_ status: @escaping @Sendable (Int) -> String) async throws -> (BrowseModel, RecordRequest, LocalHTTPServer) {
        let refusedAt = Locked<Int?>(nil), reads = Locked(0), start = start
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                let state = refusedAt.value.map { status(reads.value - $0) } ?? "scheduled"
                return .json(#"[{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"\#(state)","gameId":"espn:afl:B"}]"#)
            case ("POST", "/api/recordings/schedule"):
                refusedAt.value = reads.value
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":5}"#, status: 409)
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500)
            default: return .notFound
            }
        }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        return (browse, try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B")), http)
    }

    func testTheReadsOutlastTheirFirstRoundAndSettleItWhenTheServerHasFinished() async throws {
        // Still cancelling for 30 reads (more than the first round of 24), then the cancel failed: the row stands.
        let (browse, request, http) = try await refused { $0 <= 30 ? "cancelling" : "scheduled" }
        defer { http.stop(); browse.retirePrivateCaches() }
        browse.reconcileRetry = .milliseconds(10)
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "Cancelling…")
        for _ in 0..<1000 where browse.cancellingEarlier(request, airing: request.airings[0]) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "Record is back")
        XCTAssertTrue(browse.recordingStore.uncertainRemovals.isEmpty)
    }

    func testAnyAcceptedReadAskedAfterTheRefusalSettlesIt() async throws {
        // The refusal's own first read still finds it cancelling; every later read finds the cancel ended.
        let (browse, request, http) = try await refused { $0 <= 1 ? "cancelling" : "scheduled" }
        defer { http.stop(); browse.retirePrivateCaches() }
        browse.reconcileRetry = .seconds(30) // its own next read is far off
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made)
        for _ in 0..<500 where http.requests(path: "/api/recordings/scheduled").count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "still cancelling")
        // The open record page's poll.
        let polled = await browse.readSchedulesNow()
        XCTAssertTrue(polled)
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "the poll settled it")
    }
}
