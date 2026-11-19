import XCTest
@testable import PigTV

// Codex review of #347 (medium): with a Test's day two set to record, the card's record page bound day two and hid
// the airing picker (Change recording), so day one could not be recorded from the card. The picker now stays, and the
// page is Change recording or Record by the chosen airing. (No forAiring/airingSchedules: fails to compile on the
// commit before.)
@MainActor
final class AiringChoiceTests: XCTestCase {
    func testDayOneCanBeRecordedWhileDayTwoIsKept() async throws {
        let now = Date()
        let t0 = Int64((now.timeIntervalSince1970 + 3600) * 1000), hour: Int64 = 3_600_000, day: Int64 = 86_400_000
        func slot(_ start: Int64) -> String { #"{"sourceId":1,"id":"fox","name":"Fox Cricket","start":\#(start),"end":\#(start + 7 * hour)}"# }
        let row = { (id: Int, start: Int64) in
            #"{"id":\#(id),"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7 * hour),"status":"scheduled","gameId":"espn:cricket/1:9"}"#
        }
        let posted = Locked(false)
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"):
                posted.value = true
                return .json(row(32, t0))
            case ("GET", "/api/recordings/scheduled"):
                return .json(posted.value ? "[\(row(31, t0 + day)),\(row(32, t0))]" : "[\(row(31, t0 + day))]")
            case ("GET", "/api/recordings"):
                return .json("[]")
            default:
                return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(row(31, t0 + day).utf8))]
        let game = try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"espn:cricket/1:9","league":"Cricket","title":"Australia v India","start":\#(t0),"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed","channels":[\#(slot(t0))],"events":[],
         "canWatch":false,"competitors":[],"slots":[\#(slot(t0)),\#(slot(t0 + day))]}
        """#.utf8))
        let opened = try XCTUnwrap(browse.recordRequest(event: try XCTUnwrap(SportFrontText.event(game)), game: game, now: now))
        XCTAssertEqual(RecordPlan.openingAiring(opened), 1, "opens on day two, set to record")
        let dayTwo = RecordPlan.forAiring(opened, 1), dayOne = RecordPlan.forAiring(opened, 0)
        XCTAssertEqual(dayTwo.schedule?.id, 31, "day two: Change recording")
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: dayTwo), "Save changes")
        XCTAssertNil(dayOne.schedule, "day one chosen: Record")
        XCTAssertFalse(RecordPlan.whats(dayOne).isEmpty, "with its choices")
        XCTAssertNotEqual(RecordPlan.primaryTitle(.this, request: dayOne), "Save changes")
        // Record day one: a new schedule, day two's kept.
        let airing = dayOne.airings[0]
        let made = await browse.schedule(channel: airing.channel, programme: airing.programme, before: nil, after: nil,
                                         gameId: dayOne.gameId)
        XCTAssertTrue(made, browse.actionError ?? "")
        XCTAssertEqual(Set(browse.schedules.map(\.id)), [31, 32])
    }
}
