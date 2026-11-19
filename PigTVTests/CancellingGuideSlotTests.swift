import XCTest
@testable import PigTV

// Codex review of #347 (medium): a recording first made while its game overran stores the rolled capture end as
// `program_end`, with no `program_end_original`. Cancelling it made the next programme on the channel wait
// ("Cancelling…") in the Guide and refused its Record, as the cancellation was matched by that stored end. It is now
// resolved to its own guide slot (channel identity and start) first; the stored end is only the fallback.
@MainActor
final class CancellingGuideSlotTests: XCTestCase {
    func testACancelledOverrunRecordingDoesNotBlockTheNextProgramme() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let t0 = Double(Int64((Date().timeIntervalSince1970 + 3600) * 1000)), hour = 3_600_000.0
        let game = GuideProgramme(title: "Australia v India", description: nil, startTime: t0, endTime: t0 + 7 * hour)
        let next = GuideProgramme(title: "Cricket Highlights", description: nil, startTime: t0 + 7 * hour, endTime: t0 + 8 * hour)
        let fox = GuideChannel(rawID: "fox", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil, programmes: [game, next])
        browse.guide = [fox]
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":5,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(Int64(t0)),"program_end":\#(Int64(t0 + 9 * hour)),"status":"cancelling"}"#.utf8))]
        XCTAssertEqual(browse.scheduleGuideEnd(browse.schedules[0]), t0 + 7 * hour, "its own guide slot, not the rolled end")
        XCTAssertFalse(browse.cancellingEarlier(gameId: nil, channel: fox, start: next.startTime, end: next.endTime),
                       "the next programme is recordable")
        XCTAssertEqual(browse.programmeRecordAction(channel: fox, programme: next, now: Date()), .record)
        XCTAssertTrue(browse.cancellingEarlier(gameId: nil, channel: fox, start: game.startTime, end: game.endTime),
                      "the game itself still waits")
        // No slot found (the guide does not list it): the stored end is the fallback.
        browse.guide = []
        XCTAssertEqual(browse.scheduleGuideEnd(browse.schedules[0]), t0 + 9 * hour)
    }
}
