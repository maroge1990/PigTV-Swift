import XCTest
import Combine
@testable import PigTV

// C-S (#21, Apple 90): the Cricket page. `cricket-page-0387-stumps.json` and `cricket-page-0387-live.json` are the server's
// own answers (server 0387's sportPageCricket over its ESPN fixtures captured 31 Oct 2026 01:56 UTC: the 3rd Test of
// Australia in South Africa at stumps on day 4, and the same afternoon in play with Rickelton and Mulder at the crease,
// as the server's own test edits it), with the followed team Australia, channels from a guide stub (each with its own
// airing; on the live answer Kayo's slot has ended and the server rolled it on, `overrun: true`, as 0386 does) and the
// team logos as logo-cache paths. Before Apple 90 there is no Cricket page.
@MainActor
final class CricketPageTests: XCTestCase {
    /// 31 Oct 2026 01:56 UTC, when both answers were made.
    static let now = Date(timeIntervalSince1970: 1_793_411_760)

    nonisolated static func fixture(_ name: String) throws -> Data {
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] {
                if url.lastPathComponent == "cricket-page-0387-\(name).json" { return try Data(contentsOf: url) }
            }
        }
        throw XCTSkip("cricket-page-0387-\(name).json is not in the test bundle")
    }

    static func page(_ name: String) throws -> CricketPage { try JSONDecoder().decode(CricketPage.self, from: try fixture(name)) }

    private static var melbourne: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        c.locale = Locale(identifier: "en_AU")
        return c
    }

    func testTheLiveAnswerDecodes() throws {
        let p = try Self.page("live")
        XCTAssertTrue(p.available)
        XCTAssertEqual(p.updatedAt, 1_793_411_760_000)
        let lead = try XCTUnwrap(p.lead)
        XCTAssertEqual([lead.id, lead.seriesId, lead.label, lead.format, lead.day], ["1525661", "24203", "3rd Test", "test", "Day 4"])
        XCTAssertEqual(lead.status, .live)
        XCTAssertNil(lead.breakLabel)
        XCTAssertEqual(lead.session, 3)
        XCTAssertEqual(lead.teams.map(\.name), ["South Africa", "Australia"])
        XCTAssertEqual(lead.teams.map(\.abbr), ["SA", "AUS"])
        XCTAssertEqual(lead.teams[0].logo, "/api/logo/espn-cricket-3")
        XCTAssertEqual(lead.innings.map(\.count), [2, 1])
        XCTAssertEqual(lead.innings[0][1], CricketInnings(runs: 294, wickets: 5, overs: "103", declared: false, current: true))
        XCTAssertEqual(lead.summary, "South Africa lead by 194 runs")
        XCTAssertEqual(lead.crease?.map(\.name), ["RD Rickelton", "PWA Mulder"])
        XCTAssertEqual(lead.seriesLine, "Series level 1–1 · third of three Tests")
        XCTAssertNil(lead.nextStart)
        XCTAssertEqual(lead.channels.map(\.name), ["Fox Cricket", "Kayo Cricket 2"])
        XCTAssertEqual(lead.channels[1].endTime, 1_793_413_800_000, "an overrun airing decodes with its rolled-on end; `overrun` is ignored")
        let series = try XCTUnwrap(p.series)
        XCTAssertEqual(series.name, "Australia in South Africa")
        XCTAssertEqual(series.season, "2026/27")
        XCTAssertEqual(series.matches.count, 7)
        XCTAssertEqual(series.matches.filter(\.current).map(\.label), ["3rd Test"])
        XCTAssertEqual(series.matches[2].result, "Australia won by 45 runs (DLS)")
        XCTAssertNil(series.matches[6].result)
        XCTAssertEqual(p.others.count, 9)
        let wbbl = try XCTUnwrap(p.others.first { $0.status == .live && $0.competition == "WBBL" })
        XCTAssertEqual(wbbl.scores, ["161/6", "63/2 (7.3/20 ov, target 162)"])
        XCTAssertEqual(wbbl.line, "Stars need 99 from 75 balls")
        XCTAssertEqual(wbbl.channels.first?.name, "Fox Cricket")
    }

    func testTheStumpsAnswerDecodes() throws {
        let p = try Self.page("stumps")
        let lead = try XCTUnwrap(p.lead)
        XCTAssertEqual(lead.status, .onBreak)
        XCTAssertEqual(lead.breakLabel, "Stumps")
        XCTAssertNil(lead.session)
        XCTAssertNil(lead.crease)
        XCTAssertEqual(lead.nextStart, 1_793_435_400_000)
        XCTAssertEqual(lead.days.map(\.state), [.done, .done, .done, .done, .next])
        XCTAssertEqual(lead.channels.first?.startTime, 1_793_433_600_000, "day 5's airing")
        XCTAssertEqual(CricketPageText.innings(lead.innings[0]), "329 & 387")
        XCTAssertEqual(CricketPageText.innings(lead.innings[1]), "429")
    }

    func testNotReadyNoLeadAndATeamThatHasNotBatted() throws {
        let unavailable = try JSONDecoder().decode(CricketPage.self, from: Data(#"{"available":false}"#.utf8))
        XCTAssertFalse(unavailable.available)
        XCTAssertNil(unavailable.lead)
        XCTAssertTrue(unavailable.others.isEmpty)

        let empty = try JSONDecoder().decode(CricketPage.self, from: Data(#"{"available":true,"updatedAt":1,"lead":null,"series":null,"others":[{"id":"x"},{"teams":[]}]}"#.utf8))
        XCTAssertTrue(empty.available)
        XCTAssertNil(empty.lead)
        XCTAssertNil(empty.series)
        XCTAssertEqual(empty.others.map(\.id), ["x"], "an other match without an id is dropped, the rest stays")

        let lead = try JSONDecoder().decode(CricketLead.self, from: Data(#"""
            {"id":7,"status":"live","teams":[{"abbr":"TAS","name":"Tasmania","logo":null},{"abbr":"NSW","name":"New South Wales","logo":null}],
             "innings":[[{"runs":335,"wickets":5,"overs":"98.2","declared":false,"current":true}],[]],"summary":null,"crease":null,
             "days":[{"number":1,"date":1793278800000,"state":"live"},{"number":2,"date":1793365200000,"state":"later"}],"channels":[],"surprise":{"a":1}}
            """#.utf8))
        XCTAssertEqual(lead.id, "7", "a numeric id")
        XCTAssertEqual(CricketPageText.innings(lead.innings[0]), "335/5")
        XCTAssertNil(CricketPageText.innings(lead.innings[1]), "not batted: nothing, never 0")
        XCTAssertEqual(CricketPageText.battingNote(lead.innings[0], status: .live), "batting · 98.2 ov")
        XCTAssertNil(CricketPageText.battingNote(lead.innings[1], status: .live))
        XCTAssertEqual(lead.days.map(\.state), [.live, .later])
    }

    func testInningsText() {
        XCTAssertEqual(CricketPageText.innings([CricketInnings(runs: 329, wickets: 10), CricketInnings(runs: 200, wickets: 5, current: true)]), "329 & 200/5")
        XCTAssertEqual(CricketPageText.innings([CricketInnings(runs: 406, wickets: 5, declared: true)]), "406/5d")
        XCTAssertEqual(CricketPageText.innings([CricketInnings(runs: 406, wickets: 5, declared: true), CricketInnings(runs: 169, wickets: 10)]), "406/5d & 169")
        XCTAssertEqual(CricketPageText.innings([CricketInnings(runs: 0, wickets: 0, current: true)]), "0/0", "batting with no runs yet is a score")
        XCTAssertNil(CricketPageText.innings([]))
        XCTAssertEqual(CricketPageText.battingNote([CricketInnings(runs: 287, wickets: 7, overs: "90", current: true)], status: .onBreak), "90 ov")
        XCTAssertEqual(CricketPageText.crease([CricketBatter(name: "RD Rickelton", runs: 31, balls: 70), CricketBatter(name: "PWA Mulder", runs: 4, balls: 9)]),
                       "Rickelton 31* · Mulder 4*")
        XCTAssertNil(CricketPageText.crease(nil))
    }

    func testSpoilerFreeHidesEveryResultAndKeepsTheSchedule() throws {
        for name in ["live", "stumps"] {
            let p = try Self.page(name)
            XCTAssertEqual(CricketPageText.visible(p, spoilerFree: false), p, "nothing hidden with spoilers shown")
            let v = CricketPageText.visible(p, spoilerFree: true)
            let lead = try XCTUnwrap(v.lead), raw = try XCTUnwrap(p.lead)
            XCTAssertEqual(lead.innings.count, raw.innings.count)
            XCTAssertTrue(lead.innings.allSatisfy(\.isEmpty), "innings")
            XCTAssertNil(lead.summary, "summary")
            XCTAssertNil(lead.crease, "crease")
            XCTAssertNil(lead.seriesLine, "series line")
            XCTAssertFalse(CricketPageText.venueLine(lead).contains("Series"), "the venue line carries no series line")
            XCTAssertTrue(v.series?.matches.allSatisfy { $0.result == nil } == true, "results")
            let done = try XCTUnwrap(v.series?.matches.first { $0.status == .done })
            XCTAssertEqual(CricketPageText.seriesResult(done, lead: lead, spoilerFree: true, now: Self.now), "Finished")
            XCTAssertTrue(v.others.allSatisfy { $0.scores.allSatisfy { $0 == nil } && $0.line == nil }, "others' scores and lines")
            XCTAssertEqual(v.others.map(\.scores.count), p.others.map(\.scores.count))
            // Kept.
            XCTAssertEqual(lead.day, raw.day)
            XCTAssertEqual(lead.status, raw.status)
            XCTAssertEqual(lead.breakLabel, raw.breakLabel)
            XCTAssertEqual(lead.session, raw.session)
            XCTAssertEqual(lead.days, raw.days)
            XCTAssertEqual(lead.nextStart, raw.nextStart)
            XCTAssertEqual(lead.teams, raw.teams)
            XCTAssertEqual(lead.channels, raw.channels)
            XCTAssertEqual(v.others.map(\.status), p.others.map(\.status))
            XCTAssertEqual(v.others.map(\.teams), p.others.map(\.teams))
        }
        let shown = try XCTUnwrap(try Self.page("live").series?.matches[2])
        XCTAssertEqual(CricketPageText.seriesResult(shown, lead: nil, spoilerFree: false, now: Self.now), "Australia won by 45 runs (DLS)")
    }

    func testTheKickerPillAndDayChips() throws {
        let live = try XCTUnwrap(try Self.page("live").lead)
        XCTAssertEqual(CricketPageText.kicker(live), "3RD TEST · DAY 4 · SESSION 3")
        XCTAssertEqual(CricketPageText.pill(live, now: Self.now), "LIVE")
        XCTAssertEqual(live.days.map(\.state), [.done, .done, .done, .live, .next])
        XCTAssertEqual(CricketPageText.daySub(live.days[3], lead: live, now: Self.now), "Live now")
        XCTAssertEqual(CricketPageText.title(live.teams), "South Africa v Australia")
        let current = try XCTUnwrap(try Self.page("live").series?.matches.first(where: \.current))
        XCTAssertEqual(CricketPageText.seriesResult(current, lead: live, spoilerFree: true, now: Self.now), "Live · day 4")

        let stumps = try XCTUnwrap(try Self.page("stumps").lead)
        XCTAssertEqual(CricketPageText.kicker(stumps), "3RD TEST · STUMPS, DAY 4")
        XCTAssertEqual(CricketPageText.pill(stumps, now: Self.now), "DAY 5 IN 6 H")
        XCTAssertEqual(CricketPageText.daySub(stumps.days[3], lead: stumps, now: Self.now), "Stumps", "the current day at stumps")
        let first = CricketPageText.daySub(stumps.days[0], lead: stumps, now: Self.now, calendar: Self.melbourne)
        XCTAssertTrue(first.hasPrefix("Tue") && first.hasSuffix("27 Oct"), "the date, in the device's own format: \(first)")
        XCTAssertTrue(CricketPageText.daySub(stumps.days[4], lead: stumps, now: Self.now, calendar: Self.melbourne).contains("7:30"), "the next day's start")
        XCTAssertEqual(CricketPageText.venueLine(stumps, calendar: Self.melbourne), "Newlands, Cape Town · 5-day match, 27–31 Oct · Series level 1–1 · third of three Tests")
        let currentAtStumps = try XCTUnwrap(try Self.page("stumps").series?.matches.first(where: \.current))
        XCTAssertEqual(CricketPageText.seriesResult(currentAtStumps, lead: stumps, spoilerFree: false, now: Self.now), "Stumps · day 4")
    }

    // Watch on a channel's own airing (#20): an airing that has ended offers nothing to play; one the server rolled on for
    // an overrunning day (0386) still plays.
    func testWatchFollowsTheChannelsOwnEnd() throws {
        let live = try XCTUnwrap(try Self.page("live").lead)
        XCTAssertEqual(CricketPageText.actions(live, now: Self.now, pendingEventID: nil), [.watchLive, .otherChannels, .record(day: nil)])
        XCTAssertEqual(CricketPageText.actions(live, now: Self.now, pendingEventID: nil).map(CricketPageText.label), ["Watch live", "Other channels", "Record"])
        let afterFox = Date(timeIntervalSince1970: 1_793_431_800 + 60)
        XCTAssertEqual(CricketPageText.actions(live, now: afterFox, pendingEventID: nil), [], "the best channel's airing has ended")

        var overrun = live
        overrun.channels = [live.channels[1]]
        XCTAssertEqual(CricketPageText.actions(overrun, now: Self.now, pendingEventID: nil), [.watchLive, .record(day: nil)],
                       "its guide slot ended, the rolled-on end has not")
        XCTAssertEqual(CricketPageText.actions(overrun, now: Date(timeIntervalSince1970: 1_793_413_800 + 1), pendingEventID: nil), [])

        var noChannel = live
        noChannel.channels = []
        XCTAssertEqual(CricketPageText.actions(noChannel, now: Self.now, pendingEventID: nil), [], "nothing to play")
        XCTAssertEqual(CricketPageText.channelLine(noChannel, now: Self.now), "Not in guide yet")

        let stumps = try XCTUnwrap(try Self.page("stumps").lead)
        XCTAssertEqual(CricketPageText.actions(stumps, now: Self.now, pendingEventID: nil), [.remind(day: 5), .record(day: 5)])
        XCTAssertEqual(CricketPageText.actions(stumps, now: Self.now, pendingEventID: nil).map(CricketPageText.label), ["Remind me · day 5", "Record day 5"])
        XCTAssertEqual(CricketPageText.actions(stumps, now: Self.now, pendingEventID: "cricket:1525661"), [.cancelRemind, .record(day: 5)])
        XCTAssertTrue(CricketPageText.channelLine(stumps, now: Self.now, calendar: Self.melbourne).hasPrefix("Day 5 · "))
        XCTAssertTrue(CricketPageText.channelLine(stumps, now: Self.now).hasSuffix("on Fox Cricket"))
        XCTAssertEqual(CricketPageText.event(stumps).startTime, 1_793_433_600_000, "the channel's own airing")

        let p = try Self.page("live")
        let wbbl = try XCTUnwrap(p.others.first { $0.status == .live && $0.competition == "WBBL" })
        XCTAssertFalse(CricketPageText.othersPlaysNow(wbbl, now: Self.now), "its airing starts at 04:15")
        XCTAssertTrue(CricketPageText.othersPlaysNow(wbbl, now: Date(timeIntervalSince1970: 1_793_425_000)))
        XCTAssertFalse(CricketPageText.othersPlaysNow(wbbl, now: Date(timeIntervalSince1970: 1_793_433_600 + 1)), "ended")
    }
}

private final class CricketRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var asked: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.asked.append(path)
        let body: Data
        if path.hasSuffix("sports/pages/preferences") { body = Data(#"{"spoilerFree":true,"sports":["Cricket"],"teams":{"Cricket":["Australia"]},"following":{"F1":null,"NFL":null}}"#.utf8) }
        else if path.hasSuffix("sports/pages/cricket") { body = (try? CricketPageTests.fixture("live")) ?? Data("{}".utf8) }
        else { body = Data(#"{"available":false}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class CricketPageRefreshTests: XCTestCase {
    func testARefreshLoadsThePageAndThePreferences() async throws {
        CricketRoutes.asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CricketRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
        let prefs = F1PageModel(client: client, defaults: UserDefaults(suiteName: "cricket-\(UUID())")!)
        let model = CricketPageModel(client: client)
        await model.refresh(preferences: prefs)
        XCTAssertEqual(model.page?.lead?.id, "1525661")
        XCTAssertTrue(model.hasLiveMatch, "the lead is in play: the faster refresh")
        XCTAssertTrue(prefs.hidesSpoilers)
        XCTAssertEqual(prefs.preferences.teams["Cricket"], ["Australia"])
        XCTAssertEqual(CricketRoutes.asked.filter { $0.hasSuffix("sports/pages/cricket") }.count, 1)
        XCTAssertFalse(CricketRoutes.asked.contains { $0.hasSuffix("sports/pages/f1") || $0.hasSuffix("sports/pages/nfl") })
    }
}

/// A server whose preferences answer can be delayed or fail, and whose Cricket answer can change between loads.
private final class CricketSpoilerRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var spoilerFree = false
    nonisolated(unsafe) static var preferencesStatus = 200
    nonisolated(unsafe) static var preferencesDelay: TimeInterval = 0
    nonisolated(unsafe) static var answer = "stumps"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let preferences = path.hasSuffix("sports/pages/preferences")
        let status = preferences ? Self.preferencesStatus : 200
        let body = preferences ? Data(#"{"spoilerFree":\#(Self.spoilerFree),"sports":["Cricket"],"teams":{"Cricket":["Australia"]},"following":{"F1":null,"NFL":null}}"#.utf8)
            : path.hasSuffix("sports/pages/cricket") ? ((try? CricketPageTests.fixture(Self.answer)) ?? Data("{}".utf8)) : Data(#"{"available":false}"#.utf8)
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? body : Data(#"{"error":"down"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if preferences && Self.preferencesDelay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.preferencesDelay, execute: send) } else { send() }
    }
    override func stopLoading() {}
}

// Apple 90 (Codex round 1, high): spoiler-free switched on at another device must hide the scores before any new answer
// is drawn: the page published its answer before asking for the preferences, a failed preferences request kept the old
// choice, and a page opened again drew its cached scores under the old choice.
@MainActor
final class CricketPageSpoilerTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func models() throws -> (CricketPageModel, F1PageModel) {
        CricketSpoilerRoutes.spoilerFree = false
        CricketSpoilerRoutes.preferencesStatus = 200
        CricketSpoilerRoutes.preferencesDelay = 0
        CricketSpoilerRoutes.answer = "stumps"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CricketSpoilerRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
        return (CricketPageModel(client: client), F1PageModel(client: client, defaults: UserDefaults(suiteName: "cricket-spoilers-\(UUID())")!))
    }

    func testNewScoresAreNeverDrawnBeforeASlowSpoilerFreeAnswer() async throws {
        let (model, prefs) = try models()
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers, "spoilers shown, as this session last learned")
        CricketSpoilerRoutes.spoilerFree = true
        CricketSpoilerRoutes.preferencesDelay = 1.5
        CricketSpoilerRoutes.answer = "live"
        var drawnUnredacted: [Bool] = []
        model.$page.dropFirst().sink { page in if page?.lead?.status == .live { drawnUnredacted.append(!prefs.hidesSpoilers) } }.store(in: &cancellables)
        await model.refresh(preferences: prefs)
        XCTAssertEqual(model.page?.lead?.status, .live)
        XCTAssertEqual(drawnUnredacted, [false], "the new answer is published only once spoiler-free has answered")
        XCTAssertTrue(prefs.hidesSpoilers)
    }

    func testAFailedPreferencesRequestHidesTheScores() async throws {
        let (model, prefs) = try models()
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers)
        CricketSpoilerRoutes.preferencesStatus = 500
        CricketSpoilerRoutes.answer = "live"
        await model.refresh(preferences: prefs)
        XCTAssertTrue(prefs.hidesSpoilers, "the household's choice could not be confirmed: hidden")
        CricketSpoilerRoutes.preferencesStatus = 200
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers, "shown again once it answers")
    }

    func testAPageOpenedAgainHidesItsCachedScoresUntilThePreferencesAnswer() async throws {
        let (model, prefs) = try models()
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers)
        XCTAssertNotNil(model.page, "scores on hand from the last visit")
        CricketSpoilerRoutes.spoilerFree = true
        CricketSpoilerRoutes.preferencesDelay = 2
        let visit = Task { await model.keepFresh(preferences: prefs) }
        defer { visit.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(prefs.hidesSpoilers, "reopened: hidden while the preferences are asked again")
        let answered = await waitFor(5) { prefs.preferences.spoilerFree }
        XCTAssertTrue(answered)
        XCTAssertTrue(prefs.hidesSpoilers)
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
