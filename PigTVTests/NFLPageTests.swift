import XCTest
@testable import PigTV

// C-Q (#21): the NFL page. `nfl-page-0379.json` is the server's own answer (server 0379's sportPageNFL over its ESPN
// fixtures captured 31 Oct 2026 08:42 Melbourne: week 7's finals, week 8 with Thursday's Panthers at Packers final and
// the rest to come, one channel on Ravens at Bills, the eight divisions). Before Apple 86 there is no NFL page.
@MainActor
final class NFLPageTests: XCTestCase {
    nonisolated static func fixture() throws -> Data { try Fixture.data("nfl-page-0379.json") }

    private func page() throws -> NFLPage { try JSONDecoder().decode(NFLPage.self, from: try Self.fixture()) }

    func testTheServersAnswerDecodesAndOpensOnTheCurrentWeek() throws {
        let p = try page()
        XCTAssertTrue(p.available)
        XCTAssertEqual(p.weeks.map(\.label), ["Week 7", "Week 8"])
        XCTAssertEqual(p.weeks.first(where: \.current)?.number, 8)
        XCTAssertEqual(Set(p.weeks[1].byes), ["HOU", "NO", "NYG", "SF"])
        XCTAssertEqual(p.teams.count, 32)
        XCTAssertEqual(p.standings.count, 8)
        let thursday = p.weeks[1].games[0]
        XCTAssertEqual([thursday.away.abbr, thursday.home.abbr], ["CAR", "GB"])
        XCTAssertEqual(thursday.status, .done)
        XCTAssertEqual(NFLPageText.score(thursday.home, game: thursday, spoilerFree: false), "27")
        XCTAssertNil(NFLPageText.score(thursday.home, game: thursday, spoilerFree: true), "spoiler-free hides the score")
        XCTAssertEqual(NFLPageText.status(thursday, spoilerFree: true), "Played")
        let next = p.weeks[1].games[1]
        XCTAssertNil(NFLPageText.score(next.home, game: next, spoilerFree: false), "0 before kick-off is not a score")
    }

