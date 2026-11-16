import XCTest
@testable import PigTV

/// maroge1990/PigTV#329 (C-M): a second schedule of a game that already has an active one (same `gameId`, any channel)
/// is answered 200 with the existing schedule and `alreadyScheduled: true`; the server makes nothing. The app says so
/// ("Already set to record on <channel>") instead of "Recording scheduled".
@MainActor
final class RecordingAlreadyScheduledTests: XCTestCase {
    private static let existing = #"{"id":7,"title":"Packers v Bears","channel_name":"ESPN HD","program_start":1,"program_end":2,"status":"scheduled","alreadyScheduled":true}"#

    private func decode(_ json: String) throws -> ScheduledRecording {
        try JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    func testAlreadyScheduledDecodesAndIsFalseWhenAbsentOrMalformed() throws {
        let found = try decode(Self.existing)
        XCTAssertTrue(found.wasAlreadyScheduled)
        XCTAssertEqual(found.alreadyScheduledText, "Already set to record on ESPN HD.")
        let made = try decode(#"{"id":8,"title":"T","channel_name":"Fox","program_start":1,"program_end":2,"status":"scheduled"}"#)
        XCTAssertFalse(made.wasAlreadyScheduled, "an older server, or a new schedule")
        XCTAssertNil(made.alreadyScheduledText)
        let odd = try decode(#"{"id":8,"title":"T","program_start":1,"program_end":2,"status":"scheduled","alreadyScheduled":"yes"}"#)
        XCTAssertFalse(odd.wasAlreadyScheduled, "a malformed value never fails the row")
        let unnamed = try decode(#"{"id":8,"title":"T","program_start":1,"program_end":2,"status":"scheduled","alreadyScheduled":true}"#)
        XCTAssertEqual(unnamed.alreadyScheduledText, "Already set to record.")
    }

    private func server() throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"): return .json(Self.existing, status: 200)
            case ("GET", "/api/recordings/scheduled"): return .json("[\(Self.existing)]")
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
    }

    func testScheduleSaysTheGameIsAlreadySetToRecord() async throws {
        let http = try server()
        defer { http.stop() }
        let model = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let now = Date().timeIntervalSince1970 * 1000
        let channel = GuideChannel(rawID: "12", sourceId: 1, name: "Fox Sports 503", logo: nil, category: nil, programmes: [])
        let programme = GuideProgramme(title: "Packers v Bears", description: nil, startTime: now + 3_600_000, endTime: now + 7_200_000)
        let ok = await model.schedule(channel: channel, programme: programme, before: nil, after: nil, gameId: "espn:football/nfl:401")
        XCTAssertTrue(ok, "the game is set to record")
        XCTAssertEqual(model.actionMessage, "Already set to record on ESPN HD.", "names the existing schedule's channel, not the one asked")
        XCTAssertEqual(model.scheduleAlready, "Already set to record on ESPN HD.")
    }

    func testRecordFromThePlayerSaysItToo() async throws {
        let http = try server()
        defer { http.stop() }
        let client = APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1)
        let browse = BrowseModel(client: client, accountID: 1)
        let now = Date().timeIntervalSince1970 * 1000
        let programme = GuideProgramme(title: "Packers v Bears", description: nil, startTime: now - 60_000, endTime: now + 3_600_000)
        let channel = GuideChannel(rawID: "12", sourceId: 1, name: "Fox Sports 503", logo: nil, category: nil, programmes: [programme])
        browse.guide = [channel]
        let playback = PlaybackModel(channel: browse.asChannel(channel), client: client, programmes: [programme])
        let notice = await PlayerCommands.recordNow(playback: playback, browse: browse)
        XCTAssertEqual(notice, "Already set to record on ESPN HD.")
    }
}
