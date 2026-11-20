import XCTest
@testable import PigTV

/// #358 (Mark's final design, 20 Nov 2026; the web's Record window, server 0881–0882): the record page's two rows and the
/// pages they open. Extra time's words ("Usual", else "2 min early, 8 min late"), its usual values (Finish late 0 for a game
/// ESPN follows, C-M since #358), the steppers' bounds (the server's 0-60 and 0-180), what is sent (nothing untouched; a
/// value stepped back to the usual is nothing again), the Channel row (pressable only with a choice; times only when the
/// airings differ), the "Set to record" line and Done. Before this change none of these existed (the page had chips and a
/// "When it stops" section): this file does not compile on the commit before.
final class RecordSheetTests: XCTestCase {
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

    private func guideProgramme() -> RecordRequest {
        RecordRequest(title: "Four Corners", airings: [.init(channel: channel(), programme: programme())])
    }

    private func game(sport: String? = "Football", gameId: String? = "espn:soccer/eng.1:1", laterOnSecond: Bool = false) -> RecordRequest {
        RecordRequest(title: "Liverpool v Man City", league: "EPL",
                      airings: [.init(channel: channel("Optus Sport 1 UHD", id: "os1u"), programme: programme("Liverpool v Man City"), quality: .uhd),
                                .init(channel: channel("Fox Sports", id: "fox"),
                                      programme: laterOnSecond ? programme("Liverpool v Man City", start: 9000, end: 15000)
                                                               : programme("Liverpool v Man City"), quality: .hd)],
                      gameId: gameId, teams: [RecordTeam(name: "Liverpool"), RecordTeam(name: "Man City")],
                      followedTeam: "Liverpool", sport: sport, isGame: true)
    }

    // MARK: Extra time

    func testExtraTimeSaysUsualUntilAValueDiffers() {
        let usual = RecordPlan.Usual(before: 1, after: 5)
        XCTAssertEqual(RecordPlan.extraWords(before: nil, after: nil, usual: usual), "Usual")
        XCTAssertEqual(RecordPlan.extraWords(before: 1, after: 5, usual: usual), "Usual", "the usual values, typed: still Usual")
        XCTAssertEqual(RecordPlan.extraWords(before: 2, after: 8, usual: usual), "2 min early, 8 min late")
        XCTAssertEqual(RecordPlan.extraWords(before: nil, after: 0, usual: usual), "1 min early, 0 min late", "both said once one differs")
        XCTAssertEqual(RecordPlan.minutes(8), "8 min")
    }

    /// Finish late's usual is 0 (ESPN's end) for what the server stops at the game's end, else Settings'.
    func testTheUsualFinishLateIsZeroForAGameESPNFollows() throws {
        let settings = RecordPlan.Usual(before: 2, after: 10)
        XCTAssertEqual(RecordPlan.usual(.this, request: game(), settings: settings), .init(before: 2, after: 0), "a card's game")
        XCTAssertEqual(RecordPlan.usual(.this, request: game(gameId: nil), settings: settings).after, 10, "no game id: the guide's end")
        XCTAssertEqual(RecordPlan.usual(.everyTeam("Liverpool"), request: game(), settings: settings).after, 0, "a team rule's games")
        XCTAssertEqual(RecordPlan.usual(.everyTeam("Liverpool"), request: game(sport: nil), settings: settings).after, 10,
                       "a team whose sport is unknown is a keyword rule: no game")
        XCTAssertEqual(RecordPlan.usual(.everyLeague("EPL"), request: game(), settings: settings).after, 10, "a league's keyword rule")
        XCTAssertEqual(RecordPlan.usual(.this, request: guideProgramme(), settings: settings).after, 10)
        XCTAssertEqual(RecordPlan.usual(.everyEpisode, request: guideProgramme(), settings: settings).after, 10)
        XCTAssertEqual(RecordPlan.usual(.this, request: guideProgramme()), RecordPlan.Usual.builtIn, "the server's own defaults")
        XCTAssertEqual(RecordPlan.Usual.builtIn, .init(before: 1, after: 5))

        var set = guideProgramme()
        set.schedule = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","gameId":"espn:soccer/eng.1:1"}"#)
        XCTAssertEqual(RecordPlan.usual(.this, request: set, settings: settings).after, 0, "a schedule made for a game")
        set.schedule = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","endsWith":"event"}"#)
        XCTAssertEqual(RecordPlan.usual(.this, request: set, settings: settings).after, 10,
                       "a title-joined schedule kept Settings' Finish late (only a game id gets 0)")
    }

