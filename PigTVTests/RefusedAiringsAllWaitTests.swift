import XCTest
@testable import PigTV

// #357 (Codex sign-off of 359-364, medium): a second 409 "cancelling" for the same schedule replaced the first refusal's
// airing. A Sport attempt on one channel refused by its game, then a Guide attempt on another channel refused by its
// slot: with the scheduled list unreadable, the first channel's airing was offered again with nothing having settled
// the schedule. Every distinct refused airing now waits until a read asked for after its own refusal settles it.
@MainActor
final class RefusedAiringsAllWaitTests: XCTestCase {
    private let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)

    func testTwoRefusalsOnDifferentAiringsBothWaitUntilALaterReadSettlesThem() async throws {
        let reads = Locked(0), failing = Locked(true)
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/scheduled"):
                reads.value += 1
                if reads.value == 1 { return .json("[]") } // the press read: nothing being cancelled
                return failing.value ? .json(#"{"error":"down"}"#, status: 500) : .json("[]")
            case ("POST", "/api/recordings/schedule"):
                // Schedule 9, made and being cancelled on another device, refuses both attempts.
                return .json(#"{"error":"Still being cancelled","code":"cancelling","scheduleId":9}"#, status: 409)
            case ("GET", "/api/recordings"): return .json(#"{"error":"down"}"#, status: 500)
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        defer { browse.retirePrivateCaches() }
        browse.reconcileRetry = .milliseconds(50)
        let end = start + 7_200_000

        // 1. A Sport Record on channel A (Fox Footy), refused by the game.
        let channelA = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(end))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(end), channels: [channelA])
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        let airingA = request.airings[0]
        let sport = await browse.record(request, airing: airingA, before: nil, after: nil)
        XCTAssertFalse(sport)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airingA), "channel A waits")

        // 2. A Guide Record on channel B (Kayo), with no game: channel A's hold does not cover it, and the server refuses
        //    it by its slot, for the same schedule.
        let channelB = GuideChannel(rawID: "kayo", sourceId: 1, name: "Kayo", logo: nil, category: nil, programmes: [])
        let programmeB = GuideProgramme(title: "B v C", description: nil, startTime: Double(start), endTime: Double(end))
        XCTAssertFalse(browse.cancellingEarlier(browse.recordRequest(channel: channelB, programme: programmeB)),
                       "channel B is not held by channel A's refusal")
        let guide = await browse.schedule(channel: channelB, programme: programmeB, before: nil, after: nil)
        XCTAssertFalse(guide)
        XCTAssertEqual(http.requests(path: "/api/recordings/schedule").count, 2, "both attempts reached the server")

        // 3. With the scheduled list unreadable, both airings wait.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(browse.cancellingEarlier(request, airing: airingA), "channel A still waits after the second refusal")
        XCTAssertTrue(browse.cancellingEarlier(browse.recordRequest(channel: channelB, programme: programmeB)), "channel B waits")

        // 4. A read asked for after both refusals settles both.
        failing.value = false
        for _ in 0..<500 where browse.cancellingEarlier(request, airing: airingA)
            || browse.cancellingEarlier(browse.recordRequest(channel: channelB, programme: programmeB)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(browse.cancellingEarlier(request, airing: airingA), "Record is back on channel A")
        XCTAssertFalse(browse.cancellingEarlier(browse.recordRequest(channel: channelB, programme: programmeB)),
                       "and on channel B")
        XCTAssertTrue(browse.recordingStore.refusedAirings.isEmpty)
    }
}
