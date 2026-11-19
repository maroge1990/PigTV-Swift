import XCTest
@testable import PigTV

// #347 finding 2 (Codex sign-off, medium): a 409 "cancelling" dropped its scheduleId and relied on a recordings reload to
// show Cancelling…, but that reload stops at a failed `/recordings` before it reads the scheduled list, so Record stayed
// offered. Now the refused schedule is in progress at once, and its own scheduled-list reads go on until one shows the
// cancellation has ended.
@MainActor
final class CancellingRefusalWithoutFilesTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    private func row(_ status: String) -> String {
        #"{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"\#(status)","gameId":"espn:afl:B"}"#
    }

    func testARefusalShowsCancellingAtOnceAndItsOwnReadsClearIt() async throws {
        let refused = Locked(false), cleared = Locked(false)
        let scheduled = row("scheduled"), cancelling = row("cancelling")
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                if cleared.value { return .json("[]") } // the cancellation has ended
                return .json(refused.value ? "[\(cancelling)]" : "[\(scheduled)]")
            case ("POST", "/api/recordings/schedule"):
                refused.value = true // another device started cancelling it after the press read
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":5}"#, status: 409)
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500) // the files list fails
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
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertNotNil(browse.recordingsError, "the reload failed at the files list")
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "Cancelling… at once")

        // The scheduled list is read directly, and while it lists the schedule "cancelling" Cancelling… stays.
        let readsAfterRefusal = http.requests(path: "/api/recordings/scheduled").count
        for _ in 0..<500 where http.requests(path: "/api/recordings/scheduled").count < readsAfterRefusal + 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(http.requests(path: "/api/recordings/scheduled").count, readsAfterRefusal + 2)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "still being cancelled")

        // A successful read that no longer lists it cancelling ends it.
        cleared.value = true
        for _ in 0..<500 where browse.cancellingEarlier(request, airing: request.airings[0]) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "Record is back")
        XCTAssertTrue(browse.recordingStore.uncertainRemovals.isEmpty, "its reads have ended")
    }
}