    func testTheSteppersMoveOneMinuteWithinTheServersRanges() {
        XCTAssertEqual(RecordPlan.maxStartEarly, 60)
        XCTAssertEqual(RecordPlan.maxFinishLate, 180)
        // From the usual: the first press is one minute from it.
        XCTAssertEqual(RecordPlan.stepped(nil, by: 1, usual: 1, limit: 60, keepsValue: false), 2)
        XCTAssertEqual(RecordPlan.stepped(nil, by: -1, usual: 1, limit: 60, keepsValue: false), 0)
        // Never under 0 nor over the limit.
        XCTAssertEqual(RecordPlan.stepped(0, by: -1, usual: 5, limit: 180, keepsValue: false), 0)
        XCTAssertEqual(RecordPlan.stepped(180, by: 1, usual: 5, limit: 180, keepsValue: false), 180)
        XCTAssertEqual(RecordPlan.stepped(60, by: 1, usual: 1, limit: 60, keepsValue: true), 60)
        XCTAssertFalse(RecordPlan.canStep(0, by: -1, usual: 5, limit: 180))
        XCTAssertFalse(RecordPlan.canStep(nil, by: -1, usual: 0, limit: 180), "a game's usual 0: no −")
        XCTAssertTrue(RecordPlan.canStep(nil, by: 1, usual: 0, limit: 180))
        XCTAssertFalse(RecordPlan.canStep(180, by: 1, usual: 5, limit: 180))
        XCTAssertFalse(RecordPlan.canStep(nil, by: 1, usual: 60, limit: 60))
        XCTAssertTrue(RecordPlan.canStep(59, by: 1, usual: 1, limit: 60))
    }

    /// Codex on the web window (#358, medium): + then − came back to the usual but stored an explicit value, which a later
    /// switch to a rule with another usual then sent. A new recording's value back at the usual is nothing again; Change
    /// recording keeps the number (it is compared with the schedule's own).
    func testAValueSteppedBackToTheUsualIsNotSent() throws {
        let up = RecordPlan.stepped(nil, by: 1, usual: 0, limit: 180, keepsValue: false)
        XCTAssertEqual(up, 1)
        let back = RecordPlan.stepped(up, by: -1, usual: 0, limit: 180, keepsValue: false)
        XCTAssertNil(back, "back at the usual: nothing to send")
        // Untouched: nothing is sent with the rule either (the server applies the usual).
        let rule = try XCTUnwrap(RecordPlan.rule(.everyLeague("EPL"), request: game(), before: back, after: back))
        XCTAssertNil(rule.preBufferMin)
        XCTAssertNil(rule.postBufferMin)
        // Change recording: the schedule had 3; stepping to the usual 1 is a change to 1, so it is kept and sent.
        let scheduled = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":3,"post_buffer_min":5}"#)
        let two = RecordPlan.stepped(3, by: -1, usual: 1, limit: 60, keepsValue: true)
        let one = RecordPlan.stepped(two, by: -1, usual: 1, limit: 60, keepsValue: true)
        XCTAssertEqual(one, 1)
        XCTAssertEqual(RecordPlan.change(scheduled, before: one, after: 5), ScheduleChangeBody(preBufferMin: 1))
    }

    // MARK: Set to record

