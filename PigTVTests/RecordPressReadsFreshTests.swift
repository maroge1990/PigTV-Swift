import XCTest
@testable import PigTV

// Codex sign-off of #347 (high): the press checked the same cached list the button drew from. Another device starting a
// cancellation after the last poll passed both checks and the POST made a replacement while the original was still
// stopping. Record now reads the scheduled list at the press, and goes on only with a successful answer; a server that
// still finds the airing being cancelled answers 409 "cancelling", and the page shows Cancelling… and stays open.
// (No BrowseModel.record: fails to compile on the commit before.)
@MainActor
final class RecordPressReadsFreshTests: XCTestCase {
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

    func testARemoteCancellationSinceTheLastPollIsSeenBeforeAnythingIsSent() async throws {
        let posted = Locked(false), row = cancellingRow
        let (browse, request, http) = try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json("[\(row)]") // another device is cancelling it now
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json(row, status: 201)
            default: return .notFound
            }
        }
        defer { http.stop() }
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "the cached list does not know yet")
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made)
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertFalse(posted.value, "nothing sent")
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "the page shows Cancelling…")
    }

    func testNoAnswerToTheReadMeansNothingIsSent() async throws {
        let posted = Locked(false)
        let (browse, request, http) = try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json(#"{"error":"down"}"#, status: 500)
            case ("POST", "/api/recordings/schedule"): posted.value = true; return .json("{}", status: 201)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made)
        XCTAssertEqual(browse.actionError, PageWords.scheduleCheckFailed)
        XCTAssertFalse(posted.value)
    }

    func testTheServersCancellingRefusalShowsCancellingAndKeepsThePage() async throws {
        let refused = Locked(false), row = cancellingRow
        let (browse, request, http) = try page { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"): return .json(refused.value ? "[\(row)]" : "[]")
            case ("POST", "/api/recordings/schedule"):
                refused.value = true
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":5}"#, status: 409)
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        let made = await browse.record(request, airing: request.airings[0], before: nil, after: nil)
        XCTAssertFalse(made, "the page stays open")
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "Cancelling… for that airing")
    }
}
