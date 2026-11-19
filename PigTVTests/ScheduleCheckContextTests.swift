import XCTest
@testable import PigTV

// Codex sign-off of #347 (medium): the page resolved a cancelling schedule against the card's slots, but schedule()
// repeated the check without them, fell back to the stored (rolled) end, and refused an airing the page offered. The
// write now takes the request and airing and uses the page's rule. (No `context`: fails to compile on the commit before.)
@MainActor
final class ScheduleCheckContextTests: XCTestCase {
    func testTheWriteUsesThePagesRuleForTheAiring() async throws {
        let now = Date()
        let t0 = Int64((now.timeIntervalSince1970 + 3600) * 1000), hour: Int64 = 3_600_000, day: Int64 = 86_400_000
        func slot(_ id: String, _ start: Int64, guideEnd: Int64? = nil, end: Int64) -> String {
            #"{"sourceId":1,"id":"\#(id)","name":"\#(id.uppercased())","start":\#(start),"end":\#(end)\#(guideEnd.map { #","guideEnd":\#($0)"# } ?? "")}"#
        }
        // Day one on B overran (rolled on to day two's start), day two on A.
        let game = try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"espn:cricket/1:9","league":"Cricket","title":"Australia v India","start":\#(t0),"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed","channels":[\#(slot("b", t0, guideEnd: t0 + 7 * hour, end: t0 + day + hour))],
         "events":[],"canWatch":false,"competitors":[],
         "slots":[\#(slot("b", t0, guideEnd: t0 + 7 * hour, end: t0 + day + hour)),\#(slot("a", t0 + day, end: t0 + day + 7 * hour))]}
        """#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        // Day one's schedule (made while it overran: the rolled end, no original) is being cancelled; B is not in the guide.
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":5,"title":"Australia v India","channel_name":"B","source_id":1,"channel_item_id":"b","program_start":\#(t0),"program_end":\#(t0 + day + hour),"status":"cancelling","gameId":"espn:cricket/1:9"}"#.utf8))]
        let request = try XCTUnwrap(browse.recordRequest(event: try XCTUnwrap(SportFrontText.event(game)), game: game, now: now))
        let dayTwo = try XCTUnwrap(request.airings.first { $0.channel.rawID == "a" })
        XCTAssertFalse(browse.cancellingEarlier(request, airing: dayTwo), "the page offers day two")
        _ = await browse.schedule(channel: dayTwo.channel, programme: dayTwo.programme, guideEnd: dayTwo.guideEnd,
                                  before: nil, after: nil, gameId: request.gameId, context: (request, dayTwo))
        XCTAssertNotEqual(browse.actionError, PageWords.cancellingEarlierText, "the write does not veto it (it is sent)")
        // Without the context (the old check) it was refused.
        _ = await browse.schedule(channel: dayTwo.channel, programme: dayTwo.programme, guideEnd: dayTwo.guideEnd,
                                  before: nil, after: nil, gameId: request.gameId)
        XCTAssertEqual(browse.actionError, PageWords.cancellingEarlierText)
    }
}
