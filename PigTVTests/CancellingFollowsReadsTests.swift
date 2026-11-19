import XCTest
@testable import PigTV

// Codex review of #347 (medium): the record page kept the card's `recordingCancelling` from when it opened. An entry
// went on blocking Record after a newer scheduled-list read showed the cancellation finished, and a cancellation
// started later on another airing (another device) was missed. Entries are now reconciled by schedule id against a
// scheduled list asked for after the request, and that list's own cancellations count. (No schedulesAskedAt: fails to
// compile on the commit before.)
@MainActor
final class CancellingFollowsReadsTests: XCTestCase {
    func testTheCardsCancellingListFollowsNewerReads() throws {
        let now = Date()
        let t0 = Int64((now.timeIntervalSince1970 + 3600) * 1000), hour: Int64 = 3_600_000, day: Int64 = 86_400_000
        func slot(_ start: Int64) -> String { #"{"sourceId":1,"id":"fox","name":"Fox Cricket","start":\#(start),"end":\#(start + 7 * hour)}"# }
        let game = try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"espn:cricket/1:9","league":"Cricket","title":"Australia v India","start":\#(t0),"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed","channels":[\#(slot(t0))],"events":[],
         "canWatch":false,"competitors":[],"slots":[\#(slot(t0)),\#(slot(t0 + day))],
         "recordingCancelling":[{"scheduleId":5,"start":\#(t0),"end":\#(t0 + 7 * hour)}]}
        """#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let request = try XCTUnwrap(browse.recordRequest(event: try XCTUnwrap(SportFrontText.event(game)), game: game, now: now))
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "day one: Cancelling… (the card's list)")
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[1]))

        // A scheduled list asked for after the page opened: schedule 5 is gone (its cancel finished).
        browse.schedules = []
        browse.recordingStore.schedulesAskedAt = request.builtAt.addingTimeInterval(1)
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]), "Record is back on day one")

        // That list shows another device cancelling day two's schedule: day two waits.
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":6,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(t0 + day),"program_end":\#(t0 + day + 7 * hour),"status":"cancelling","gameId":"espn:cricket/1:9"}"#.utf8))]
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[1]), "day two: Cancelling…")
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]))

        // An older read (before the page opened) does not overrule the card.
        browse.schedules = []
        browse.recordingStore.schedulesAskedAt = request.builtAt.addingTimeInterval(-60)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]))
    }
}
