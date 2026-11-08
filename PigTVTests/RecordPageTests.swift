import XCTest
@testable import PigTV

/// D-44 batch 5 (Apple 114): the record page's choices (What, the padding chips, When it stops, Change recording's
/// change) and what the model sends: a Sport card's `gameId` with the schedule (C-M since 0440), and Change
/// recording's `PUT recordings/scheduled/:id` (C-M since 0444) with its answers from an older or a refusing server.
final class RecordPageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String = "Four Corners", start: TimeInterval = 2400, end: TimeInterval = 6000) -> GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    private func channel(_ name: String = "ABC TV", id: String = "abc") -> GuideChannel {
        GuideChannel(rawID: id, sourceId: 1, name: name, logo: nil, category: nil, programmes: [])
    }

    private func schedule(_ json: String) throws -> ScheduledRecording {
        try JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    private func game(followed: String? = "Liverpool", gameId: String? = "espn:soccer/eng.1:1") -> RecordRequest {
        RecordRequest(title: "Liverpool v Man City", league: "EPL",
                      airings: [.init(channel: channel("Optus Sport 1 UHD", id: "os1u"), programme: programme("Liverpool v Man City"), quality: .uhd),
                                .init(channel: channel("Optus Sport 1", id: "os1"), programme: programme("Liverpool v Man City"), quality: .hd)],
                      gameId: gameId, teams: [RecordTeam(name: "Liverpool"), RecordTeam(name: "Man City")],
                      followedTeam: followed, sport: "Football", isGame: true)
    }

    func testWhatOffersThisOneThenTheRules() {
        let guide = RecordRequest(title: "Four Corners", airings: [.init(channel: channel(), programme: programme())])
        XCTAssertEqual(RecordPlan.whats(guide, rulesAvailable: true), [.this, .everyNewEpisode, .everyEpisode])
        XCTAssertEqual(RecordPlan.whats(guide, rulesAvailable: false), [.this], "no rules without the server's rules")
        XCTAssertEqual(RecordPlan.whats(game(), rulesAvailable: true), [.this, .everyTeam("Liverpool"), .everyLeague("EPL")],
                       "the followed team, then the league")
        XCTAssertEqual(RecordPlan.whats(game(followed: nil), rulesAvailable: true),
                       [.this, .everyTeam("Liverpool"), .everyTeam("Man City"), .everyLeague("EPL")], "no follow: each side")
        var changing = game()
        changing.schedule = try? schedule(#"{"id":4,"title":"Liverpool v Man City","program_start":1,"program_end":2,"status":"scheduled"}"#)
        XCTAssertEqual(RecordPlan.whats(changing, rulesAvailable: true), [], "Change recording is one schedule")
        XCTAssertEqual(RecordPlan.label(.everyLeague("EPL"), request: game(), leagueLabel: "Premier League", now: now).title,
                       "Every Premier League game")
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: game()), "Record game")
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: guide), "Record programme")
    }

    func testRulesAreTheServersKinds() {
        let team = RecordPlan.rule(.everyTeam("Liverpool"), request: game(), before: 2, after: 15)
        XCTAssertEqual(team?.kind, "team")
        XCTAssertEqual(team?.sport, "Football")
        XCTAssertEqual(team?.preBufferMin, 2)
        var noSport = game()
        noSport.sport = nil
        XCTAssertEqual(RecordPlan.rule(.everyTeam("Liverpool"), request: noSport, before: nil, after: nil)?.kind, "sport",
                       "a keyword rule when the team's sport is not known")
        XCTAssertEqual(RecordPlan.rule(.everyLeague("EPL"), request: game(), before: nil, after: nil)?.match, "EPL")
        let guide = RecordRequest(title: "Four Corners", airings: [.init(channel: channel(), programme: programme())])
        let series = RecordPlan.rule(.everyNewEpisode, request: guide, before: nil, after: nil)
        XCTAssertEqual(series?.kind, "series")
        XCTAssertEqual(series?.channelId, "abc")
        XCTAssertEqual(series?.newOnly, true)
        XCTAssertEqual(RecordPlan.rule(.everyEpisode, request: guide, before: nil, after: nil)?.newOnly, false)
        XCTAssertNil(RecordPlan.rule(.this, request: guide, before: nil, after: nil))
    }

    func testWhenItStopsFollowsTheGameOrTheGuide() throws {
        XCTAssertEqual(RecordPlan.stopLines(game(), airing: game().airings.first, now: now).title, "When the game ends (ESPN)")
        XCTAssertEqual(RecordPlan.stopLines(game(gameId: nil), airing: nil, now: now).title, "When the guide says it ends")
        var changing = game(gameId: nil)
        changing.schedule = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","endsWith":"event"}"#)
        XCTAssertTrue(RecordPlan.stopsWithGame(changing), "a schedule the server links to its game")
    }

    func testChangeRecordingSendsOnlyWhatChangedAndNeverStartEarlyOnceItRecords() throws {
        let scheduled = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":3,"post_buffer_min":5}"#)
        XCTAssertEqual(scheduled.startEarly, 3)
        XCTAssertEqual(RecordPlan.chips(RecordPlan.startEarly, current: 3, changing: true), [0, 1, 2, 3, 5, 10],
                       "its own value, and no Usual")
        XCTAssertNil(RecordPlan.change(scheduled, before: 3, after: 5), "nothing changed")
        XCTAssertEqual(RecordPlan.change(scheduled, before: 3, after: 15), ScheduleChangeBody(postBufferMin: 15))
        XCTAssertEqual(RecordPlan.change(scheduled, before: 10, after: 5), ScheduleChangeBody(preBufferMin: 10))
        let recording = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"recording","pre_buffer_min":3,"post_buffer_min":5}"#)
        XCTAssertFalse(RecordPlan.canChangeStartEarly(recording))
        XCTAssertNil(RecordPlan.change(recording, before: 10, after: 5), "Start early cannot change once it records")
        XCTAssertEqual(RecordPlan.change(recording, before: 10, after: 30), ScheduleChangeBody(postBufferMin: 30))
        // A field of another type does not lose the schedule list.
        let odd = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":"two","endsWith":7}"#)
        XCTAssertNil(odd.startEarly)
        XCTAssertFalse(odd.stopsWithEvent)
    }

    /// Codex 5a round 1 (medium): only the second channel has it scheduled. Change recording is that channel's (the
    /// page starts on it), and choosing the unscheduled best channel is a new recording there, never a change of the
    /// other one.
    @MainActor
    func testChangeRecordingIsBoundToTheScheduledChannel() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let start = (now.timeIntervalSince1970 + 3600) * 1000, end = start + 7_200_000
        let best = SportEventChannel(sourceId: 1, rawID: "espn", name: "ESPN HD", startTime: start, endTime: end)
        let other = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Footy", startTime: start, endTime: end)
        let event = SportEvent(id: "e1", title: "Packers v Bears", league: "NFL", startTime: start, endTime: end,
                               channels: [best, other])
        browse.schedules = [try schedule(#"{"id":7,"title":"Packers v Bears","channel_name":"Fox Footy","program_start":\#(Int64(start)),"program_end":\#(Int64(end)),"status":"scheduled"}"#)]
        let request = try XCTUnwrap(browse.recordRequest(event: event, now: now))
        XCTAssertEqual(request.schedule?.id, 7)
        XCTAssertEqual(request.preferredChannel, other.id, "the page shows the channel whose schedule it changes")
        let chosen = try XCTUnwrap(browse.recordRequest(event: event, now: now, preferredChannel: best.id))
        XCTAssertNil(chosen.schedule, "Record on the unscheduled channel is a new recording")
        XCTAssertEqual(chosen.preferredChannel, best.id)
        XCTAssertEqual(try XCTUnwrap(browse.recordRequest(event: event, now: now, preferredChannel: other.id)).schedule?.id, 7)
    }

    /// Codex 5a round 1 (medium): the open page diffs against the schedule as the list has it now. Once it records, an
    /// edited Start early is left out and Finish late still goes; once it is gone there is nothing to change.
    func testTheOpenPageFollowsItsScheduleWhenItStartsRecordingOrEnds() throws {
        let opened = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":3,"post_buffer_min":5}"#)
        XCTAssertEqual(RecordPlan.change(opened, before: 10, after: 30), ScheduleChangeBody(preBufferMin: 10, postBufferMin: 30))
        let started = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"recording","pre_buffer_min":3,"post_buffer_min":5}"#)
        let live = try XCTUnwrap(RecordPlan.live(opened, in: [started]))
        XCTAssertEqual(RecordPlan.change(live, before: 10, after: 30), ScheduleChangeBody(postBufferMin: 30))
        XCTAssertNil(RecordPlan.live(opened, in: []), "gone")
        let ended = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"completed"}"#)
        XCTAssertNil(RecordPlan.live(opened, in: [ended]), "finished")
    }

    // MARK: What the model sends

    @MainActor
    private func model(_ http: LocalHTTPServer) throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
    }

    private static let row = #"{"id":9,"title":"Liverpool v Man City","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":1,"post_buffer_min":5}"#

    @MainActor
    func testASportCardsRecordingSendsItsGameId() async throws {
        let bodies = Locked<[Data]>([])
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"):
                bodies.value.append(request.body)
                return .json(Self.row, status: 201)
            case ("GET", "/api/recordings/scheduled"), ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = try model(http)
        let request = game()
        let scheduled = await browse.schedule(channel: request.airings[1].channel, programme: request.airings[1].programme,
                                              before: nil, after: 15, gameId: request.gameId)
        XCTAssertTrue(scheduled, browse.actionError ?? "")
        let sent = try XCTUnwrap(bodies.value.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(sent["gameId"] as? String, "espn:soccer/eng.1:1")
        XCTAssertEqual(sent["channelItemId"] as? String, "os1", "on the channel chosen under Record on")
        XCTAssertEqual(sent["postBufferMin"] as? Int, 15)
        XCTAssertNil(sent["preBufferMin"], "Usual: left to the server")
    }

    @MainActor
    func testChangeRecordingPutsTheChangeAndSaysWhyItCannot() async throws {
        let answer = Locked<LocalHTTPServer.Response>(.json(Self.row))
        let listed = Locked<String>("[]")
        let bodies = Locked<[Data]>([])
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("PUT", "/api/recordings/scheduled/9"):
                bodies.value.append(request.body)
                return answer.value
            case ("GET", "/api/recordings/scheduled"): return .json(listed.value)
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = try model(http)
        let item = try schedule(Self.row)
        let changed = await browse.changeSchedule(item, ScheduleChangeBody(postBufferMin: 15))
        XCTAssertTrue(changed, browse.actionError ?? "")
        let sent = try XCTUnwrap(bodies.value.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(sent["postBufferMin"] as? Int, 15)
        XCTAssertNil(sent["preBufferMin"], "only what changed")

        // The server's words for a value it refuses.
        answer.value = .json(#"{"error":"Finish late would stop it before now."}"#, status: 409)
        let refused = await browse.changeSchedule(item, ScheduleChangeBody(postBufferMin: 0))
        XCTAssertFalse(refused)
        XCTAssertEqual(browse.actionError, "Finish late would stop it before now.")

        // An older server has no such route: the schedule is still listed, so it is the server.
        answer.value = .notFound
        listed.value = "[\(Self.row)]"
        let old = await browse.changeSchedule(item, ScheduleChangeBody(postBufferMin: 15))
        XCTAssertFalse(old)
        XCTAssertEqual(browse.actionError, BrowseModel.cannotChangeText)
        answer.value = .json(#"{"error":"Method not allowed"}"#, status: 405)
        _ = await browse.changeSchedule(item, ScheduleChangeBody(postBufferMin: 15))
        XCTAssertEqual(browse.actionError, BrowseModel.cannotChangeText)

        // Gone or finished: it says so.
        answer.value = .notFound
        listed.value = "[]"
        _ = await browse.changeSchedule(item, ScheduleChangeBody(postBufferMin: 15))
        XCTAssertEqual(browse.actionError, "This recording has finished or no longer exists.")
        XCTAssertFalse(browse.mutationBusy)
    }
}

extension RecordPageTests {
    /// #49 (Codex batch 7a, high): with both opponents followed, each side's carousel card and the hero record that
    /// side's team, never the first followed match; with no team named, nothing is guessed: the menu offers no team
    /// rule and the record page offers both teams. Before Apple 140 Man City's card added a Liverpool rule.
    @MainActor
    func testBothOpponentsFollowedEachCardRecordsItsOwnTeam() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let front = try SportFrontLayoutTests.front { json in
            var follows = json["follows"] as? [[String: Any]] ?? []
            follows.insert(["league": "EPL", "sport": "Football", "name": "Man City", "logo": NSNull(), "state": "live",
                            "gameId": "espn:soccer/eng.1:1", "start": follows[0]["start"] ?? 0], at: 1)
            json["follows"] = follows
        }
        browse.sportFront.setFixture(front)
        let game = try XCTUnwrap(front.game("espn:soccer/eng.1:1"))
        let event = try XCTUnwrap(SportFrontText.event(game))
        let at = Date(timeIntervalSince1970: front.now / 1000)
        let cards = SportPhoneLayout.cards(front, hidden: false, now: at)
        XCTAssertEqual(cards[0].team, "Liverpool")
        XCTAssertEqual(cards[1].team, "Man City")
        for card in cards.prefix(2) {
            let request = try XCTUnwrap(browse.recordRequest(event: event, game: game, team: card.team, now: at))
            XCTAssertEqual(request.everyGameTeam, card.team)
            let items = SportRecordFlow.menuItems(request, rulesAvailable: true, now: at)
            XCTAssertTrue(items.contains { $0.title == "Record every \(card.team) game" }, items.map(\.title).joined(separator: ", "))
            XCTAssertEqual(RecordPlan.whats(request, rulesAvailable: true), [.this, .everyTeam(card.team), .everyLeague("EPL")])
        }
        let unnamed = try XCTUnwrap(browse.recordRequest(event: event, game: game, now: at))
        XCTAssertNil(unnamed.followedTeam)
        XCTAssertEqual(unnamed.followedTeams, ["Liverpool", "Man City"])
        XCTAssertNil(unnamed.everyGameTeam, "no guess between two followed sides")
        XCTAssertFalse(SportRecordFlow.menuItems(unnamed, rulesAvailable: true, now: at).contains { $0.id == "recordEvery" })
        XCTAssertEqual(RecordPlan.whats(unnamed, rulesAvailable: true),
                       [.this, .everyTeam("Liverpool"), .everyTeam("Man City"), .everyLeague("EPL")])
        let rows = SportPhoneLayout.groups(front, hidden: false, now: at)[0].rows
        XCTAssertEqual(rows[0].sides.map(\.followed), [true, true], "both sides starred")
    }
}

extension RecordPageTests {
    /// Codex batch 7a round 2 (high): a driver follow's carousel card and hero (Oscar Piastri on an F1 session, a game with
    /// no competitors) offer no "Record every Oscar Piastri game" and send no team rule: the server matches team rules
    /// only against a game's competitors, so it would record nothing. Before Apple 141 the named follow was kept as is.
    @MainActor
    func testADriverFollowOffersNoTeamRule() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let front = try SportFrontLayoutTests.front()
        browse.sportFront.setFixture(front)
        let game = try XCTUnwrap(front.game("espn:racing/f1:1"))
        let event = try XCTUnwrap(SportFrontText.event(game))
        let at = Date(timeIntervalSince1970: front.now / 1000)
        let card = try XCTUnwrap(SportPhoneLayout.cards(front, hidden: false, now: at).first { $0.gameId == game.id })
        XCTAssertEqual(card.team, "Oscar Piastri")
        let request = try XCTUnwrap(browse.recordRequest(event: event, game: game, team: card.team, now: at))
        XCTAssertNil(request.followedTeam)
        XCTAssertNil(request.everyGameTeam)
        XCTAssertFalse(SportRecordFlow.menuItems(request, rulesAvailable: true, now: at).contains { $0.id == "recordEvery" })
        XCTAssertFalse(RecordPlan.whats(request, rulesAvailable: true).contains {
            if case .everyTeam = $0 { return true } else { return false }
        })
    }

    /// #251: the note told every household "PigTV has one provider stream", whatever its providers.
    func testTheStreamNoteNamesNoNumberOfStreams() {
        let airing = RecordRequest.Airing(channel: channel(), programme: programme())
        let note = RecordPlan.streamNote(airing, before: nil, now: now)
        XCTAssertFalse(note.contains("one provider stream"), note)
        XCTAssertEqual(note, "If every provider connection is in use when it starts, the recording waits for one to free up.")
        let started = RecordRequest.Airing(channel: channel(), programme: programme(start: -60))
        XCTAssertEqual(RecordPlan.streamNote(started, before: nil, now: now), "It has started: only the rest of it is recorded.")
    }
}
