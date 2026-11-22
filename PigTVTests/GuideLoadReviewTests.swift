import XCTest
@testable import PigTV

/// Codex review of Apple 383-385 (one high, three mediums), Apple 386. Each test fails on 385.
/// 1 (high): a staged refresh moved `window` and `guideLoadedUntil` before its pages came; a failed page then let the next
///   pass mark the old rows fresh against the new day. Now the day, its edge, the version and the rows change together.
/// 2: a freshness pass while a staged refresh was still paging restarted it; now it is joined, and a stopped one resumes.
/// 3: two overlapping resets both went on under the newer generation; now only the newest proceeds, with its own version.
/// 4: the small first page could be exported to the Top Shelf; now the snapshot builder never uses it.
@MainActor
final class GuideLoadReviewTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        ReviewServer.reset()
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-review-\(UUID().uuidString)")
    }

    override func tearDown() {
        ReviewServer.reset()
        BrowseModel.guidePageRetryDelaysOverride = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func model() throws -> BrowseModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewServer.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = BrowseModel(client: client, guideCacheDirectory: cacheDirectory)
        m.publishesTopShelf = false
        return m
    }

    private func eventually(_ seconds: Double = 15, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private var today: Date { GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn) }

    /// A guide whose day no longer covers the next 12 hours (so a refresh is due even with the version unchanged).
    private func loadedOldGuide() async throws -> BrowseModel {
        let m = try model()
        m.window = today.addingTimeInterval(-13 * 3600)
        await m.loadGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertEqual(m.guide.count, 1250)
        return m
    }

    // MARK: 1 (high)

    func testAFailedStagedRefreshLeavesTheOldDayAndTheNextPassLoadsInsteadOfMarkingFresh() async throws {
        BrowseModel.guidePageRetryDelaysOverride = []
        let m = try await loadedOldGuide()
        let oldWindow = m.window, oldUntil = m.guideLoadedUntil, oldLoadedAt = m.guideLoadedAt
        let oldRows = m.guide.map(\.programmes)
        ReviewServer.failCursor = "500" // the refresh's page 2; the server version stays "review-1"
        await m.refreshGuideIfStale(maxAge: 0)
        try await eventually { !m.guidePagingActive }
        XCTAssertNotNil(m.guideError)
        XCTAssertEqual(m.window, oldWindow, "the day moves only with its rows")
        XCTAssertEqual(m.guideLoadedUntil, oldUntil)
        XCTAssertEqual(m.guideLoadedAt, oldLoadedAt)
        XCTAssertEqual(m.guide.map(\.programmes), oldRows)
        // The next pass: the version is unchanged, but the guide on screen does not cover the next 12 hours: it must load.
        ReviewServer.failCursor = nil
        let asked = ReviewServer.guideRequests
        await m.refreshGuideIfStale(maxAge: 0)
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertGreaterThan(ReviewServer.guideRequests, asked, "not marked fresh: the pass loaded")
        XCTAssertNil(m.guideError)
        XCTAssertEqual(m.window, today)
        XCTAssertEqual(m.guideLoadedUntil, today.addingTimeInterval(GuideNavigation.loadedDuration))
        XCTAssertEqual(m.guide[1249].programmes, ProductionGuideFixture.channels(count: 1250, window: today)[1249].programmes)
    }

    // MARK: 2

    func testAFreshnessPassDuringAStagedRefreshJoinsItAndAStoppedOneResumes() async throws {
        let m = try await loadedOldGuide()
        ReviewServer.version = "review-2"
        ReviewServer.holdCursor = "500"
        await m.refreshGuideIfStale(maxAge: 0)
        try await eventually { ReviewServer.held }
        let asked = ReviewServer.guideRequests // 3 for the load, 2 so far for the refresh
        await m.refreshGuideIfStale(maxAge: 0) // the minute's pass while page 2 is in flight
        XCTAssertEqual(ReviewServer.guideRequests, asked, "the pass joined the paging, asking nothing")
        ReviewServer.holdCursor = nil
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertEqual(ReviewServer.guideRequests, 6, "the refresh was never restarted")
        XCTAssertEqual(m.window, today)
        XCTAssertEqual(m.guideCacheVersion, "review-2")

        // A refresh stopped by a failed page: the next pass resumes from its cursor (page 2, then 3), not from page 1.
        BrowseModel.guidePageRetryDelaysOverride = []
        let again = try await loadedOldGuide()
        ReviewServer.version = "review-3"
        ReviewServer.failCursor = "500"
        let before = ReviewServer.guideRequests
        await again.refreshGuideIfStale(maxAge: 0)
        try await eventually { !again.guidePagingActive }
        XCTAssertNotNil(again.guideError)
        ReviewServer.failCursor = nil
        await again.refreshGuideIfStale(maxAge: 0)
        try await eventually { !again.guidePagingActive && !again.guideHasMore }
        XCTAssertEqual(ReviewServer.guideRequests - before, 2 + 2, "page 1, page 2 failed; then page 2 and page 3")
        XCTAssertEqual(again.guideCacheVersion, "review-3")
        XCTAssertEqual(again.window, today)
    }

    // MARK: 3

    func testOverlappingResetsLetOnlyTheNewestProceedWithItsOwnVersion() async throws {
        let m = try model()
        m.window = today
        ReviewServer.holdFirstVersion = true
        ReviewServer.versions = ["review-old", "review-new"]
        let first = Task { await m.loadGuide() }
        try await eventually { ReviewServer.versionRequests == 1 }
        let second = Task { await m.loadGuide() } // its version is answered at once
        await second.value
        ReviewServer.holdFirstVersion = false // the first load's version answer arrives last
        await first.value
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ReviewServer.guideRequests, 3, "one load paged the guide")
        XCTAssertEqual(m.guideCacheVersion, "review-new", "the load that proceeded committed its own version")
        XCTAssertEqual(m.guide.count, 1250)
    }

    // MARK: 4

    func testTheSmallFirstPageIsNeverExportedToTheTopShelf() async throws {
        let m = try model()
        BrowseModel.guidePageRetryDelaysOverride = []
        ReviewServer.holdFullPages = true
        ReviewServer.failFullPages = true // an answer is made when its request arrives: this held one will fail
        let launch = Task { await m.loadInitialGuide() }
        try await eventually { !m.guide.isEmpty }
        XCTAssertTrue(m.guideIsPreview)
        XCTAssertNil(m.topShelfSnapshot(), "nothing is built from the small page")
        // A favourite on the small page: its entry comes from the favourites answer's own slots, not the small page.
        let row = m.guide[2]
        let mine = Channel(rawID: row.rawID, sourceId: row.sourceId, name: row.name, logo: nil, category: nil,
                           now: nil, next: nil, stableId: row.stableId)
        m.favourites = [mine]
        XCTAssertEqual(m.topShelfSnapshot()?.channels.first?.programmes.count, 0, "the favourite's own (empty) slots")
        m.favourites = []
        // The full load fails: still nothing built (an earlier snapshot is left as it was).
        ReviewServer.holdFullPages = false
        await launch.value
        try await eventually { !m.guideBusy }
        XCTAssertNil(m.topShelfSnapshot())
        // After a successful load the normal snapshot is built from the full guide.
        ReviewServer.failFullPages = false
        await m.retryGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        let built = try XCTUnwrap(m.topShelfSnapshot())
        XCTAssertEqual(built.kind, "channels")
        XCTAssertEqual(built.channels.first?.id, m.guide.first?.rawID)
        XCTAssertFalse(built.channels.first?.programmes.isEmpty ?? true)
    }

    // MARK: Review of 386 (mediums)

    /// A freshness pass awaiting its version answer while the user jumps to another day: the late answer must not start a
    /// reset that cancels the jump's paging (the viewport on the jumped-to day with rows of today). Fails on 386.
    func testAFreshnessAnswerArrivingAfterAJumpLeavesTheJumpsLoadAlone() async throws {
        let m = try await loadedOldGuide() // version request 0
        ReviewServer.version = "review-2" // changed: the old pass will want a reload
        ReviewServer.holdVersionIndex = 1
        let pass = Task { await m.refreshGuideIfStale(maxAge: 0) }
        try await eventually { ReviewServer.versionRequests == 2 && ReviewServer.held }
        // Jump to… tomorrow (GuideView's needsReload): its own reset, with its page 2 held so it is still paging.
        let jumpDay = today.addingTimeInterval(24 * 3600)
        ReviewServer.holdCursor = "500"
        m.window = jumpDay
        let jump = Task { await m.loadGuide(keepVisible: true) }
        try await eventually { ReviewServer.versionRequests == 3 && ReviewServer.guideRequests == 3 + 2 }
        ReviewServer.holdVersionIndex = nil // the freshness pass's answer arrives now, late, while the jump pages
        try await Task.sleep(for: .milliseconds(300))
        ReviewServer.holdCursor = nil // (on 386 the pass's own staged load would wait here for its page 2 too)
        await pass.value
        await jump.value
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ReviewServer.guideRequests, 3 + 3, "only the jump's load paged after the setup")
        XCTAssertEqual(m.window, jumpDay, "the jump's day stays")
        XCTAssertEqual(m.guide.count, 1250)
        XCTAssertEqual(m.guide[1249].programmes, ProductionGuideFixture.channels(count: 1250, window: jumpDay)[1249].programmes,
                       "rows of the jumped-to day")
    }

    /// Review of 387-388 (medium): a launch from the saved guide awaits its version answer; meanwhile the user jumps to
    /// another day. The late (changed) answer must not make the launch start its own reset, which took the jump's
    /// generation, threw its pending first page away and fetched page one again. Fails on 388.
    func testALateCachedVersionAnswerLeavesAJumpsPendingFirstPageAlone() async throws {
        // A saved guide for today (the first model's full load saves it).
        let saver = try model()
        saver.window = today
        await saver.loadGuide() // version request 0
        try await eventually { !saver.guidePagingActive && !saver.guideHasMore }
        try await eventually { !((try? FileManager.default.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.isEmpty }
        let m = try model()
        ReviewServer.version = "review-2" // changed: the saved guide is not marked fresh
        ReviewServer.holdVersionIndex = 1 // the launch's version check of its saved guide
        let launch = Task { await m.loadInitialGuide() }
        try await eventually { ReviewServer.versionRequests == 2 && !m.guide.isEmpty }
        XCTAssertTrue(m.fromCache)
        // Jump to… tomorrow, its first page held.
        let asked = ReviewServer.guideRequests
        let jumpDay = today.addingTimeInterval(24 * 3600)
        ReviewServer.holdFullPages = true
        m.window = jumpDay
        let jump = Task { await m.loadGuide(keepVisible: true) }
        try await eventually { ReviewServer.guideRequests == asked + 1 }
        ReviewServer.holdVersionIndex = nil // the saved guide's answer arrives now, late
        try await Task.sleep(for: .milliseconds(300))
        ReviewServer.holdFullPages = false
        await launch.value
        await jump.value
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ReviewServer.guideRequests - asked, 3, "only the jump fetched its pages (page one once)")
        XCTAssertEqual(m.window, jumpDay)
        XCTAssertEqual(m.guide[1249].programmes, ProductionGuideFixture.channels(count: 1250, window: jumpDay)[1249].programmes)
    }

    /// The Top Shelf's card logos during the launch's small first page: a favourite with a different logo from its preview
    /// row draws its own (the snapshot already uses its own slots). Fails on 386 (the preview row's logo).
    func testTopShelfLogosNeverComeFromTheSmallFirstPage() async throws {
        let m = try model()
        BrowseModel.guidePageRetryDelaysOverride = []
        ReviewServer.holdFullPages = true
        let launch = Task { await m.loadInitialGuide() }
        try await eventually { !m.guide.isEmpty }
        XCTAssertTrue(m.guideIsPreview)
        let row = m.guide[2]
        let rowLogo = try XCTUnwrap(m.logo(for: row))
        let mine = Channel(rawID: row.rawID, sourceId: row.sourceId, name: row.name, logo: "/api/logo/favourite-own",
                           category: nil, now: nil, next: nil, stableId: row.stableId)
        m.favourites = [mine]
        let snapshot = try XCTUnwrap(m.topShelfSnapshot())
        let sources = m.topShelfLogoSources(for: snapshot)
        XCTAssertNotEqual(sources[mine.id], rowLogo, "the preview row's logo")
        XCTAssertEqual(sources[mine.id], "/api/logo/favourite-own")
        // Once the full guide is on screen, the guide row's logo is used again (as before).
        ReviewServer.holdFullPages = false
        await launch.value
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertFalse(m.guideIsPreview)
        let full = try XCTUnwrap(m.topShelfSnapshot())
        XCTAssertEqual(m.topShelfLogoSources(for: full)[mine.id], m.guideChannel(id: mine.id).flatMap { m.logo(for: $0) })
        m.favourites = []
    }
}

