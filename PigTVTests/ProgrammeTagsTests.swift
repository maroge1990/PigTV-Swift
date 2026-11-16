import XCTest
@testable import PigTV

// #56 (Apple half): the guide's programme fields (live, new, subtitle, episode, image) and what the badges and the
// episode line say.
final class ProgrammeTagsTests: XCTestCase {
    private func decode(_ json: String) throws -> GuideProgramme {
        try JSONDecoder().decode(GuideProgramme.self, from: Data(json.utf8))
    }

    func testAnOlderServersProgrammeDecodesWithNoTags() throws {
        let programme = try decode(#"{"title":"News","description":null,"startTime":1000,"endTime":2000}"#)
        XCTAssertEqual(programme.title, "News")
        XCTAssertNil(programme.liveBroadcast)
        XCTAssertNil(programme.isNew)
        XCTAssertNil(programme.subtitle)
        XCTAssertNil(programme.episode)
        XCTAssertNil(programme.image)
        XCTAssertTrue(ProgrammeTags(programme).isEmpty, "nothing is drawn for an older server's programme")
    }

    func testTheNewFieldsDecode() throws {
        let programme = try decode(#"""
        {"title":"Bluey","startTime":1000,"endTime":2000,"live":false,"new":true,"subtitle":"Sleepytime",
         "episode":"S2 E5","image":"/api/logo/abc"}
        """#)
        XCTAssertEqual(programme.isNew, true)
        XCTAssertEqual(programme.liveBroadcast, false)
        XCTAssertEqual(programme.subtitle, "Sleepytime")
        XCTAssertEqual(programme.episode, "S2 E5")
        XCTAssertEqual(programme.image, "/api/logo/abc")
        let tags = ProgrammeTags(programme)
        XCTAssertEqual(tags.badges, [.new])
        XCTAssertEqual(tags.episodeLine(title: programme.title), "S2 E5 · Sleepytime")
        XCTAssertEqual(tags.spoken(title: programme.title), "new, S2 E5 · Sleepytime")
    }

    func testAnOddValueIsNilNotAFailedGuide() throws {
        let programme = try decode(#"""
        {"title":"Cricket","startTime":1000,"endTime":2000,"live":"yes","new":"no","subtitle":"  ","episode":5,"image":null}
        """#)
        XCTAssertNil(programme.liveBroadcast)
        XCTAssertNil(programme.isNew)
        XCTAssertNil(programme.subtitle, "a blank subtitle is none")
        XCTAssertNil(programme.episode)
        XCTAssertNil(programme.image)
        XCTAssertThrowsError(try decode(#"{"title":"No times"}"#), "the four original fields are still required")
    }

    func testAGuidePageStillDecodesAndRoundTrips() throws {
        let json = #"""
        {"total":1,"channels":[{"id":"7","sourceId":1,"name":"Seven","logo":null,"category":null,
          "programmes":[{"title":"AFL","startTime":1000,"endTime":2000,"live":true},
                        {"title":"News","startTime":2000,"endTime":3000}]}]}
        """#
        let page = try JSONDecoder().decode(GuidePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.channels.first?.programmes.map(\.liveBroadcast), [true, nil])
        let again = try JSONDecoder().decode(GuideProgramme.self,
                                             from: JSONEncoder().encode(page.channels[0].programmes[0]))
        XCTAssertEqual(again, page.channels[0].programmes[0], "the fields survive an encode (the guide copy kept on the device)")
    }

    func testBadgesAndEpisodeLine() {
        XCTAssertEqual(ProgrammeTags(live: true, new: true).badges, [.live, .new], "LIVE before NEW")
        XCTAssertEqual(ProgrammeTags(live: true).spoken(), "live")
        XCTAssertEqual(ProgrammeTags(episode: "S1 E1").episodeLine(), "S1 E1")
        XCTAssertEqual(ProgrammeTags(subtitle: "Pilot").episodeLine(), "Pilot")
        XCTAssertNil(ProgrammeTags(subtitle: "Bluey").episodeLine(title: "bluey"), "a subtitle repeating the title is left out")
        XCTAssertEqual(ProgrammeTags(episode: "S3 E2", subtitle: "Bluey").episodeLine(title: "Bluey"), "S3 E2")
        XCTAssertTrue(ProgrammeTags().isEmpty)
        XCTAssertNil(ProgrammeTags().spoken())
        XCTAssertFalse(ProgrammeTags(new: true).isEmpty)
    }

    // #57: one live marker on a programme row: LIVE when the guide says live broadcast, else On now while it is on.
    func testARowShowsOneLiveMarker() {
        XCTAssertFalse(ProgrammeTags.showsOnNow(live: true, tags: ProgrammeTags(live: true)))
        XCTAssertTrue(ProgrammeTags.showsOnNow(live: true, tags: ProgrammeTags(new: true)))
        XCTAssertFalse(ProgrammeTags.showsOnNow(live: false, tags: ProgrammeTags()))
    }
}
