import XCTest
@testable import PigTV

// #347 finding 1 (Codex sign-off, high): the press-time read authorized Record whenever it answered, even when its answer
// lost the ticket check to a poll published first and was discarded. Record then checked the poll's list, which can
// predate a cancellation the discarded read showed, and the POST went ahead. Now only a published press-time read
// authorizes the write: a superseded one is read once more, and a second superseded read sends nothing.
@MainActor
final class RecordPressSupersededReadTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
    private var cancellingRow: String {
        #"{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"cancelling","gameId":"espn:afl:B"}"#
    }

    private func page(_ handler: @escaping LocalHTTPServer.Handler) throws -> (BrowseModel, RecordRequest, LocalHTTPServer) {
        let http = try LocalHTTPServer(handler: handler)
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        return (browse, try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B")), http)
    }

    /// Until the server has had `count` scheduled-list reads (polled; CI's 2 vCPUs need room).
    private func waitForReads(_ http: LocalHTTPServer, _ count: Int) async throws {
        for _ in 0..<500 where http.requests(path: "/api/recordings/scheduled").count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(http.requests(path: "/api/recordings/scheduled").count, count)
    }

    /// `slow`: the reads (1-based) answered late, with the row being cancelled; every other read answers at once with the
    /// empty list a poll had from before the cancellation started.
    private func server(slow: Set<Int>, posted: Locked<Bool>) throws -> (BrowseModel, RecordRequest, LocalHTTPServer) {
        let reads = Locked(0), row = cancellingRow
        return try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                guard slow.contains(reads.value) else { return .json("[]") }
                var late = LocalHTTPServer.Response.json("[\(row)]")
                late.delay = 1.5
                return late
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json(row, status: 201)
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
    }

    func testADiscardedPressReadShowingTheCancelIsReadAgainAndNothingIsSent() async throws {
        let posted = Locked(false)
        // Read 1 (the press) shows the cancel but answers late; read 2 (a poll) answers first with the older empty list;
        // read 3 (the press's second read) is the server's state now.
        let (browse, request, http) = try server(slow: [1, 3], posted: posted)
        defer { http.stop() }
        let press = Task { await browse.record(request, airing: request.airings[0], before: nil, after: nil) }
        try await waitForReads(http, 1)
        let polled = await browse.readSchedulesNow()
        XCTAssertTrue(polled, "the poll answers first and is published")
        let made = await press.value
        XCTAssertFalse(made)
        XCTAssertFalse(posted.value, "nothing sent")
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertEqual(http.requests(path: "/api/recordings/scheduled").count, 3, "the press read once more")
    }

    func testTwoSupersededPressReadsFailClosed() async throws {
        let posted = Locked(false)
        // Both press reads (1 and 3) are overtaken by polls (2 and 4).
        let (browse, request, http) = try server(slow: [1, 3], posted: posted)
        defer { http.stop() }
        let press = Task { await browse.record(request, airing: request.airings[0], before: nil, after: nil) }
        try await waitForReads(http, 1)
        let first = await browse.readSchedulesNow()
        try await waitForReads(http, 3)
        let second = await browse.readSchedulesNow()
        XCTAssertTrue(first && second)
        let made = await press.value
        XCTAssertFalse(made)
        XCTAssertFalse(posted.value, "nothing sent")
        XCTAssertEqual(browse.actionError, PageWords.scheduleCheckFailed)
    }
}
