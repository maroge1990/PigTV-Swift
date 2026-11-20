import XCTest
@testable import PigTV

// #357 (Codex sign-off of 359-364, high): Record awaits its press-time scheduled-list read. Signing out (or switching
// server or account) while that read was out left the task holding the old model, and it sent the POST on the old
// session's token when the read returned. A retired model now sends nothing after its reads, and a late 409 on it
// starts no reconciling reads.
@MainActor
final class RecordAfterRetirementTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    private func page(_ handler: @escaping LocalHTTPServer.Handler) throws -> (BrowseModel, RecordRequest, LocalHTTPServer) {
        let http = try LocalHTTPServer(handler: handler)
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        browse.reconcileRetry = .milliseconds(50)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        return (browse, try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B")), http)
    }

    func testSigningOutDuringThePressReadSendsNoPost() async throws {
        let posted = Locked(false)
        let (browse, request, http) = try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                var held = LocalHTTPServer.Response.json("[]")
                held.delay = 1.5 // the press-time read is out
                return held
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json("{}", status: 201)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let press = Task { await browse.record(request, airing: request.airings[0], before: nil, after: nil) }
        for _ in 0..<500 where http.requests(path: "/api/recordings/scheduled").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        browse.retirePrivateCaches() // signed out while it is held
        let made = await press.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(made)
        XCTAssertFalse(posted.value, "nothing sent on the old session")
        XCTAssertNil(browse.actionError, "nothing said: the session has gone")
    }

    func testARefusalAnsweredAfterSignOutStartsNoReads() async throws {
        let posted = Locked(false)
        let (browse, request, http) = try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json("[]")
            case ("POST", "/api/recordings/schedule"):
                posted.value = true
                var refused = LocalHTTPServer.Response.json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":9}"#, status: 409)
                refused.delay = 1
                return refused
            default: return .notFound
            }
        }
        defer { http.stop() }
        let press = Task { await browse.record(request, airing: request.airings[0], before: nil, after: nil) }
        for _ in 0..<500 where !posted.value { try await Task.sleep(for: .milliseconds(10)) }
        browse.retirePrivateCaches() // signed out while the POST is out
        let reads = http.requests(path: "/api/recordings/scheduled").count
        _ = await press.value
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(http.requests(path: "/api/recordings/scheduled").count, reads, "no reads on the old session")
    }
}
