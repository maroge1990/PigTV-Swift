import XCTest
@testable import PigTV

/// D-44 batch 5 (Apple 119): what the Recordings tab draws: the featured recording, the cards, Coming up, and the
/// teams of a game recording.
final class RecordingsHomeTests: XCTestCase {
    private func recording(_ json: String) throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
    }
    private func schedule(_ json: String) throws -> ScheduledRecording {
        try JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    func testFeaturedIsTheNewestPartlyWatchedThenTheNewestUnwatched() throws {
        let live = try recording(#"{"id":5,"title":"Live","started_at":5000,"status":"recording"}"#)
        let new = try recording(#"{"id":4,"title":"New","started_at":4000,"status":"completed","duration_sec":1800}"#)
        let partly = try recording(#"{"id":3,"title":"Partly","started_at":3000,"status":"completed","duration_sec":1800}"#)
        let failed = try recording(#"{"id":2,"title":"Failed","started_at":6000,"status":"failed"}"#)
        let shelf = RecordingsHome.shelf([partly, failed, new, live])
        XCTAssertEqual(shelf.map(\.id), [5, 4, 3], "recording now first, then newest; never a failed one")
        let progress: (Recording) -> RecordingProgress = { $0.id == 3 ? RecordingProgress(fraction: 0.5, watched: false) : .none }
        XCTAssertEqual(RecordingsHome.featured(shelf, progress: progress)?.id, 3, "Continue wins")
        XCTAssertEqual(RecordingsHome.featured(shelf, progress: { _ in .none })?.id, 4, "else the newest finished")
        XCTAssertEqual(RecordingsHome.cards(shelf, featured: partly).map(\.id), [5, 4])
        XCTAssertEqual(RecordingsHome.shelf([new, live], hidden: ["recording:4"]).map(\.id), [5], "one waiting on its Undo is gone")
    }

    func testComingUpIsWhatIsStillToStartSoonestFirstWithItsClashes() throws {
        let later = try schedule(#"{"id":1,"title":"Later","program_start":9000,"program_end":9500,"status":"scheduled"}"#)
        let sooner = try schedule(#"{"id":2,"title":"Sooner","program_start":1000,"program_end":1500,"status":"waiting","conflictsWith":[1]}"#)
        let now = try schedule(#"{"id":3,"title":"Now","program_start":500,"program_end":1500,"status":"recording"}"#)
        let done = try schedule(#"{"id":4,"title":"Done","program_start":100,"program_end":200,"status":"failed"}"#)
        let items = RecordingsHome.comingUp([later, now, done, sooner])
        XCTAssertEqual(items.map(\.id), [2, 1])
        XCTAssertTrue(RecordingsHome.clashes(sooner))
        XCTAssertFalse(RecordingsHome.clashes(later))
        XCTAssertEqual(RecordingsHome.comingUp([later, sooner], hidden: ["schedule:2"]).map(\.id), [1])
    }

    func testWhenSaysTodayTomorrowAWeekdayOrADate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.locale = Locale(identifier: "en_AU")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 21, minute: 40))!
        func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        XCTAssertEqual(RecordingsHome.day(at(3, 22), now: now, calendar: calendar), "Today")
        XCTAssertEqual(RecordingsHome.day(at(4, 21), now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(RecordingsHome.day(at(7, 23), now: now, calendar: calendar), "Sat")
        XCTAssertTrue(RecordingsHome.day(at(12, 5), now: now, calendar: calendar).contains("12"), "a date beyond the week")
    }

    func testAGameTitleFindsItsTeamsLogosInTheLoadedSportData() throws {
        XCTAssertEqual(RecordingTeams.sides("AFL: Collingwood v Carlton · Round 3")?.0, "Collingwood")
        XCTAssertEqual(RecordingTeams.sides("Kansas City Chiefs vs Buffalo Bills")?.1, "Buffalo Bills")
        XCTAssertNil(RecordingTeams.sides("Four Corners"))
        let game = try JSONDecoder().decode(SportsGame.self, from: Data(#"""
        {"id":"g1","league":"EPL","title":"Liverpool v Manchester City","start":1,"status":"scheduled","freshness":"fresh",
         "progress":{},"availability":"available","broadcastStatus":"confirmed","channels":[],"events":[],"canWatch":false,
         "competitors":[{"id":"a","name":"Manchester City","logo":"/api/logo/mci"},{"id":"b","name":"Liverpool","logo":"https://example.com/liv.png"}]}
        """#.utf8))
        let teams = RecordingTeams.match(title: "Liverpool v Man City", games: [game])
        XCTAssertEqual(teams?.map(\.name), ["Liverpool", "Manchester City"], "in the title's order")
        XCTAssertEqual(teams?.map(\.logo), [nil, "/api/logo/mci"], "only cached same-server logos")
        XCTAssertEqual(RecordingTeams.match(title: "Packers v Lions", games: [game])?.map(\.name), ["Packers", "Lions"],
                       "no card: the title's two sides, as monogram discs")
        XCTAssertNil(RecordingTeams.match(title: "Gruen", games: [game]))
    }

    /// Apple 120: Scheduled lists every active schedule soonest first, names the rule a schedule came from, and sums up
    /// the rules and what needs attention for the iPhone's tiles.
    func testScheduledListsUpcomingRuleChipsAndAttention() throws {
        let series = try schedule(#"{"id":1,"title":"Four Corners","program_start":9000,"program_end":9500,"status":"scheduled","rule_id":7}"#)
        let game = try schedule(#"{"id":2,"title":"Pies v Blues","program_start":500,"program_end":1500,"status":"recording","rule_id":8}"#)
        let lost = try schedule(#"{"id":3,"title":"Lost","program_start":9000,"program_end":9500,"status":"scheduled","rule_id":99}"#)
        let missed = try schedule(#"{"id":4,"title":"Gruen","program_start":100,"program_end":200,"status":"missed"}"#)
        let failed = try recording(#"{"id":5,"title":"Packers v Bears","started_at":100,"status":"failed"}"#)
        XCTAssertEqual(ScheduledRows.upcoming([series, missed, lost, game]).map(\.id), [2, 1, 3])
        let rules = try JSONDecoder().decode([RecordingRule].self, from: Data(#"""
        [{"id":7,"kind":"series","match":"Four Corners","enabled":true},{"id":8,"kind":"team","match":"Collingwood","enabled":false}]
        """#.utf8))
        XCTAssertEqual(ScheduledRows.ruleChip(series, rules: rules), "Series")
        XCTAssertEqual(ScheduledRows.ruleChip(game, rules: rules), "Every Collingwood game")
        XCTAssertEqual(ScheduledRows.ruleChip(lost, rules: rules), "From a rule")
        XCTAssertNil(ScheduledRows.ruleChip(missed, rules: rules))
        XCTAssertEqual(ScheduledRows.rulesSummary(rules), "1 on · 1 off")
        let attention = ScheduledRows.attention(recordings: [failed], schedules: [series, missed])
        XCTAssertEqual(attention.map(\.id), ["schedule-4", "recording-5"])
        XCTAssertEqual(ScheduledRows.attentionSummary(attention), "1 missed · 1 failed")
        XCTAssertEqual(ScheduledRows.attention(recordings: [failed], schedules: [missed], hidden: ["recording:5"]).map(\.id), ["schedule-4"])
    }
}
