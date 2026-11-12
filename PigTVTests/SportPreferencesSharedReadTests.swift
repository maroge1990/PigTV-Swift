import XCTest
@testable import PigTV

/// A server that counts the preferences requests and can hold a preferences answer until the test releases it, with the
/// front page's and the NFL page's own answers.
private final class CountingPreferencesRoutes: URLProtocol, @unchecked Sendable {
    struct Reply { var spoilerFree = false; var status = 200; var held = false }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var otherwise = Reply()
    nonisolated(unsafe) private static var gets = 0
    nonisolated(unsafe) private static var held: [CountingPreferencesRoutes] = []
    private var stopped = false
    private var pending: (() -> Void)?

    static func reset(script: [Reply] = [], otherwise: Reply = Reply()) {
        lock.withLock {
            self.script = script
            self.otherwise = otherwise
            gets = 0
            held = []
        }
    }
    static func then(_ replies: [Reply], otherwise: Reply = Reply()) {
        lock.withLock { script = replies; self.otherwise = otherwise }
    }
    static var getCount: Int { lock.withLock { gets } }
    static var heldCount: Int { lock.withLock { held.count } }
    static func resetCount() { lock.withLock { gets = 0 } }

    /// Answers the oldest held request; false when none is held.
    @discardableResult
    static func releaseOldest() -> Bool {
        let next: CountingPreferencesRoutes? = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        guard let next else { return false }
        let send: (() -> Void)? = lock.withLock { next.stopped ? nil : next.pending }
        send?()
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func fixture(_ name: String) -> Data {
        let url = Bundle(for: CountingPreferencesRoutes.self).urls(forResourcesWithExtension: "json", subdirectory: nil)?.first { $0.lastPathComponent == name }
        return url.flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
    }

    private static func preferences(spoilerFree: Bool) -> Data {
        Data(#"{"spoilerFree":\#(spoilerFree),"sports":["NFL"],"teams":{},"following":{"F1":null,"NFL":"GB"}}"#.utf8)
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var reply = Reply()
        let body: Data
        if path.hasSuffix("sports/pages/preferences") {
            Self.lock.lock()
            Self.gets += 1
            reply = Self.script.isEmpty ? Self.otherwise : Self.script.removeFirst()
            Self.lock.unlock()
            body = Self.preferences(spoilerFree: reply.spoilerFree)
        } else if path.hasSuffix("sports/front") { body = Self.fixture("sport-front-0381.json") }
        else if path.hasSuffix("sports/pages/nfl") { body = Self.fixture("nfl-page-0379.json") }
        else { body = Data(#"{"available":false}"#.utf8) }
        let status = reply.status
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? body : Data(#"{"error":"down"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.held {
            Self.lock.withLock { pending = send; Self.held.append(self) }
        } else {
            send()
        }
    }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
}

/// What the askers did, read by the test between their suspensions.
@MainActor
private final class Askers {
    var started = 0
    var done = 0
    var hidden: [Bool] = []
}

// #278 (audit F5): a sport page runs two pollers (the front page and its league), and each asked for the household's
// preferences on every tick, so two requests went out and one answer was thrown away. Askers that arrive while a read is
// in flight now share it, but only while it is fresh for them: a read that began before an invalidation never answers for
// an asker after it, and none answers during a Hide scores change (fail closed, never stale).
@MainActor
final class SportPreferencesSharedReadTests: XCTestCase {
    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingPreferencesRoutes.self]
        return APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", session: URLSession(configuration: configuration))
    }

    private func makePreferences(_ client: APIClient) -> F1PageModel {
        F1PageModel(client: client)
    }

    private func waitFor(_ seconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Answers every held request until `done`, then waits for it (the old code holds one request per asker).
    private func releaseUntil(_ done: @MainActor () -> Bool) async -> Bool {
        await waitFor(10) {
            CountingPreferencesRoutes.releaseOldest()
            return done()
        }
    }

    /// `count` askers at once, each recording whether the scores were hidden when it returned.
    private func concurrentAskers(_ count: Int, script: CountingPreferencesRoutes.Reply) async throws -> (gets: Int, hidden: [Bool], prefs: F1PageModel) {
        CountingPreferencesRoutes.reset(otherwise: script)
        let prefs = makePreferences(try makeClient())
        let seen = Askers()
        var askers: [Task<Void, Never>] = []
        for _ in 0..<count {
            askers.append(Task { @MainActor in
                seen.started += 1
                await prefs.revalidatePreferences()
                seen.hidden.append(prefs.hidesSpoilers)
            })
        }
        // Every asker has run up to its wait (they run on the main actor, and this test only resumes when they suspend).
        let allStarted = await waitFor { seen.started == count }
        XCTAssertTrue(allStarted)
        let arrived = await waitFor { CountingPreferencesRoutes.heldCount >= 1 }
        XCTAssertTrue(arrived, "the read reached the server")
        XCTAssertTrue(seen.hidden.isEmpty, "no asker returns before the answer")
        let finished = await releaseUntil { seen.hidden.count == count }
        XCTAssertTrue(finished, "every asker returned once the answer came")
        for asker in askers { await asker.value }
        return (CountingPreferencesRoutes.getCount, seen.hidden, prefs)
    }

    func testTwoConcurrentAskersShareOneRead() async throws {
        let result = try await concurrentAskers(2, script: .init(spoilerFree: false, held: true))
        XCTAssertEqual(result.gets, 1, "two askers at once send one preferences request")
        XCTAssertEqual(result.hidden, [false, false], "both return with the answer: the scores shown")
        XCTAssertTrue(result.prefs.preferencesKnown)
    }

    func testFiveConcurrentAskersShareOneRead() async throws {
        let result = try await concurrentAskers(5, script: .init(spoilerFree: true, held: true))
        XCTAssertEqual(result.gets, 1, "five askers at once send one preferences request")
        XCTAssertEqual(result.hidden, Array(repeating: true, count: 5))
        XCTAssertTrue(result.prefs.preferencesKnown)
        XCTAssertTrue(result.prefs.preferences.spoilerFree, "every asker sees the one answer: spoiler-free")
    }

    func testAFailedSharedReadFailsEveryAskerClosed() async throws {
        let result = try await concurrentAskers(3, script: .init(status: 500, held: true))
        XCTAssertEqual(result.gets, 1, "one request, failed")
        XCTAssertEqual(result.hidden, [true, true, true], "every asker: the choice unknown, the scores hidden")
        XCTAssertFalse(result.prefs.preferencesKnown)
        XCTAssertTrue(result.prefs.hidesSpoilers)
    }

    /// A real page tick: the Sport front page's poller and the NFL page's, on one preferences model, refreshed together.
    func testAFrontPageAndItsNFLPageTickingTogetherSendOnePreferencesRequest() async throws {
        CountingPreferencesRoutes.reset(otherwise: .init(spoilerFree: false, held: true))
        let client = try makeClient()
        let prefs = makePreferences(client)
        let front = SportFrontModel(client: client)
        let nfl = NFLPageModel(client: client)
        let seen = Askers()
        let frontTick = Task { @MainActor in seen.started += 1; await front.refresh(preferences: prefs); seen.done += 1 }
        let nflTick = Task { @MainActor in seen.started += 1; await nfl.refresh(preferences: prefs); seen.done += 1 }
        let allStarted = await waitFor { seen.started == 2 }
        XCTAssertTrue(allStarted)
        let arrived = await waitFor { CountingPreferencesRoutes.heldCount >= 1 }
        XCTAssertTrue(arrived)
        XCTAssertNil(nfl.page, "the NFL page waits for the preferences before it publishes")
        let finished = await releaseUntil { seen.done == 2 }
        XCTAssertTrue(finished)
        await frontTick.value
        await nflTick.value
        XCTAssertEqual(CountingPreferencesRoutes.getCount, 1, "one preferences request for the two pollers' tick")
        XCTAssertNotNil(front.front)
        XCTAssertNotNil(nfl.page)
        XCTAssertFalse(prefs.hidesSpoilers)
    }

    func testTicksOneAfterAnotherEachAsk() async throws {
        CountingPreferencesRoutes.reset(otherwise: .init(spoilerFree: false))
        let prefs = makePreferences(try makeClient())
        await prefs.revalidatePreferences()
        await prefs.revalidatePreferences()
        XCTAssertEqual(CountingPreferencesRoutes.getCount, 2, "not a cache: each tick asks")
        XCTAssertFalse(prefs.hidesSpoilers)
    }

    /// The case to protect: Hide scores turned on in Settings while a poll's read is in flight. The bridge invalidates and
    /// asks again; the old read's answer (scores shown) must neither answer the new asker nor apply.
    func testAReadFromBeforeAnInvalidationNeverAnswersALaterAsker() async throws {
        CountingPreferencesRoutes.reset(otherwise: .init(spoilerFree: false))
        let prefs = makePreferences(try makeClient())
        await prefs.revalidatePreferences()
        XCTAssertFalse(prefs.hidesSpoilers)
        CountingPreferencesRoutes.resetCount()
        CountingPreferencesRoutes.then([.init(spoilerFree: false, held: true), .init(spoilerFree: true, held: true)])

        let poll = Task { @MainActor in await prefs.revalidatePreferences() }
        let pollAsked = await waitFor { CountingPreferencesRoutes.heldCount == 1 }
        XCTAssertTrue(pollAsked)
        prefs.invalidatePreferences()
        XCTAssertTrue(prefs.hidesSpoilers, "hidden from the invalidation on")
        let seen = Askers()
        let bridge = Task { @MainActor in await prefs.revalidatePreferences(); seen.done += 1 }
        let bridgeAsked = await waitFor { CountingPreferencesRoutes.getCount == 2 }
        XCTAssertTrue(bridgeAsked, "the later asker sends its own read")

        CountingPreferencesRoutes.releaseOldest()   // the old read: scores shown
        await poll.value
        XCTAssertEqual(seen.done, 0, "the old answer does not answer the later asker")
        XCTAssertTrue(prefs.hidesSpoilers, "still hidden: the old answer changed nothing")
        XCTAssertFalse(prefs.preferencesKnown)

        CountingPreferencesRoutes.releaseOldest()   // the new read: spoiler-free
        await bridge.value
        XCTAssertEqual(CountingPreferencesRoutes.getCount, 2)
        XCTAssertTrue(prefs.preferencesKnown)
        XCTAssertTrue(prefs.preferences.spoilerFree, "ends with the new value")
        XCTAssertTrue(prefs.hidesSpoilers)
    }

    /// #278 (audit D5): a Hide scores change begun while a read is in flight: neither that read nor one asked during the
    /// change makes the choice known; once it ends, a new read does, with the server's value.
    func testNoReadMakesTheChoiceKnownWhileAChangeIsOnItsWay() async throws {
        CountingPreferencesRoutes.reset(otherwise: .init(spoilerFree: false))
        let prefs = makePreferences(try makeClient())
        await prefs.revalidatePreferences()
        CountingPreferencesRoutes.resetCount()
        CountingPreferencesRoutes.then([.init(spoilerFree: false, held: true), .init(spoilerFree: false, held: true)],
                                       otherwise: .init(spoilerFree: true))

        let poll = Task { @MainActor in await prefs.revalidatePreferences() }
        let pollAsked = await waitFor { CountingPreferencesRoutes.heldCount == 1 }
        XCTAssertTrue(pollAsked)
        prefs.beginChange()
        XCTAssertTrue(prefs.hidesSpoilers, "hidden from the press on")
        let later = Task { @MainActor in await prefs.revalidatePreferences() }
        let laterAsked = await waitFor(3) { CountingPreferencesRoutes.getCount == 2 }
        XCTAssertTrue(laterAsked, "an asker during the change sends its own read")
        let finished = await releaseUntil { CountingPreferencesRoutes.heldCount == 0 }
        XCTAssertTrue(finished)
        await poll.value
        await later.value
        XCTAssertFalse(prefs.preferencesKnown, "neither answer (scores shown) applies while the change is on its way")
        XCTAssertTrue(prefs.hidesSpoilers)
        await prefs.endChange()
        XCTAssertEqual(CountingPreferencesRoutes.getCount, 3, "the end of the change asks again")
        XCTAssertTrue(prefs.preferencesKnown)
        XCTAssertTrue(prefs.preferences.spoilerFree, "the server's value after the change")
    }

    /// The page went away: its only asker cancelled ends the request, and the choice is left unknown (as before sharing).
    func testTheLastAskerCancelledEndsTheReadClosed() async throws {
        CountingPreferencesRoutes.reset(otherwise: .init(spoilerFree: false))
        let prefs = makePreferences(try makeClient())
        await prefs.revalidatePreferences()
        CountingPreferencesRoutes.then([.init(spoilerFree: false, held: true)])
        prefs.invalidatePreferences()
        let seen = Askers()
        let asker = Task { @MainActor in await prefs.revalidatePreferences(); seen.done += 1 }
        let asked = await waitFor { CountingPreferencesRoutes.heldCount == 1 }
        XCTAssertTrue(asked)
        asker.cancel()
        let ended = await waitFor { seen.done == 1 }
        XCTAssertTrue(ended, "the cancelled asker returns without the answer")
        XCTAssertTrue(prefs.hidesSpoilers)
        CountingPreferencesRoutes.releaseOldest()
    }
}
