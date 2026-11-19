import XCTest
@testable import PigTV

// Codex sign-off of #347 (high): game B now offers Record in a slot game A's schedule was made for, and the server's POST
// fell back to the existing row at that channel and start: it answered 201 with A's row, and the client closed the page
// as if B were recorded. A row naming another game is now no success (the page stays open with the reason), and so is
// the newer server's 409 "slotTaken". (Fails on the commit before: schedule() returned true.)
@MainActor
final class ScheduleSwappedGameTests: XCTestCase {
    private func run(_ answer: @escaping @Sendable () -> LocalHTTPServer.Response) async throws -> (Bool, String?) {
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), end = start + 7_200_000
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"): return answer()
            case ("GET", "/api/recordings/scheduled"), ("GET", "/api/recordings"): return .json("[]")
            default: return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        let channel = GuideChannel(rawID: "fox", sourceId: 1, name: "Fox Footy", logo: nil, category: nil, programmes: [])
        let programme = GuideProgramme(title: "B v C", description: nil, startTime: Double(start), endTime: Double(end))
        let made = await browse.schedule(channel: channel, programme: programme, before: nil, after: nil, gameId: "espn:afl:B")
        return (made, browse.actionError)
    }

    func testARowNamingAnotherGameIsNotThisGamesRecording() async throws {
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        let aRow = #"{"id":1,"title":"A v D","channel_name":"Fox Footy","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(start + 7_200_000),"status":"scheduled","gameId":"espn:afl:A"}"#
        let old = try await run { .json(aRow, status: 201) }
        XCTAssertFalse(old.0, "an older server's 201 with game A's row: not recorded")
        XCTAssertEqual(old.1, PageWords.slotTakenText)
        let new = try await run { .json(#"{"error":"Another game","code":"slotTaken","scheduleId":1}"#, status: 409) }
        XCTAssertFalse(new.0)
        XCTAssertEqual(new.1, PageWords.slotTakenText, "the newer server's 409 slotTaken says the same")
        let ok = try await run { .json(aRow.replacingOccurrences(of: "espn:afl:A", with: "espn:afl:B"), status: 201) }
        XCTAssertTrue(ok.0, "this game's own row: recorded")
    }
}
