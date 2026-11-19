import XCTest
import Combine
@testable import PigTV

// Codex sign-off of #347 (medium): the card still listed a cancellation the cached list had already dropped. The page
// waits for a list read after it opened; an identical answer moved only an unpublished field, so the open page was not
// told and kept a disabled Cancelling… through later polls. While such a page is open every accepted read is published
// (and only then: a quiet refresh still publishes nothing, ObservationTests). (Fails to compile on 627b21b's parent.)
@MainActor
final class ScheduleReadRevisionTests: XCTestCase {
    func testAnIdenticalAcceptedReadStillTellsTheOpenPage() async throws {
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), hour: Int64 = 3_600_000
        let http = try LocalHTTPServer { request in
            request.path == "/api/recordings/scheduled" ? .json("[]") : .notFound
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        // The first read happens before the page opens.
        let first = await browse.readSchedulesNow()
        XCTAssertTrue(first)
        // A stale card: it still lists schedule 5 as being cancelled; the list has no such row.
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox", startTime: Double(start), endTime: Double(start + 7 * hour))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7 * hour), channels: [channel])
        var request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        request.serverCancelling = [.init(scheduleId: 5, start: Double(start), end: Double(start + 7 * hour))]
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "Cancelling… from the card")
        browse.recordingStore.readWaiters += 1 // the page is open (RecordPage.onAppear)
        var told = 0
        let watching = browse.recordingStore.objectWillChange.sink { told += 1 }
        defer { watching.cancel() }
        // The page's poll: the same (empty) list again.
        try await Task.sleep(for: .milliseconds(20))
        let second = await browse.readSchedulesNow()
        XCTAssertTrue(second)
        XCTAssertGreaterThan(told, 0, "the open page is told, though the rows did not change")
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "and Record is back")
    }
}
