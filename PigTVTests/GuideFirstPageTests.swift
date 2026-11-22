import XCTest
@testable import PigTV

/// #360/#361 (C1, Apple 383): a launch with no usable saved guide asks first for a small page (the first 50 channels, the
/// window's first 6 hours: about 30 KB on the real guide against about 975 KB for 500 channels and 24 hours), shows it,
/// then fetches the full guide behind it exactly as before; the full guide's first page replaces the small one. The
/// small page is never saved, never commits the guide version and never moves `guideLoadedUntil`.
/// Before 383 the first request was the full page (limit 500, 24 h): the first two tests fail there.
@MainActor
final class GuideFirstPageTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        FirstPageServer.reset()
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-first-page-\(UUID().uuidString)")
    }

    override func tearDown() {
        FirstPageServer.reset()
        BrowseModel.guidePageRetryDelaysOverride = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func model(directory: URL? = nil) throws -> BrowseModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstPageServer.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let model = BrowseModel(client: client, guideCacheDirectory: directory ?? cacheDirectory)
        model.publishesTopShelf = false
        return model
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func cacheFiles(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// The saved guide once it is complete on disk (an atomic write's temporary file is not it).
    private func saved(_ directory: URL) -> GuideCache? {
        cacheFiles(directory).lazy.filter { $0.lastPathComponent.hasPrefix("guide-v") && $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(GuideCache.self, from: Data(contentsOf: $0)) }.first
    }

    func testAColdLaunchAsksFirstForFiftyChannelsAndSixHoursAndShowsThem() async throws {
        FirstPageServer.holdFullPages = true
        let m = try model()
        let launch = Task { await m.loadInitialGuide() }
        try await eventually { !m.guide.isEmpty }
        let pages = FirstPageServer.guideQueries
        let first = try XCTUnwrap(pages.first, "a guide page was asked for")
        XCTAssertEqual(first["limit"], "50", "the first guide request is the small page")
        let start = try XCTUnwrap(first["start"].flatMap(Double.init)), end = try XCTUnwrap(first["end"].flatMap(Double.init))
        XCTAssertEqual(end - start, 6 * 3600 * 1000, "its window is 6 hours")
        XCTAssertEqual(start, m.window.timeIntervalSince1970 * 1000, "from the guide's window (the lead-in included)")
        XCTAssertNil(first["cursor"])
        // Its rows are on screen while the full guide is still on its way.
        XCTAssertEqual(m.guide.count, 50)
        XCTAssertEqual(m.guideTotal, 620)
        let sixHours = m.window.addingTimeInterval(6 * 3600)
        XCTAssertTrue(m.guide.allSatisfy { $0.programmes.allSatisfy { $0.start < sixHours } })
        XCTAssertTrue(m.guideBusy, "the Guide still counts as loading (no extension, no refresh, no Top Shelf from it)")
        XCTAssertFalse(m.guideHasMore)
        XCTAssertNil(m.guideLoadedAt)
        XCTAssertEqual(m.guideLoadedUntil, m.window.addingTimeInterval(GuideNavigation.loadedDuration),
                       "the loaded edge stays where the load put it: a scroll right past 6 hours triggers no reload or extension")
        // Never saved.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(cacheFiles(cacheDirectory), [], "the small page is never saved")
        // The full guide behind it: limit 500, 24 h, from the top.
        FirstPageServer.holdFullPages = false
        await launch.value
        try await eventually { !m.guidePagingActive }
        let full = FirstPageServer.guideQueries.dropFirst()
        XCTAssertEqual(full.map { $0["limit"] }, ["500", "500"])
        XCTAssertEqual(full.map { $0["cursor"] }, [nil, "500"])
        XCTAssertTrue(full.allSatisfy { $0["start"] == first["start"] })
        XCTAssertTrue(full.allSatisfy { Double($0["end"] ?? "") == start + GuideNavigation.loadedDuration * 1000 })
        XCTAssertEqual(m.guide.count, 620)
    }

    func testTheEndStateIsTheOldLoadsEndState() async throws {
        let directoryOld = cacheDirectory.appendingPathComponent("old"), directoryNew = cacheDirectory.appendingPathComponent("new")
        let fresh = try model(directory: directoryNew)
        await fresh.loadInitialGuide()
        try await eventually { !fresh.guidePagingActive && !fresh.guideHasMore }
        XCTAssertEqual(FirstPageServer.guideQueries.first?["limit"], "50", "the new path asked for the small page first")

        FirstPageServer.reset()
        let old = try model(directory: directoryOld)
        old.window = fresh.window
        await old.loadGuide(reset: true) // the load as it was: no small page
        try await eventually { !old.guidePagingActive && !old.guideHasMore }
        XCTAssertEqual(FirstPageServer.guideQueries.first?["limit"], "500")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(fresh.guide), try encoder.encode(old.guide), "the same channels, order and programmes")
        XCTAssertEqual(fresh.guide.count, 620)
        XCTAssertEqual(fresh.window, old.window)
        XCTAssertEqual(fresh.guideLoadedUntil, old.guideLoadedUntil)
        XCTAssertEqual(fresh.guideTotal, old.guideTotal)
        XCTAssertEqual(fresh.guideHasMore, old.guideHasMore)
        XCTAssertEqual(fresh.guideEnded, old.guideEnded)
        XCTAssertEqual(fresh.fromCache, old.fromCache)
        XCTAssertNil(fresh.guideError)
        XCTAssertNotNil(fresh.guideLoadedAt)
        // The saved guide: the same day, channels and committed version.
        try await eventually { self.saved(directoryNew) != nil && self.saved(directoryOld) != nil }
        let savedNew = try XCTUnwrap(saved(directoryNew)), savedOld = try XCTUnwrap(saved(directoryOld))
        XCTAssertEqual(try encoder.encode(savedNew.channels), try encoder.encode(savedOld.channels))
        XCTAssertEqual(savedNew.window, savedOld.window)
        XCTAssertEqual(savedNew.version, "first-page-1")
        XCTAssertEqual(savedNew.version, savedOld.version)
    }

    /// The full guide's first page fails after the small page was shown: the error shows on its own, as before 383 (the
    /// small rows are not left standing in for a guide), and nothing is saved.
    func testASmallPageIsNeverSavedAndDoesNotOutliveAFailedLoad() async throws {
        BrowseModel.guidePageRetryDelaysOverride = []
        FirstPageServer.failFullPages = true
        let m = try model()
        await m.loadInitialGuide()
        try await eventually { !m.guideBusy }
        XCTAssertEqual(FirstPageServer.guideQueries.first?["limit"], "50")
        XCTAssertNotNil(m.guideError)
        XCTAssertTrue(m.guide.isEmpty, "the failed load shows its error, not the small page")
        XCTAssertEqual(m.guideState, .failed(PageWords.guideFailed))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(cacheFiles(cacheDirectory), [])
        // Try again then loads the whole guide.
        FirstPageServer.failFullPages = false
        await m.retryGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertEqual(m.guide.count, 620)
        XCTAssertNil(m.guideError)
    }

    /// The small page's rows replaced by the full guide with the same channel count (a guide of 50 channels or fewer) still
    /// tells the Guide its rows changed (`guideProgrammesVersion`), or its rows would keep the 6 hours.
    func testASmallGuideStillRedrawsWhenTheFullPageReplacesTheSmallOne() async throws {
        FirstPageServer.total = 30
        let m = try model()
        await m.loadInitialGuide()
        try await eventually { !m.guidePagingActive }
        XCTAssertEqual(m.guide.count, 30)
        XCTAssertEqual(m.guideProgrammesVersion, 1)
        XCTAssertTrue(m.guide.contains { $0.programmes.contains { $0.start >= m.window.addingTimeInterval(6 * 3600) } })
    }

    /// The speed fixture's pages as the app asks for them (1,250 channels): the small first page is under the 300 KB
    /// first-page target (D-80), the full first page far over it.
    func testTheSmallPageIsUnderThreeHundredKilobytesOnTheProductionFixture() {
        let start = ProductionGuideFixture.window(now: Date(timeIntervalSince1970: 1_795_000_000)).timeIntervalSince1970 * 1000
        func bytes(limit: Int, hours: Double) -> Int {
            ProductionGuideFixture.pageJSON(query: ["start": String(Int64(start)), "end": String(Int64(start + hours * 3_600_000)),
                                                    "limit": String(limit)], total: 1250).count
        }
        let small = bytes(limit: GuideNavigation.previewChannels, hours: GuideNavigation.previewDuration / 3600)
        let full = bytes(limit: 500, hours: 24)
        print("GUIDE-FIRST-PAGE fixture bytes: small \(small), full first page \(full)")
        XCTAssertLessThan(small, 300_000)
        XCTAssertGreaterThan(full, 300_000)
    }

    /// With a usable saved guide there is no small page: the saved guide is on screen at once.
    func testASavedGuideIsShownWithoutTheSmallPage() async throws {
        let first = try model()
        await first.loadInitialGuide()
        try await eventually { !first.guidePagingActive && !first.guideHasMore && self.saved(self.cacheDirectory)?.channels.count == 620 }
        FirstPageServer.reset()
        FirstPageServer.version = "first-page-2" // changed: the saved guide is shown, then reloaded behind it
        let second = try model()
        await second.loadInitialGuide()
        try await eventually { !second.guidePagingActive && !second.guideHasMore }
        XCTAssertEqual(FirstPageServer.guideQueries.map { $0["limit"] }, ["500", "500"], "no small page with a saved guide on screen")
    }
}

