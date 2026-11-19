import XCTest
@testable import PigTV

// Codex sign-off of #347 (medium): schedule() reloaded the lists by joining a load already in flight, whose scheduled-list
// GET could have been read before the POST: the new schedule was then missing from the list schedule() returned with
// (the record page closed and the card showed nothing recorded until the next refresh). It now waits out a load that
// began before the write and reads again. Fails on the commit before (the list stayed empty).
@MainActor
final class ScheduleReadAfterWriteTests: XCTestCase {
    func testScheduleReturnsWithAListReadAfterItsPost() async throws {
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), end = start + 7_200_000
        let row = #"{"id":21,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(end),"status":"scheduled"}"#
        let posted = Locked(false), firstListAsked = Locked(false)
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/recordings/schedule"):
                posted.value = true
                return .json(row)
            case ("GET", "/api/recordings/scheduled"):
                // What the server has when the GET arrives; the first answer is slow, so the POST lands meanwhile.
                var answer = LocalHTTPServer.Response.json(posted.value ? "[\(row)]" : "[]")
                if !firstListAsked.value { firstListAsked.value = true; answer.delay = 0.8 }
                return answer
            case ("GET", "/api/recordings"):
                return .json("[]")
            default:
                return .notFound
            }
        }
        defer { http.stop() }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        // A refresh is in flight, its scheduled list already asked for (before the POST).
        let refresh = Task { await browse.loadRecordings(quietly: true) }
        for _ in 0..<100 where !firstListAsked.value { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(firstListAsked.value)
        let channel = GuideChannel(rawID: "fox", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil, programmes: [])
        let programme = GuideProgramme(title: "Australia v India", description: nil, startTime: Double(start), endTime: Double(end))
        let made = await browse.schedule(channel: channel, programme: programme, before: nil, after: nil)
        XCTAssertTrue(made, browse.actionError ?? "")
        XCTAssertEqual(browse.schedules.map(\.id), [21], "the list schedule() returns with was read after its POST")
        await refresh.value
        XCTAssertEqual(browse.schedules.map(\.id), [21], "the older answer, arriving later, does not put the list back")
    }
}
