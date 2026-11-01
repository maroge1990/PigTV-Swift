import XCTest
@testable import PigTV

/// #12 (D-42, server 0410–0415), maroge1990/PigTV#200: who wins a recording clash. A schedule that loses carries
/// `beatenBy` and says why it waits; the winner says it records; a `team` rule ("Record every game", 0414) reads with
/// its sport and who set it; a Sport front page card carries its recording (C-R `recording`, 0415). Before this change
/// none of these fields or texts existed. Pure: no UI, no server (the "choose" action is in RecordingChooseTests).
final class RecordingClashWinnerTests: XCTestCase {
    static let winner = #"{"id":5,"title":"Footy","channel_name":"Fox Footy","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[9]}"#
    static let loser = #"{"id":9,"title":"Cricket","channel_name":"Fox Cricket","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[5],"beatenBy":[5]}"#

    private func decode(_ json: String) throws -> ScheduledRecording {
        try JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    func testTheLoserSaysWhyItWaitsAndCanBeChosen() throws {
        let footy = try decode(Self.winner)
        let cricket = try decode(Self.loser)
        XCTAssertEqual(cricket.beatenBy, [5])
        XCTAssertTrue(cricket.isBeaten && cricket.canChoose)
        XCTAssertEqual(cricket.beatenText(in: [footy, cricket]), "Clashes with \u{201C}Footy\u{201D}, which was scheduled first.")
        XCTAssertEqual(cricket.clashText(in: [footy, cricket]), cricket.beatenText(in: [footy, cricket]))
        XCTAssertEqual(cricket.beatenText(in: [cricket]), "Clashes with \u{201C}another recording\u{201D}, which was scheduled first.")
        XCTAssertEqual(cricket.chooseMessage(in: [footy, cricket]), "Footy will wait instead. A recording already running is never stopped.")
        // The server's own reason wins over the client's.
        let told = try decode(#"{"id":9,"title":"Cricket","program_start":1,"program_end":2,"status":"waiting","beatenBy":[5],"error":"Clashes with “Footy”, which is recording."}"#)
        XCTAssertEqual(told.beatenText(in: [footy]), "Clashes with “Footy”, which is recording.")
        XCTAssertTrue(told.canChoose)
        // Never once it records.
        let running = try decode(#"{"id":9,"title":"Cricket","program_start":1,"program_end":2,"status":"recording","beatenBy":[5]}"#)
        XCTAssertFalse(running.canChoose)
        let empty = try decode(#"{"id":9,"title":"Cricket","program_start":1,"program_end":2,"status":"scheduled","beatenBy":[]}"#)
        XCTAssertFalse(empty.isBeaten)
    }

    func testTheWinnerSaysItRecordsAndAnOlderServerReadsAsBefore() throws {
        let footy = try decode(Self.winner)
        let cricket = try decode(Self.loser)
        XCTAssertNil(footy.beatenBy)
        XCTAssertFalse(footy.isBeaten)
        XCTAssertEqual(footy.clashText(in: [footy, cricket]), "Clashes with Cricket (Fox Cricket): this one records; Cricket waits.")
        // A server before 0410 sends no beatenBy: today's wording.
        let old = try decode(#"{"id":9,"title":"Cricket","channel_name":"Fox Cricket","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[5]}"#)
        XCTAssertNil(old.beatenText(in: [footy, old]))
        XCTAssertEqual(footy.clashText(in: [footy, old]), "Clashes with Cricket (Fox Cricket): one will wait or be missed.")
    }

    func testATeamRuleReadsWithItsSportAndWhoSetIt() throws {
        let team = try JSONDecoder().decode(RecordingRule.self, from: Data(#"{"id":12,"kind":"team","match":"Collingwood","sport":"Australian Football","createdBy":2,"createdByName":"Mark","enabled":true,"upcoming":1}"#.utf8))
        XCTAssertEqual(team.summary, "Every Collingwood game (Australian Football)")
        XCTAssertEqual(team.setBy, "Set by Mark")
        XCTAssertEqual(team.createdBy, 2)
        let anonymous = try JSONDecoder().decode(RecordingRule.self, from: Data(#"{"id":13,"kind":"team","match":"Collingwood","sport":"Australian Football","createdBy":null,"createdByName":null}"#.utf8))
        XCTAssertNil(anonymous.setBy)
        let sport = try JSONDecoder().decode(RecordingRule.self, from: Data(#"{"id":4,"kind":"sport","match":"AFL"}"#.utf8))
        XCTAssertEqual(sport.summary, "Every game: AFL")
    }

    func testAFrontCardCarriesItsRecordingAndClash() throws {
        func game(_ recording: String?) throws -> SportsGame {
            let extra = recording.map { #","recording":\#($0)"# } ?? ""
            let json = #"{"id":"g","league":"NFL","title":"Chiefs v Bills","start":1,"end":2,"session":null,"circuit":null,"format":null,"competitors":[],"status":"scheduled","freshness":"fresh","progress":{},"scores":null,"situation":null,"breakLabel":null,"availability":"available","broadcastStatus":"scheduled","channels":[],"events":[],"canWatch":false,"dataSource":null\#(extra)}"#
            return try JSONDecoder().decode(SportsGame.self, from: Data(json.utf8))
        }
        let losing = try game(#"{"scheduleId":93,"status":"scheduled","ruleId":4,"clashesWith":["Evening Match","Footy"]}"#)
        XCTAssertEqual(losing.recordingMark?.scheduleId, 93)
        XCTAssertEqual(losing.recordingMark?.ruleId, 4)
        XCTAssertEqual(losing.recordingMark?.label, "Set to record")
        XCTAssertEqual(losing.recordingMark?.clashLine, "Clashes with Evening Match, Footy")
        let recording = try game(#"{"scheduleId":7,"status":"recording","ruleId":null}"#)
        XCTAssertEqual(recording.recordingMark?.label, "Recording")
        XCTAssertNil(recording.recordingMark?.clashLine)
        XCTAssertNil(try game(nil).recordingMark)
        // A malformed one is dropped, never the card.
        XCTAssertNil(try game(#""soon""#).recordingMark)
        XCTAssertNil(try game(#"{"scheduleId":"x","status":"scheduled"}"#).recordingMark)
    }
}