/// `ProductionGuideFixture`'s guide (1,250 channels, pages of 500) with a version that can change (or answer in turn,
/// the first held back), a page that can fail or be held by its cursor, and the full pages (limit 500) held or failed.
private final class ReviewServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var versionAsks = 0
    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) static var version = "review-1"
    nonisolated(unsafe) static var versions: [String] = []
    nonisolated(unsafe) static var holdFirstVersion = false
    /// The version request with this index (0 = the first since `reset`) is held until this is nil again.
    nonisolated(unsafe) static var holdVersionIndex: Int?
    nonisolated(unsafe) static var failCursor: String?
    nonisolated(unsafe) static var holdCursor: String?
    nonisolated(unsafe) static var holdFullPages = false
    nonisolated(unsafe) static var failFullPages = false

    static var guideRequests: Int { lock.withLock { requests } }
    static var versionRequests: Int { lock.withLock { versionAsks } }
    static var held: Bool { lock.withLock { holding } }
    static func reset() {
        lock.withLock { requests = 0; versionAsks = 0; holding = false }
        version = "review-1"; versions = []; holdFirstVersion = false; holdVersionIndex = nil; failCursor = nil; holdCursor = nil
        holdFullPages = false; failFullPages = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200
        var body = Data(#"{"error":"not found"}"#.utf8)
        var wait: () -> Bool = { false }
        if url.path == "/api/library/guide/version" {
            let index = Self.lock.withLock { () -> Int in Self.versionAsks += 1; return Self.versionAsks - 1 }
            let answer = index < Self.versions.count ? Self.versions[index] : Self.version
            body = Data(#"{"version":"\#(answer)"}"#.utf8)
            if index == 0 && !Self.versions.isEmpty { wait = { Self.holdFirstVersion } }
            if index == Self.holdVersionIndex { wait = { Self.holdVersionIndex != nil } }
        } else if url.path == "/api/library/guide" {
            Self.lock.withLock { Self.requests += 1 }
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value }
            let full = query["limit"] == "500"
            if let fail = Self.failCursor, query["cursor"] == fail {
                status = 500
                body = Data(#"{"error":"down"}"#.utf8)
            } else if full && Self.failFullPages {
                status = 500
                body = Data(#"{"error":"down"}"#.utf8)
            } else {
                body = ProductionGuideFixture.pageJSON(query: query, total: 1250)
            }
            if let hold = Self.holdCursor, query["cursor"] == hold { wait = { Self.holdCursor != nil } }
            if full && Self.holdFullPages { wait = { Self.holdFullPages } }
        } else {
            status = 404
        }
        let answer = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        guard wait() else { answer(); return }
        DispatchQueue.global().async {
            Self.lock.withLock { Self.holding = true }
            while wait() { usleep(5000) }
            Self.lock.withLock { Self.holding = false }
            answer()
        }
    }
    override func stopLoading() {}
}
