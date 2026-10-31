import XCTest
import Combine
@testable import PigTV

/// A server for the NFL and F1 pages whose preferences answer can be delayed or fail, and whose page answer moves on
/// (`updatedAt` + `revision` ms) between loads.
private final class SportPageSpoilerRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var spoilerFree = false
    nonisolated(unsafe) static var preferencesStatus = 200
    nonisolated(unsafe) static var preferencesDelay: TimeInterval = 0
    nonisolated(unsafe) static var revision: Double = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func answer(_ name: String) -> Data {
        let url = Bundle(for: SportPageSpoilerRoutes.self).urls(forResourcesWithExtension: "json", subdirectory: nil)?.first { $0.lastPathComponent == name }
        guard let url, let data = try? Data(contentsOf: url), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Data("{}".utf8) }
        json["updatedAt"] = ((json["updatedAt"] as? Double) ?? 0) + revision
        // F1 has no updatedAt: the weekend's name moves instead.
        if revision > 0, var weekend = json["weekend"] as? [String: Any] { weekend["name"] = "\(weekend["name"] ?? "") \(revision)"; json["weekend"] = weekend }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let preferences = path.hasSuffix("sports/pages/preferences")
        let status = preferences ? Self.preferencesStatus : 200
        let body = preferences ? Data(#"{"spoilerFree":\#(Self.spoilerFree),"following":{"F1":null,"NFL":"GB"}}"#.utf8)
            : path.hasSuffix("sports/pages/nfl") ? Self.answer("nfl-page-0379.json")
            : path.hasSuffix("sports/pages/f1") ? Self.answer("f1-page-0346.json") : Data(#"{"available":false}"#.utf8)
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? body : Data(#"{"error":"down"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if preferences && Self.preferencesDelay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.preferencesDelay, execute: send) } else { send() }
    }
    override func stopLoading() {}
}

// Apple 90 (Codex round 1, high, as CricketPageSpoilerTests): spoiler-free switched on at another device must hide the
// NFL and F1 scores before any new answer is drawn. The NFL page published its answer before asking for the
// preferences; both kept the old choice when the preferences request failed, and drew their cached scores under it
// when opened again.
@MainActor
final class SportPageSpoilerTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func client() throws -> APIClient {
        SportPageSpoilerRoutes.spoilerFree = false
        SportPageSpoilerRoutes.preferencesStatus = 200
        SportPageSpoilerRoutes.preferencesDelay = 0
        SportPageSpoilerRoutes.revision = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SportPageSpoilerRoutes.self]
        return APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
    }

    private func prefsModel(_ client: APIClient) -> F1PageModel {
        F1PageModel(client: client, defaults: UserDefaults(suiteName: "sport-spoilers-\(UUID())")!)
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: NFL

    func testNFLNewScoresAreNeverDrawnBeforeASlowSpoilerFreeAnswer() async throws {
        let c = try client()
        let model = NFLPageModel(client: c), prefs = prefsModel(c)
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers)
        SportPageSpoilerRoutes.spoilerFree = true
        SportPageSpoilerRoutes.preferencesDelay = 1.5
        SportPageSpoilerRoutes.revision = 1000
        let first = model.page?.updatedAt
        var drawnUnredacted: [Bool] = []
        model.$page.dropFirst().sink { page in if page?.updatedAt != first { drawnUnredacted.append(!prefs.hidesSpoilers) } }.store(in: &cancellables)
        await model.refresh(preferences: prefs)
        XCTAssertNotEqual(model.page?.updatedAt, first)
        XCTAssertEqual(drawnUnredacted, [false], "the new answer is published only once spoiler-free has answered")
    }

    func testNFLAFailedPreferencesRequestHidesTheScores() async throws {
        let c = try client()
        let model = NFLPageModel(client: c), prefs = prefsModel(c)
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers)
        SportPageSpoilerRoutes.preferencesStatus = 500
        await model.refresh(preferences: prefs)
        XCTAssertTrue(prefs.hidesSpoilers, "the household's choice could not be confirmed: hidden")
        SportPageSpoilerRoutes.preferencesStatus = 200
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers, "shown again once it answers")
    }

    func testNFLAPageOpenedAgainHidesItsCachedScoresUntilThePreferencesAnswer() async throws {
        let c = try client()
        let model = NFLPageModel(client: c), prefs = prefsModel(c)
        await model.refresh(preferences: prefs)
        XCTAssertFalse(prefs.hidesSpoilers)
        SportPageSpoilerRoutes.spoilerFree = true
        SportPageSpoilerRoutes.preferencesDelay = 2
        let visit = Task { await model.keepFresh(preferences: prefs) }
        defer { visit.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(prefs.hidesSpoilers, "reopened: hidden while the preferences are asked again")
        let answered = await waitFor(5) { prefs.preferences.spoilerFree }
        XCTAssertTrue(answered)
    }

    // MARK: F1 (the page model holds the preferences itself)

    func testF1NewScoresAreNeverDrawnBeforeASlowSpoilerFreeAnswer() async throws {
        let model = prefsModel(try client())
        await model.load()
        XCTAssertFalse(model.hidesSpoilers)
        SportPageSpoilerRoutes.spoilerFree = true
        SportPageSpoilerRoutes.preferencesDelay = 1.5
        SportPageSpoilerRoutes.revision = 1000
        let first = model.page?.weekend?.name
        var drawnUnredacted: [Bool] = []
        model.$page.dropFirst().sink { page in if page?.weekend?.name != first { drawnUnredacted.append(!model.hidesSpoilers) } }.store(in: &cancellables)
        await model.load()
        XCTAssertNotEqual(model.page?.weekend?.name, first)
        XCTAssertEqual(drawnUnredacted, [false])
    }

    func testF1AFailedPreferencesRequestHidesTheScores() async throws {
        let model = prefsModel(try client())
        await model.load()
        XCTAssertFalse(model.hidesSpoilers)
        SportPageSpoilerRoutes.preferencesStatus = 500
        await model.load()
        XCTAssertTrue(model.hidesSpoilers, "the household's choice could not be confirmed: hidden")
        SportPageSpoilerRoutes.preferencesStatus = 200
        await model.load()
        XCTAssertFalse(model.hidesSpoilers, "shown again once it answers")
    }

    func testF1APageOpenedAgainHidesItsCachedScoresUntilThePreferencesAnswer() async throws {
        let model = prefsModel(try client())
        await model.load()
        XCTAssertFalse(model.hidesSpoilers)
        XCTAssertNotNil(model.page)
        SportPageSpoilerRoutes.spoilerFree = true
        SportPageSpoilerRoutes.preferencesDelay = 2
        let visit = Task { await model.keepFresh() }
        defer { visit.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.hidesSpoilers, "reopened: hidden while the preferences are asked again")
        let answered = await waitFor(5) { model.preferences.spoilerFree }
        XCTAssertTrue(answered)
    }
}