/// The guide routes, answered from `ProductionGuideFixture` (any limit, window and cursor) and recorded.
private final class FirstPageServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queries: [[String: String]] = []
    nonisolated(unsafe) static var total = 620
    nonisolated(unsafe) static var version = "first-page-1"
    nonisolated(unsafe) static var holdFullPages = false
    nonisolated(unsafe) static var failFullPages = false

    static var guideQueries: [[String: String]] { lock.withLock { queries } }
    static func reset() {
        lock.withLock { queries = [] }
        total = 620; version = "first-page-1"; holdFullPages = false; failFullPages = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200
        var body = Data(#"{"error":"not found"}"#.utf8)
        var wait = false
        if url.path == "/api/library/guide/version" {
            body = Data(#"{"version":"\#(Self.version)"}"#.utf8)
        } else if url.path == "/api/library/guide" {
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value }
            Self.lock.withLock { Self.queries.append(query) }
            let full = query["limit"] != "50"
            wait = full
            if full && Self.failFullPages {
                status = 500
                body = Data(#"{"error":"down"}"#.utf8)
            } else {
                body = ProductionGuideFixture.pageJSON(query: query, total: Self.total)
            }
        } else {
            status = 404
        }
        let answer = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        guard wait else { answer(); return }
        DispatchQueue.global().async {
            while Self.holdFullPages { usleep(5000) }
            answer()
        }
    }
    override func stopLoading() {}
}
