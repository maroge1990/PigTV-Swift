import XCTest
@testable import PigTV

// #357 (Codex review of 359-360, medium): a 409 "cancelling" was kept only by the schedule id it named, and the page
// finds a cancellation by scanning the rows on show. A schedule made and cancelled on another device after the press
// read is not among them, so Record stayed offered until a reconcile read landed, and a poll asked for before the
// refusal could publish a list without it. The refusal is now tied to the airing tried: it waits until an accepted read
// asked for after the refusal shows that schedule not "cancelling", or gone.
@MainActor
final class RefusedAiringWaitsTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    func testARefusalForAScheduleNotOnShowWaitsUntilALaterReadSettlesIt() async throws {
        let reads = Locked(0), failing = Locked(true), posted = Locked(false)
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                switch reads.value {
                case 1: return .json("[]") // the press read: nothing being cancelled
                case 2: // a poll asked for while the POST is in flight, answered after the refusal
                    var late = LocalHTTPServer.Response.json("[]")
                    late.delay = 2
                    return late
                default: return failing.value ? .json(#"{"error":"down"}"#, status: 500) : .json("[]")
                }
            case ("POST", "/api/recordings/schedule"):
                posted.value = true
                // Schedule 9 was made and is being cancelled on another device since the press read.
                var refused = LocalHTTPServer.Response.json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":9}"#, status: 409)
                refused.delay = 0.5
                return refused
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        defer { browse.retirePrivateCaches() }
        browse.reconcileRetry = .milliseconds(50)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        let airing = request.airings[0]

        let press = Task { await browse.record(request, airing: airing, before: nil, after: nil) }
        for _ in 0..<500 where !posted.value { try await Task.sleep(for: .milliseconds(10)) }
        let poll = Task { await browse.readSchedulesNow() } // asked for before the refusal
        let made = await press.value
        XCTAssertFalse(made)
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airing), "Cancelling… at once, with no row on show")

        let polled = await poll.value
        XCTAssertTrue(polled, "the older poll is published")
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airing), "a list asked for before the refusal settles nothing")
        try await Task.sleep(for: .milliseconds(300)) // its own reads fail meanwhile
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airing), "nor does a failed read")

        failing.value = false // the scheduled list answers: schedule 9 is gone
        for _ in 0..<500 where browse.cancellingEarlier(request, airing: airing) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(browse.cancellingEarlier(request, airing: airing), "Record is back")
    }
}
