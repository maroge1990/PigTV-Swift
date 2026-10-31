import XCTest
@testable import PigTV

/// A server whose preferences answers are scripted one per request (delay, spoiler-free, status), with the front page's,
/// the F1 page's and the Cricket page's own answers.
private final class ScriptedPreferencesRoutes: URLProtocol, @unchecked Sendable {
    struct Reply { var delay: TimeInterval = 0; var spoilerFree = false; var status = 200 }
    private static let lock = NSLock()
    nonisolated(unsafe) static var script: [Reply] = []
    nonisolated(unsafe) static var otherwise = Reply()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func fixture(_ name: String) -> Data {
        let url = Bundle(for: ScriptedPreferencesRoutes.self).urls(forResourcesWithExtension: "json", subdirectory: nil)?.first { $0.lastPathComponent == name }
        return url.flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var reply = Reply()
        let body: Data
        if path.hasSuffix("sports/pages/preferences") {
            Self.lock.lock()
            reply = Self.script.isEmpty ? Self.otherwise : Self.script.removeFirst()
            Self.lock.unlock()
            body = Data(#"{"spoilerFree":\#(reply.spoilerFree),"sports":["NFL","Cricket"],"teams":{"Cricket":["Australia"]},"following":{"F1":null,"NFL":"GB"}}"#.utf8)
        } else if path.hasSuffix("sports/front") { body = Self.fixture("sport-front-0381.json") }
        else if path.hasSuffix("sports/pages/f1") { body = Self.fixture("f1-page-0346.json") }
        else if path.hasSuffix("sports/pages/cricket") { body = Self.fixture("cricket-page-0387-live.json") }
        else { body = Data(#"{"available":false}"#.utf8) }
        let status = reply.status
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? body : Data(#"{"error":"down"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send) } else { send() }
    }
    override func stopLoading() {}
}

// Apple 90 (Codex round 2, two highs). The Sport front page kept the household's spoiler choice it last read: reopened,
// it drew cached scores while the preferences loaded, and a failed read left newly fetched scores visible. And a slow
// preferences answer from before a newer read (an F1 backdrop load that outlived the front page) could still apply,
// undoing spoiler-free that a sport page had just learned, across every page sharing the choice.
@MainActor
final class SportSpoilerFailClosedTests: XCTestCase {
    private func setUp(spoilerFree: Bool = false) throws -> (APIClient, F1PageModel) {
        ScriptedPreferencesRoutes.script = []
        ScriptedPreferencesRoutes.otherwise = .init(spoilerFree: spoilerFree)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedPreferencesRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
        return (client, F1PageModel(client: client, defaults: UserDefaults(suiteName: "fail-closed-\(UUID())")!))
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The front page with scores shown, an F1 page already loaded (no backdrop load) and a non-F1 hero.
    private func shownFront(_ client: APIClient, _ prefs: F1PageModel) async throws -> SportFrontModel {
        await prefs.load()
        XCTAssertNotNil(prefs.page, "an F1 page on hand")
        let front = SportFrontModel(client: client)
        await front.refresh(preferences: prefs)
        XCTAssertNotNil(front.front)
        XCTAssertNotEqual(front.heroGame?.league, "F1", "a non-F1 hero")
        XCTAssertFalse(prefs.hidesSpoilers)
        return front
    }

    func testTheFrontPageReopenedHidesItsCachedScoresUntilThePreferencesAnswer() async throws {
        let (client, prefs) = try setUp()
        let front = try await shownFront(client, prefs)
        ScriptedPreferencesRoutes.otherwise = .init(delay: 2, spoilerFree: true)
        let visit = Task { await front.keepFresh(preferences: prefs) }
        defer { visit.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(prefs.hidesSpoilers, "reopened: the cached scores are hidden while the preferences are asked again")
        let answered = await waitFor(5) { prefs.preferences.spoilerFree }
        XCTAssertTrue(answered)
        XCTAssertTrue(prefs.hidesSpoilers)
    }

    func testAFailedPreferencesReadOnTheFrontPageHidesTheScores() async throws {
        let (client, prefs) = try setUp()
        let front = try await shownFront(client, prefs)
        ScriptedPreferencesRoutes.script = [.init(status: 500)]
        await front.refresh(preferences: prefs)
        XCTAssertNotNil(front.front)
        XCTAssertTrue(prefs.hidesSpoilers, "the household's choice could not be confirmed: hidden")
        await front.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers, "shown again once it answers")
    }

    func testAnOlderPreferencesAnswerCannotUndoANewerOne() async throws {
        let (client, prefs) = try setUp()
        _ = try await shownFront(client, prefs)
        // The front page's F1 backdrop load asks first and is slow (scores shown, as it was then); the viewer opens the
        // Cricket page, which asks again and learns spoiler-free is on.
        ScriptedPreferencesRoutes.script = [.init(delay: 1.5, spoilerFree: false), .init(spoilerFree: true)]
        ScriptedPreferencesRoutes.otherwise = .init(spoilerFree: true)
        let backdrop = Task { await prefs.load() }
        try await Task.sleep(for: .milliseconds(200))
        let cricket = CricketPageModel(client: client)
        let visit = Task { await cricket.keepFresh(preferences: prefs) }
        defer { visit.cancel(); backdrop.cancel() }
        let learned = await waitFor(1) { prefs.preferences.spoilerFree && prefs.preferencesKnown }
        XCTAssertTrue(learned, "the newer answer: spoiler-free")
        await backdrop.value
        XCTAssertTrue(prefs.preferences.spoilerFree, "the older answer changed nothing")
        XCTAssertTrue(prefs.hidesSpoilers)
    }
}
