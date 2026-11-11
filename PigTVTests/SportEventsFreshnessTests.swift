import XCTest
@testable import PigTV

// Audit F6: the Guide's Watch on… reads the sport events; they are asked again once they are older than five minutes.
@MainActor
final class SportEventsFreshnessTests: XCTestCase {
    private nonisolated func body(_ title: String) -> String {
        let start = Date().timeIntervalSince1970 * 1000
        return #"{"now":0,"events":[{"id":"e1","title":"\#(title)","league":"NFL","start":\#(start),"end":\#(start + 3_600_000),"channels":[{"sourceId":1,"id":"c1","name":"Sport 1"}]}]}"#
    }

    private func make(handler: @escaping @Sendable (LocalHTTPServer.Request) -> LocalHTTPServer.Response) throws
        -> (SportModel, LocalHTTPServer) {
        let server = try LocalHTTPServer(handler: handler)
        let client = APIClient(address: try ServerAddress(server.baseURL), token: "fixture")
        return (SportModel(client: client), server)
    }

    private func asked(_ server: LocalHTTPServer) -> Int { server.requests(path: "/api/sports/events").count }

    func testFreshEventsAreNotAskedAgain() async throws {
        let (model, server) = try make { _ in .json(self.body("First")) }
        defer { server.stop() }
        let t0 = Date()
        await model.loadIfStale(now: t0)
        XCTAssertEqual(asked(server), 1)
        await model.loadIfStale(now: Date().addingTimeInterval(60))
        XCTAssertEqual(asked(server), 1, "a minute old is fresh")
    }

    func testEventsOlderThanFiveMinutesAreReplaced() async throws {
        let count = Locked(0)
        let (model, server) = try make { _ in
            count.value += 1
            return .json(self.body(count.value == 1 ? "First" : "Second"))
        }
        defer { server.stop() }
        await model.loadIfStale()
        XCTAssertEqual(model.events.map(\.title), ["First"])
        await model.loadIfStale(now: Date().addingTimeInterval(5 * 60 + 1))
        XCTAssertEqual(asked(server), 2, "older than five minutes asks again")
        XCTAssertEqual(model.events.map(\.title), ["Second"], "the new events replace the old")
    }

    func testConcurrentCallsShareOneRequest() async throws {
        let (model, server) = try make { _ in
            var r = LocalHTTPServer.Response.json(self.body("First")); r.delay = 0.5; return r
        }
        defer { server.stop() }
        async let a: Void = model.loadIfStale()
        async let b: Void = model.loadIfStale()
        _ = await (a, b)
        XCTAssertEqual(asked(server), 1)
    }

    func testAFailedReloadKeepsTheOldEventsAndIsTriedAgain() async throws {
        let failing = Locked(false)
        let (model, server) = try make { _ in
            failing.value ? .json(#"{"error":"down"}"#, status: 500) : .json(self.body("First"))
        }
        defer { server.stop() }
        await model.loadIfStale()
        failing.value = true
        let later = Date().addingTimeInterval(6 * 60)
        await model.loadIfStale(now: later)
        XCTAssertEqual(asked(server), 2)
        XCTAssertEqual(model.events.map(\.title), ["First"], "the events already held stay")
        await model.loadIfStale(now: later)
        XCTAssertEqual(asked(server), 3, "a failure is not remembered as fresh")
    }
}