    func testSetToRecordSaysItsStateAndDoneSendsOnlyWhatChanged() throws {
        let scheduled = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled","pre_buffer_min":1,"post_buffer_min":0}"#)
        let waiting = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"waiting"}"#)
        let recording = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"recording","pre_buffer_min":1,"post_buffer_min":0}"#)
        XCTAssertEqual(RecordPlan.stateWords(scheduled, gone: false), "Set to record")
        XCTAssertEqual(RecordPlan.stateWords(waiting, gone: false), "Waiting to record")
        XCTAssertEqual(RecordPlan.stateWords(recording, gone: false), "Recording now")
        XCTAssertEqual(RecordPlan.stateWords(scheduled, gone: true), "Ended")
        var set = game()
        set.schedule = scheduled
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: set), "Done")
        XCTAssertEqual(RecordPlan.whats(set), [], "no What switch: one schedule")
        XCTAssertNil(RecordPlan.change(scheduled, before: 1, after: 0), "nothing changed: Done only closes")
        XCTAssertEqual(RecordPlan.change(recording, before: 4, after: 8), ScheduleChangeBody(postBufferMin: 8),
                       "while it records only Finish late goes")
    }

    // MARK: Channel

    func testTheChannelRowOpensOnlyWhenThereIsAChoice() throws {
        XCTAssertFalse(RecordPlan.channelChoosable(guideProgramme(), changing: false), "one channel: nothing to choose")
        XCTAssertTrue(RecordPlan.channelChoosable(game(), changing: false))
        var set = guideProgramme()
        set.schedule = try schedule(#"{"id":4,"title":"x","program_start":1,"program_end":2,"status":"scheduled"}"#)
        XCTAssertFalse(RecordPlan.channelChoosable(set, changing: true), "set to record: it records where it was set")
        var twoDays = game()
        twoDays.schedule = set.schedule
        XCTAssertFalse(RecordPlan.channelChoosable(twoDays, changing: true))
        twoDays.airingSchedules = [twoDays.airings[0].id: try XCTUnwrap(set.schedule)]
        XCTAssertTrue(RecordPlan.channelChoosable(twoDays, changing: true),
                      "Codex review of #347: another airing stays recordable while one is set to record")
    }

    func testTheChannelPageShowsTimesOnlyWhenTheAiringsDiffer() {
        let same = game()
        XCTAssertFalse(RecordPlan.channelsTimed(same))
        XCTAssertNil(RecordPlan.channelDetail(same.airings[1], timed: false, now: now))
        let later = game(laterOnSecond: true)
        XCTAssertTrue(RecordPlan.channelsTimed(later))
        let detail = RecordPlan.channelDetail(later.airings[1], timed: true, now: now)
        XCTAssertEqual(detail, "Today \(later.airings[1].programme.timeRange)")
        XCTAssertFalse(RecordPlan.channelsTimed(guideProgramme()), "one airing")
    }

    // MARK: Header and switch

    func testTheDateIsSaidOnceInTheHeaderAndTheSwitchHasShortWordsOnIPhone() {
        let request = game()
        XCTAssertEqual(RecordPlan.when(request, airing: request.airings[0], now: now),
                       "Today · \(request.airings[0].programme.timeRange)")
        XCTAssertNil(RecordPlan.when(RecordRequest(title: "x", airings: []), airing: nil, now: now))
        XCTAssertEqual(RecordPlan.whats(request).map { RecordPlan.title($0, request: request) },
                       ["This game", "Every Liverpool game", "Every EPL game"])
        XCTAssertEqual(RecordPlan.whats(request).map { RecordPlan.title($0, request: request, short: true) },
                       ["This game", "All Liverpool", "All EPL"])
        XCTAssertEqual(RecordPlan.whats(guideProgramme()).map { RecordPlan.title($0, request: guideProgramme()) },
                       ["This programme", "Every new episode", "Every episode"])
    }
}
