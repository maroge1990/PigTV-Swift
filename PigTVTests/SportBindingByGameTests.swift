import XCTest
@testable import PigTV

// Codex review of #347 (high): game A's schedule in a channel slot the guide has since given to game B. B's sport
// request bound A's schedule by channel and start (before it set its game), so B's Change recording or Cancel changed
// A's recording; the save and cancel recheck repeated the same lookup. Rows naming another game are never bound now.
@MainActor
final class SportBindingByGameTests: XCTestCase {
    func testARowNamingAnotherGameIsNeverBound() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), end = start + 7_200_000
        func row(_ id: Int, game: String?) throws -> ScheduledRecording {
            let named = game.map { #","gameId":"\#($0)""# } ?? ""
            return try JSONDecoder().decode(ScheduledRecording.self, from: Data(
                #"{"id":\#(id),"title":"x","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(end),"status":"scheduled"\#(named)}"#.utf8))
        }
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: Double(start), endTime: Double(end))
        let event = SportEvent(id: "e", title: "B v C", league: "AFL", startTime: Double(start), endTime: Double(end), channels: [channel])
        browse.schedules = [try row(1, game: "espn:afl:A")]
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:B"))
        XCTAssertNil(request.schedule, "game A's schedule is not game B's Change recording")
        XCTAssertFalse(browse.stillBinds(try row(1, game: "espn:afl:A"), request), "nor at save or cancel")
        // A row naming this game binds; one naming none binds by the guarded slot rule, as before.
        browse.schedules = [try row(2, game: "espn:afl:B")]
        XCTAssertEqual(browse.recordRequest(event: event, card: "espn:afl:B")?.schedule?.id, 2)
        browse.schedules = [try row(3, game: nil)]
        XCTAssertEqual(browse.recordRequest(event: event, card: "espn:afl:B")?.schedule?.id, 3)
        browse.schedules = [try row(1, game: "espn:afl:A"), try row(2, game: "espn:afl:B")]
        XCTAssertEqual(browse.recordRequest(event: event, card: "espn:afl:B")?.schedule?.id, 2, "this game's, not the first")
    }
}
