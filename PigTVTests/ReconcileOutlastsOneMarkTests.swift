import XCTest
@testable import PigTV

// #357 (Codex sign-off of 359-364, medium): a schedule can carry a Record refusal and a later cancel with no answer. An
// accepted read asked for between the two clears the refusal and keeps the cancel. The schedule's reads compared the
// pair of marks and ended when it changed, so the cancel was left with nothing to settle it, and with the files list
// down Record stayed disabled for the session. The reads now go on while either mark is set.
@MainActor
final class ReconcileOutlastsOneMarkTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    func testAReadBetweenARefusalAndALostCancelClearsOnlyTheRefusalAndTheReadsGoOn() async throws {
        let start = start
        let row = #"[{"id":5,"title":"B v C","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"scheduled","gameId":"espn:afl:B"}]"#
        let reads = Locked(0), failing = Locked(true), pollArmed = Locked(false)
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                if reads.value == 1 { return .json(row) } // the press read
                if pollArmed.value { // the record page's poll: asked for after the refusal, answered after the lost cancel
                    pollArmed.value = false
                    var late = LocalHTTPServer.Response.json(row)
                    late.delay = 1.5
                    return late
                }
                return failing.value ? .json(#"{"error":"down"}"#, status: 500) : .json(row)
            case ("POST", "/api/recordings/schedule"):
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":5}"#, status: 409)
            case ("DELETE", "/api/recordings/scheduled/5"):
                var dropped = LocalHTTPServer.Response.json(""); dropped.drop = true; return dropped
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        defer { browse.retirePrivateCaches() }
        let presenter = AppPresenter()
        browse.presenter = presenter
        browse.reconcileRetry = .seconds(30) // the refusal's own reads: one at once, the next far off
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(start + 7_200_000))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(start + 7_200_000), channels: [channel])
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        let airing = request.airings[0]
        let key = PendingRemoval.key(.cancelSchedule, 5)
        func scheduledReads() -> Int { http.requests(path: "/api/recordings/scheduled").count }

        // 1. Record is refused: the refusal mark. Its own first read fails.
        let made = await browse.record(request, airing: airing, before: nil, after: nil)
        XCTAssertFalse(made)
        XCTAssertNotNil(browse.recordingStore.refusedAirings[key])
        for _ in 0..<500 where scheduledReads() < 2 { try await Task.sleep(for: .milliseconds(10)) }

        // 2. The page's poll is asked for after the refusal (its answer is held).
        pollArmed.value = true
        let poll = Task { await browse.readSchedulesNow() }
        for _ in 0..<500 where pollArmed.value { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(pollArmed.value, "the poll has been asked for")

        // 3. Then the schedule's cancel is sent and gets no answer: the lost-cancel mark, set after the poll was asked.
        browse.reconcileRetry = .milliseconds(100)
        let item = try XCTUnwrap(browse.schedules.first { $0.id == 5 })
        browse.cancelWithUndo(item, presenter: presenter)
        presenter.commitPendingUndo()
        for _ in 0..<500 where browse.recordingStore.uncertainRemovals[key] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(browse.recordingStore.uncertainRemovals[key], "no answer to the cancel")

        // 4. The poll answers: it settles the refusal, asked for before it, and not the cancel, asked for after it.
        let polled = await poll.value
        XCTAssertTrue(polled)
        XCTAssertNil(browse.recordingStore.refusedAirings[key], "the refusal is settled")
        XCTAssertNotNil(browse.recordingStore.uncertainRemovals[key], "the cancel is not")
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airing), "Record still waits")

        // 5. The schedule's reads go on (they fail meanwhile), and Record stays blocked.
        let before = scheduledReads()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(scheduledReads(), before, "its reads go on while the cancel is unsettled")
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airing), "a failed read settles nothing")

        // 6. The list answers: a read asked for after the cancel settles it, and Record is back.
        failing.value = false
        for _ in 0..<500 where browse.cancellingEarlier(request, airing: airing) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(browse.recordingStore.uncertainRemovals[key], "the cancel is settled")
        XCTAssertFalse(browse.cancellingEarlier(request, airing: airing), "Record is back")
    }
}
