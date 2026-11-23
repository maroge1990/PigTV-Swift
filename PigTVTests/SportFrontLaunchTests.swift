import Combine
import XCTest
@testable import PigTV

/// A server whose preferences and front page answers each wait `delay` and answer `status`, recording when each request
/// started and finished.
private final class TimedSportRoutes: URLProtocol, @unchecked Sendable {
    struct Reply { var delay: TimeInterval = 0.3; var status = 200 }
    private static let lock = NSLock()
    nonisolated(unsafe) static var preferences = Reply()
    nonisolated(unsafe) static var front = Reply()
    nonisolated(unsafe) private static var log: [(path: String, start: Date, end: Date?)] = []

    static func reset(preferences: Reply = Reply(), front: Reply = Reply()) {
        lock.withLock { log = [] }
        Self.preferences = preferences
        Self.front = front
    }

    /// Each request's start and end, by path's last component.
    static var requests: [(path: String, start: Date, end: Date?)] { lock.withLock { log } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let name = path.hasSuffix("sports/pages/preferences") ? "preferences" : path.hasSuffix("sports/front") ? "front" : path
        let reply = name == "preferences" ? Self.preferences : name == "front" ? Self.front : Reply(delay: 0, status: 404)
        let index = Self.lock.withLock { Self.log.append((name, Date(), nil)); return Self.log.count - 1 }
        let body: Data
        if name == "preferences" {
            body = Data(#"{"spoilerFree":false,"sports":["NFL","Cricket"],"teams":{},"following":{}}"#.utf8)
        } else if name == "front" {
            body = (try? Fixture.data("sport-front-0381.json")) ?? Data("{}".utf8)
        } else {
            body = Data(#"{"error":"not here"}"#.utf8)
        }
        let status = reply.status
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            Self.lock.withLock { Self.log[index].end = Date() }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? body : Data(#"{"error":"refused"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// #55 (Apple 403): on a server with sport the app opens on Sport, and the launch splash waits for the front page's first
/// answer (`splashPageReady`, after the restore). That first refresh asked the household's preferences, then the front
/// page, one after the other: two round trips behind the splash. The front page is now asked at the same time; the
/// answer is still published only after the preferences, and what a success, a failure of either and a 401 leave is as
/// before.
@MainActor
final class SportFrontLaunchTests: XCTestCase {
    private func models() throws -> (SportFrontModel, F1PageModel) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimedSportRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        return (SportFrontModel(client: client), F1PageModel(client: client))
    }

    /// The page's first refresh, as the launch runs it (`keepFresh`'s first pass), and how long it took.
    private func firstRefresh(_ front: SportFrontModel, _ prefs: F1PageModel) async -> TimeInterval {
        prefs.invalidatePreferences()
        let began = Date()
        await front.refresh(preferences: prefs)
        return Date().timeIntervalSince(began)
    }

    func testTheFrontPageIsAskedWhileThePreferencesAreAsked() async throws {
        TimedSportRoutes.reset()
        let (front, prefs) = try models()
        let took = await firstRefresh(front, prefs)
        print("SPORT-FRONT-LAUNCH first refresh \(Int(took * 1000)) ms with 300 ms per answer")
        let requests = TimedSportRoutes.requests
        let asked = try XCTUnwrap(requests.first { $0.path == "preferences" })
        let page = try XCTUnwrap(requests.first { $0.path == "front" })
        XCTAssertEqual(requests.count, 2, "\(requests.map(\.path))")
        XCTAssertLessThan(page.start, try XCTUnwrap(asked.end), "the front page is asked before the preferences answer")
        XCTAssertLessThan(took, 0.55, "two answers at once (one after the other: 0.6 s); took \(took)")
        XCTAssertNotNil(front.front)
        XCTAssertEqual(front.state, .content)
        XCTAssertTrue(prefs.preferencesKnown)
        XCTAssertFalse(prefs.hidesSpoilers)
    }

    /// The answer is not published before the preferences have answered, even when it arrives first.
    func testAFrontPageThatAnswersFirstWaitsForThePreferences() async throws {
        TimedSportRoutes.reset(preferences: .init(delay: 0.6), front: .init(delay: 0.05))
        let (front, prefs) = try models()
        let refresh = Task { await firstRefresh(front, prefs) }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(front.front, "published before the preferences answered")
        XCTAssertEqual(front.state, .loading)
        _ = await refresh.value
        XCTAssertNotNil(front.front)
    }

    func testAFailedPreferencesReadStillShowsThePageWithTheScoresHidden() async throws {
        TimedSportRoutes.reset(preferences: .init(status: 500))
        let (front, prefs) = try models()
        _ = await firstRefresh(front, prefs)
        XCTAssertNotNil(front.front)
        XCTAssertNil(front.error)
        XCTAssertTrue(prefs.hidesSpoilers, "the household's choice could not be confirmed: hidden")
    }

    func testAFailedFrontPageShowsItsError() async throws {
        TimedSportRoutes.reset(front: .init(status: 500))
        let (front, prefs) = try models()
        _ = await firstRefresh(front, prefs)
        XCTAssertNil(front.front)
        XCTAssertNotNil(front.error)
        XCTAssertTrue(front.loaded)
        XCTAssertFalse(prefs.hidesSpoilers)
        XCTAssertEqual(TimedSportRoutes.requests.count, 2)
    }

    /// A 401 on both (a session that ended): the page settles on its error, nothing is published, each request was sent
    /// once, and the client's refusal watch (AppModel's, which confirms with auth/me) sees each as before.
    func testA401LeavesThePageAsBefore() async throws {
        TimedSportRoutes.reset(preferences: .init(status: 401), front: .init(status: 401))
        let (front, prefs) = try models()
        var refusals = 0
        front.client.unauthorisedHandler = { _ in refusals += 1 }
        _ = await firstRefresh(front, prefs)
        XCTAssertEqual(refusals, 2, "each 401 reaches the session's refusal check, as before")
        XCTAssertNil(front.front)
        XCTAssertNotNil(front.error)
        XCTAssertTrue(front.loaded)
        XCTAssertTrue(prefs.hidesSpoilers)
        XCTAssertEqual(TimedSportRoutes.requests.map(\.path).sorted(), ["front", "preferences"])
    }

    // MARK: One load at a time (Codex review of 403)

    /// Overlapping callers while the preferences are pending: `second` runs 150 ms into a refresh whose preferences take
    /// 600 ms. Exactly one front page request and one publish (6eece63 sent the front page ahead without registering the
    /// load, so the second caller sent its own).
    private func overlap(_ second: @escaping @MainActor (SportFrontModel, F1PageModel) async -> Void) async throws {
        TimedSportRoutes.reset(preferences: .init(delay: 0.6), front: .init(delay: 0.05))
        let (front, prefs) = try models()
        var publishes = 0
        let watch = front.$updatedAt.dropFirst().sink { if $0 != nil { publishes += 1 } }
        defer { watch.cancel() }
        prefs.invalidatePreferences()
        let first = Task { await front.refresh(preferences: prefs) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(front.front, "published before the preferences answered")
        await second(front, prefs)
        await first.value
        XCTAssertEqual(TimedSportRoutes.requests.filter { $0.path == "front" }.count, 1, "\(TimedSportRoutes.requests.map(\.path))")
        XCTAssertEqual(publishes, 1)
        XCTAssertNotNil(front.front)
        XCTAssertTrue(prefs.preferencesKnown)
    }

    func testALoadDuringARefreshsPreferencesJoinsIt() async throws {
        try await overlap { front, _ in await front.load() }
    }

    func testTwoOverlappingRefreshesSendOneFrontPageRequest() async throws {
        try await overlap { front, prefs in await front.refresh(preferences: prefs) }
    }
}