    func testAGameIsAnEventOnItsChannelsOwnTimes() throws {
        let p = try page()
        let ravens = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "BAL" })
        let event = NFLPageText.event(ravens, in: p)
        XCTAssertEqual(event.title, "Ravens at Bills")
        XCTAssertEqual(event.league, "NFL")
        XCTAssertEqual(event.best?.name, "Fox Sports 505")
        XCTAssertEqual(event.startTime, ravens.startTime - 1_800_000, "the channel's own airing (#20)")
        let other = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "TEN" })
        XCTAssertNil(NFLPageText.event(other, in: p).best, "not in the guide yet")
    }

    func testStandingsViewsDivisionConferenceOverall() throws {
        let p = try page()
        let division = NFLPageText.standings(p, view: .division, following: "GB")
        XCTAssertEqual(division.first?.title, "NFC North", "the followed team's division first")
        XCTAssertEqual(division.count, 8)
        let conference = NFLPageText.standings(p, view: .conference, following: "GB")
        XCTAssertEqual(conference.map(\.title), ["NFC", "AFC"])
        XCTAssertEqual(conference[0].rows.map(\.rank), Array(1...16), "by seed")
        let overall = NFLPageText.standings(p, view: .overall, following: nil)
        XCTAssertEqual(overall.count, 1)
        XCTAssertEqual(overall[0].rows.count, 32)
        let shares = overall[0].rows.map { NFLPageText.winShare($0.row) }
        XCTAssertEqual(shares, shares.sorted(by: >))
    }

    func testTheFollowedTeamIsKeptAndSentInThePreferences() throws {
        let prefs = try JSONDecoder().decode(SportPagePreferences.self, from: Data(#"{"spoilerFree":true,"following":{"F1":"Lando Norris","NFL":"GB"}}"#.utf8))
        XCTAssertEqual(prefs.nflFollowing, "GB")
        XCTAssertEqual(prefs.f1Following, "Lando Norris")
        let older = try JSONDecoder().decode(SportPagePreferences.self, from: Data(#"{"spoilerFree":false,"following":{"F1":null}}"#.utf8))
        XCTAssertNil(older.nflFollowing, "a server before 0379")
        let round = try JSONDecoder().decode(SportPagePreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(round, prefs)
    }

    func testANotReadyAnswerDecodesAsUnavailable() throws {
        let p = try JSONDecoder().decode(NFLPage.self, from: Data(#"{"available":false}"#.utf8))
        XCTAssertFalse(p.available)
        XCTAssertTrue(p.weeks.isEmpty)
    }
}

private final class NFLRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var asked: [String] = []
    nonisolated(unsafe) static var preferences = #"{"spoilerFree":false,"following":{"F1":null,"NFL":"GB"}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.asked.append(path)
        let body: Data
        if path.hasSuffix("sports/pages/preferences") { body = Data(Self.preferences.utf8) }
        else if path.hasSuffix("sports/pages/nfl") { body = (try? NFLPageTests.fixture()) ?? Data("{}".utf8) }
        else { body = Data(#"{"available":false}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class NFLPageRefreshTests: XCTestCase {
    // #184 (Apple 86 Codex round 1): a game with no guide channel offered a Watch that did nothing.
    func testEveryPlayActionNeedsAChannel() throws {
        let p = try JSONDecoder().decode(NFLPage.self, from: try NFLPageTests.fixture())
        let ravens = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "BAL" })
        let before = ravens.start.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(NFLPageText.actions(ravens, in: p, now: before, pendingEventID: nil), [.watchAtKickOff, .record])
        XCTAssertEqual(NFLPageText.actions(ravens, in: p, now: before, pendingEventID: "nfl:\(ravens.id)"), [.cancelKickOff, .record])
        var live = ravens
        live.status = .live
        XCTAssertEqual(NFLPageText.actions(live, in: p, now: ravens.start.addingTimeInterval(600), pendingEventID: nil), [.watchLive, .record])
        var noChannel = live
        noChannel.channels = []
        XCTAssertEqual(NFLPageText.actions(noChannel, in: p, now: ravens.start.addingTimeInterval(600), pendingEventID: nil), [], "nothing to play")
        let thursday = p.weeks[1].games[0]
        XCTAssertEqual(NFLPageText.actions(thursday, in: p, now: Date(), pendingEventID: nil), [], "finished, no channel")
    }

    // #187 (Apple 87 Codex round 2): a game ESPN marks live whose channel airs it later (a delayed broadcast) offered
    // only Record, a pending watch could not be cancelled from it, and the team card still said "Watch live". Deferred
    // play is now chosen from the channel's airing for live games too (as the F1 page), with the cancel kept. On the
    // old code the first assertion gets [.record].
    func testALiveGameOnALaterChannelOffersTheDeferredWatchAndItsCancel() throws {
        let p = try JSONDecoder().decode(NFLPage.self, from: try NFLPageTests.fixture())
        let ravens = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "BAL" })
        let channel = try XCTUnwrap(ravens.channels.first)
        let now = ravens.start.addingTimeInterval(600)
        let airs = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 2 * 3600).rounded())
        var delayed = ravens
        delayed.status = .live
        delayed.channels = [SportEventChannel(sourceId: channel.sourceId, rawID: channel.rawID, stableId: channel.stableId,
                                              name: channel.name, number: channel.number, quality: channel.quality,
                                              startTime: airs.timeIntervalSince1970 * 1000,
                                              endTime: airs.timeIntervalSince1970 * 1000 + 3.5 * 3600 * 1000)]
        let id = "nfl:\(ravens.id)"
        XCTAssertEqual(NFLPageText.actions(delayed, in: p, now: now, pendingEventID: nil), [.watchAt(airs), .record])
        XCTAssertEqual(NFLPageText.actions(delayed, in: p, now: now, pendingEventID: id), [.cancelWatchAt(airs), .record],
                       "an existing pending watch can be cancelled")
        let time = airs.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(NFLPageText.label(.watchAt(airs)), "Watch at \(time)")
        XCTAssertEqual(NFLPageText.label(.cancelWatchAt(airs)), "Don't watch at \(time)")
        // Once its channel airs it, Watch live.
        XCTAssertEqual(NFLPageText.actions(delayed, in: p, now: airs.addingTimeInterval(60), pendingEventID: nil), [.watchLive, .record])
    }

    // #205 (Mark, TestFlight 90): the page drew colour discs instead of the team logos the server sends (C-Q
    // `teams[abbr].logo`). A team with a logo draws it (a logo-cache path, as the front page's badges); no logo, the
    // disc in the team's colour. Before this change the page never read `logo`.
    func testATeamWithALogoDrawsItsBadgeAndNoneTheDisc() throws {
        var p = try JSONDecoder().decode(NFLPage.self, from: try NFLPageTests.fixture())
        XCTAssertEqual(p.teams["GB"]?.logo.map { $0.hasPrefix("/api/logo/") }, true)
        XCTAssertEqual(NFLPageText.logo("GB", in: p), p.teams["GB"]?.logo, "the Packers' badge")
        XCTAssertTrue(p.teams.keys.allSatisfy { NFLPageText.logo($0, in: p) != nil }, "every team in the answer has its badge")
        p.teams["GB"]?.logo = nil
        XCTAssertNil(NFLPageText.logo("GB", in: p), "no logo: the disc")
        p.teams["CHI"]?.logo = "https://a.espncdn.com/i/teamlogos/nfl/500/chi.png"
        XCTAssertNil(NFLPageText.logo("CHI", in: p), "never a source URL, only the server's logo cache")
        XCTAssertNil(NFLPageText.logo("XYZ", in: p), "an unknown team: the disc")
        XCTAssertEqual(NFLPageText.discColor("GB", in: p), p.teams["GB"]?.color)
        p.teams["LV"]?.color = "000000"
        XCTAssertEqual(NFLPageText.discColor("LV", in: p), "3A3242", "black lifted to the dark plum, as before")
    }

    // #185 (Apple 86 Codex round 1): the page reloaded only its own data, so spoiler-free switched on elsewhere never
    // reached an open page. A refresh now reloads the household's preferences too, and never the F1 page.
    func testARefreshReloadsThePreferencesWithoutTheF1Page() async throws {
        NFLRoutes.asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NFLRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
        let prefs = F1PageModel(client: client)
        let model = NFLPageModel(client: client)
        await model.refresh(preferences: prefs)
        XCTAssertEqual(prefs.preferences.nflFollowing, "GB")
        XCTAssertFalse(prefs.hidesSpoilers)
        NFLRoutes.preferences = #"{"spoilerFree":true,"following":{"F1":null,"NFL":"GB"}}"#
        await model.refresh(preferences: prefs)
        XCTAssertTrue(prefs.hidesSpoilers, "switched on elsewhere: hidden at the next refresh")
        XCTAssertFalse(NFLRoutes.asked.contains { $0.hasSuffix("sports/pages/f1") })
        XCTAssertEqual(NFLRoutes.asked.filter { $0.hasSuffix("sports/pages/nfl") }.count, 2)
    }
}
