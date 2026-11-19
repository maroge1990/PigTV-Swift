import XCTest
@testable import PigTV

// #357 (Codex review of 359-360, medium): the Sport hold menu's quick Record called `schedule()` directly, so it checked
// only the cached list: with the scheduled list down it still sent the POST, and a cancellation started since the last
// poll was not seen. It now goes through the record page's press (`BrowseModel.record`): read at the press, a superseded
// read once more, nothing sent without a usable answer.
@MainActor
final class QuickRecordPressReadTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
    private var cancellingRow: String {
        #"{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"cancelling","gameId":"espn:afl:B"}"#
    }

    /// The app the flow is attached to (weakly): kept for the test's length.
    private var heldApp: AppModel?

    private func makeFlow(_ handler: @escaping LocalHTTPServer.Handler) throws -> (SportRecordFlow, BrowseModel, SportEvent, LocalHTTPServer) {
        let http = try LocalHTTPServer(handler: handler)
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let app = AppModel()
        app.configureClientForTesting(browse.client, browse: browse)
        let flow = SportRecordFlow()
        flow.attach(app)
        heldApp = app
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        return (flow, browse, event, http)
    }

    /// Until `done` or 5 s (CI's 2 vCPUs need room).
    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testQuickRecordDuringAScheduledListOutageSendsNothing() async throws {
        let posted = Locked(false)
        let (flow, browse, event, http) = try makeFlow { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json(#"{"error":"down"}"#, status: 500)
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json("{}", status: 201)
            default: return .notFound
            }
        }
        defer { http.stop() }
        flow.run(.recordThis(game: true), event: event, game: nil, card: "espn:afl:B")
        try await waitUntil { browse.actionError != nil || posted.value }
        XCTAssertFalse(posted.value, "nothing sent")
        XCTAssertEqual(browse.actionError, PageWords.scheduleCheckFailed)
    }

    func testQuickRecordReadsAgainWhenItsPressReadIsSuperseded() async throws {
        let posted = Locked(false), reads = Locked(0), row = cancellingRow
        // Read 1 (the press) shows the cancel but answers late; read 2 (a poll) answers first with the older empty list;
        // read 3 (the press's second read) is the server's state now.
        let (flow, browse, event, http) = try makeFlow { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                guard reads.value != 2 else { return .json("[]") }
                var late = LocalHTTPServer.Response.json("[\(row)]")
                late.delay = 1.5
                return late
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json(row, status: 201)
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        flow.run(.recordThis(game: true), event: event, game: nil, card: "espn:afl:B")
        try await waitUntil { reads.value >= 1 }
        let polled = await browse.readSchedulesNow()
        XCTAssertTrue(polled, "the poll answers first and is published")
        try await waitUntil { browse.actionError != nil || posted.value }
        XCTAssertFalse(posted.value, "nothing sent")
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
    }
}
