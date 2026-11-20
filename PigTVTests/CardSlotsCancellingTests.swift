import XCTest
@testable import PigTV

// C-R since #353 (server 0862+, additive; production's 0861 sends none of these): a card's `slots` (each later airing of
// its channels, a Test's day two), `recordingCancelling` (the game's schedules being cancelled, with their guide slots)
// and a channel's `guideEnd` (an overrunning airing's own guide end). Before, the client read none of them: Record
// offered only day one, Cancelling… was the client's inference for the whole request, and schedules matched airings by
// the rolled end. (No `slots`, `recordingCancelling`, `guideEndTime`: these fail to compile on the commit before.)
@MainActor
final class CardSlotsCancellingTests: XCTestCase {
    private let now = Date()
    private var t0: Int64 { Int64((now.timeIntervalSince1970 + 3600) * 1000) }
    private let hour: Int64 = 3_600_000, day: Int64 = 86_400_000

    private func channel(_ start: Int64, _ end: Int64, guideEnd: Int64? = nil) -> String {
        #"{"sourceId":1,"id":"fox","name":"Fox Cricket","start":\#(start),"end":\#(end)\#(guideEnd.map { #","guideEnd":\#($0)"# } ?? "")}"#
    }

    private func game(extra: String) throws -> SportsGame {
        try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"espn:cricket/1:9","league":"Cricket","title":"Australia v India","start":\#(t0),"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed","channels":[\#(channel(t0, t0 + 7 * hour))],"events":[],
         "canWatch":false,"competitors":[]\#(extra)}
        """#.utf8))
    }

    private func browse() throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1), accountID: 1)
    }

    private func request(_ browse: BrowseModel, _ game: SportsGame) throws -> RecordRequest {
        let event = try XCTUnwrap(SportFrontText.event(game))
        return try XCTUnwrap(browse.recordRequest(event: event, game: game, now: now))
    }

    func testTheFieldsAreAdditiveAndLenient() throws {
        let plain = try game(extra: "")
        XCTAssertNil(plain.slots)
        XCTAssertNil(plain.recordingCancelling)
        XCTAssertEqual(plain.recordSlots.count, 1, "an older server: Record offers its channels")
        let odd = try game(extra: #","slots":"two","recordingCancelling":{"x":1}"#)
        XCTAssertNil(odd.slots?.value, "malformed: absent, the card stays")
        XCTAssertNil(odd.recordingCancelling?.value)
        let ch = try JSONDecoder().decode(SportEventChannel.self, from: Data(channel(t0, t0 + 9 * hour, guideEnd: t0 + 7 * hour).utf8))
        XCTAssertEqual(ch.guideEndTime, Double(t0 + 7 * hour))
    }

    /// `slots`: Record offers a Test's day two on day one's channel, each airing its own choice with its day.
    func testRecordOffersEachSlotWithItsDay() throws {
        let test = try game(extra: #","slots":[\#(channel(t0, t0 + 7 * hour)),\#(channel(t0 + day, t0 + day + 7 * hour))]"#)
        let browse = try browse()
        let request = try request(browse, test)
        XCTAssertEqual(request.airings.map(\.programme.startTime), [Double(t0), Double(t0 + day)], "both days")
        XCTAssertEqual(Set(request.airings.map(\.id)).count, 2, "each airing its own choice")
        let groups = RecordPlan.channelGroups(request)
        XCTAssertEqual(groups.count, 2, "a row per airing")
        XCTAssertTrue(RecordPlan.channelsTimed(request), "the days differ")
        let details = groups.map { group in
            RecordPlan.channelDetail(request.airings[group.best.copy], timed: true, now: now)
        }
        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details.allSatisfy { $0 != nil }, "each shows its day and time: \(details)")
        XCTAssertNotEqual(details[0], details[1])
        XCTAssertEqual(try self.request(try self.browse(), try game(extra: "")).airings.count, 1, "no slots: the channels")
    }

    /// A Test whose day two is the one scheduled: the record page opens on day two (the bound airing, by channel and guide
    /// start), as Change recording of it. Before, it opened on the channel's first airing (day one) while changing day two.
    /// (No preferredAiring or RecordPlan.openingAiring: fails to compile on the commit before.)
    func testTheRecordPageOpensOnTheBoundAiring() throws {
        let test = try game(extra: #","slots":[\#(channel(t0, t0 + 7 * hour)),\#(channel(t0 + day, t0 + day + 7 * hour))]"#)
        let browse = try browse()
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":31,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(t0 + day),"program_end":\#(t0 + day + 7 * hour),"status":"scheduled"}"#.utf8))]
        let request = try request(browse, test)
        XCTAssertEqual(request.schedule?.id, 31, "Change recording of day two")
        let opening = RecordPlan.openingAiring(request)
        XCTAssertEqual(request.airings[opening].programme.startTime, Double(t0 + day), "the page opens on day two")
        // Nothing scheduled: the best airing, as before.
        browse.schedules = []
        XCTAssertEqual(RecordPlan.openingAiring(try self.request(browse, test)), 0)
    }

    /// `recordingCancelling`: the airing that overlaps an entry waits (Cancelling…); day two stays recordable. With the
    /// field present it is preferred over the client's inference; without it (0861) the inference stays.
    func testTheCardsCancellingListDecidesPerAiring() throws {
        let slots = #","slots":[\#(channel(t0, t0 + 7 * hour)),\#(channel(t0 + day, t0 + day + 7 * hour))]"#
        let test = try game(extra: slots + #","recordingCancelling":[{"scheduleId":5,"start":\#(t0),"end":\#(t0 + 7 * hour)}]"#)
        let browse = try browse()
        let request = try request(browse, test)
        XCTAssertEqual(request.serverCancelling?.count, 1)
        XCTAssertTrue(browse.cancellingEarlier(request, airing: request.airings[0]), "day one: Cancelling…")
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[1]), "day two: Record")

        // Older server (no field): the client's own list says day one's schedule is cancelling.
        let old = try game(extra: slots)
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":5,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(t0),"program_end":\#(t0 + 7 * hour),"status":"cancelling","gameId":"espn:cricket/1:9"}"#.utf8))]
        let fallback = try self.request(browse, old)
        XCTAssertNil(fallback.serverCancelling)
        XCTAssertTrue(browse.cancellingEarlier(fallback, airing: fallback.airings[0]), "inferred, as before")
        XCTAssertFalse(browse.cancellingEarlier(fallback, airing: fallback.airings[1]))

        // The card says only day two is being cancelled: its list is preferred over a stale client row for day one.
        let fresh = try game(extra: slots + #","recordingCancelling":[{"scheduleId":6,"start":\#(t0 + day),"end":\#(t0 + day + 7 * hour)}]"#)
        let preferred = try self.request(browse, fresh)
        XCTAssertFalse(browse.cancellingEarlier(preferred, airing: preferred.airings[0]), "the server's list, not the stale row")
        XCTAssertTrue(browse.cancellingEarlier(preferred, airing: preferred.airings[1]))
    }

    /// `guideEnd`: an overrunning airing's `end` is rolled on for Watch; schedules match it by guide bounds, so the next
    /// programme's schedule on that channel, being cancelled, is not this game's (Record stays).
    func testSchedulesMatchAiringsByGuideBoundsNotTheRolledEnd() throws {
        let overrun = try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"espn:cricket/1:9","league":"Cricket","title":"Australia v India","start":\#(t0),"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed",
         "channels":[\#(channel(t0, t0 + 9 * hour, guideEnd: t0 + 7 * hour))],"events":[],"canWatch":false,"competitors":[]}
        """#.utf8))
        let browse = try browse()
        browse.schedules = [try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":8,"title":"Cricket Highlights","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(t0 + 7 * hour),"program_end":\#(t0 + 8 * hour),"status":"cancelling"}"#.utf8))]
        let request = try request(browse, overrun)
        XCTAssertEqual(request.airings[0].programme.endTime, Double(t0 + 9 * hour), "Record still sends the rolled end")
        XCTAssertEqual(request.airings[0].guideBounds.end, Double(t0 + 7 * hour))
        XCTAssertFalse(browse.cancellingEarlier(request, airing: request.airings[0]),
                       "the programme after the game is not the game's")
        // A schedule made while it overran stores the rolled end; its guide end is the original.
        let rolled = try JSONDecoder().decode(ScheduledRecording.self, from: Data(
            #"{"id":9,"title":"x","program_start":1,"program_end":10,"program_end_original":7,"status":"scheduled"}"#.utf8))
        XCTAssertEqual(rolled.guideEnd, 7)
    }
}
