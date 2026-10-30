import XCTest
@testable import PigTV

/// #12 (D-28: clashes are shown when scheduling, never silent; server 0324): the app reads `conflictsWith` and the
/// slot wait reason, shows them on the schedule, and says the clash in the message right after Record.
@MainActor
final class RecordingClashTests: XCTestCase {
    private static let other = #"{"id":5,"title":"Footy","channel_name":"Fox Footy","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[9]}"#
    private static let made = #"{"id":9,"title":"Cricket","channel_name":"Fox Cricket","program_start":1,"program_end":2,"status":"scheduled","conflictsWith":[5]}"#

    private func decode(_ json: String) throws -> ScheduledRecording {
        try JSONDecoder().decode(ScheduledRecording.self, from: Data(json.utf8))
    }

    func testAClashNamesTheOtherSchedulesAndASlotWaitSaysSo() throws {
        let footy = try decode(Self.other)
        let cricket = try decode(Self.made)
        XCTAssertEqual(cricket.clashText(in: [footy, cricket]), "Clashes with Footy (Fox Footy): one will wait or be missed.")
        XCTAssertEqual(try decode(#"{"id":1,"title":"S","program_start":1,"program_end":2,"status":"scheduled"}"#).clashText(in: []), nil)
        let slot = try decode(#"{"id":2,"title":"S","program_start":1,"program_end":2,"status":"waiting","error":"Another recording is using the recording slot."}"#)
        XCTAssertEqual(slot.statusLabel, "Waiting — another recording has the slot")
        let viewer = try decode(#"{"id":3,"title":"S","program_start":1,"program_end":2,"status":"waiting"}"#)
        XCTAssertEqual(viewer.statusLabel, "Waiting — someone is watching")
    }

    func testRecordSaysTheClashAtOnce() async throws {
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"): return .json(Self.made, status: 201)
            case ("GET", "/api/recordings/scheduled"): return .json("[\(Self.other),\(Self.made)]")
            case ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        let client = APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1)
        let model = BrowseModel(client: client, accountID: 1)
        let now = Date().timeIntervalSince1970 * 1000
        let channel = GuideChannel(rawID: "11", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil, programmes: [])
        let programme = GuideProgramme(title: "Cricket", description: nil, startTime: now + 3_600_000, endTime: now + 7_200_000)
        let ok = await model.schedule(channel: channel, programme: programme, before: 1, after: 5)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.actionMessage, "Recording scheduled. Clashes with Footy (Fox Footy): one will wait or be missed.")
    }
}
