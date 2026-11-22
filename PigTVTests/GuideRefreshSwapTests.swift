import Combine
import XCTest
@testable import PigTV

/// #360 (G6, C2, Apple 384): a stale-guide refresh (`refreshGuideIfStale` → a full reload that keeps the rows on screen)
/// replaced the guide with its first page, so the TV Guide shrank to 500 rows and grew back page by page. Now the rows on
/// screen stay until the whole new guide has arrived, then it is swapped in at once: one change of `guide`, never fewer
/// rows than before. Before 384 the first two tests fail (500 rows mid-refresh, three changes).
@MainActor
final class GuideRefreshSwapTests: XCTestCase {
    private var cacheDirectory: URL!
    private var watching: AnyCancellable?

    override func setUp() {
        super.setUp()
        SwapServer.reset()
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-swap-\(UUID().uuidString)")
    }

    override func tearDown() {
        watching = nil
        SwapServer.reset()
        BrowseModel.guidePageRetryDelaysOverride = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    /// The day before the refresh starts an hour earlier, so the refreshed rows differ from the old ones.
    private var oldWindow: Date { GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn - 3600) }

    private func loadedModel() async throws -> BrowseModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwapServer.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = BrowseModel(client: client, guideCacheDirectory: cacheDirectory)
        m.publishesTopShelf = false
        m.window = oldWindow
        await m.loadGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertEqual(m.guide.count, 1250)
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

    /// Every change of the guide the Guide would see (the store's `guide`), as row counts.
    private func watch(_ m: BrowseModel) -> () -> [Int] {
        var counts: [Int] = []
        watching = m.guideStore.$guide.dropFirst().sink { counts.append($0.count) }
        return { counts }
    }

    func testAStaleRefreshKeepsEveryRowUntilTheNewGuideIsSwappedInOnce() async throws {
        let m = try await loadedModel()
        let before = m.guide.count
        let versionBefore = m.guideProgrammesVersion
        SwapServer.version = "swap-2"
        var seenDuringRequests: [Int] = []
        SwapServer.duringGuidePage = { MainActor.assumeIsolated { seenDuringRequests.append(m.guide.count) } }
        let changes = watch(m)
        await m.refreshGuideIfStale(maxAge: 0)
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        SwapServer.duringGuidePage = nil
        XCTAssertEqual(SwapServer.guideRequests, 6, "three pages for the load, three for the refresh")
        XCTAssertEqual(seenDuringRequests.count, 3)
        XCTAssertTrue(seenDuringRequests.allSatisfy { $0 >= before }, "rows on screen while the refresh's pages came: \(seenDuringRequests)")
        XCTAssertEqual(changes(), [1250], "the new guide reaches the Guide once, whole")
        XCTAssertGreaterThan(m.guideProgrammesVersion, versionBefore, "told as a programme change: the rows keep their count")
        // It is the new day's guide, as a load from scratch would leave it.
        let window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        XCTAssertEqual(m.window, window)
        XCTAssertEqual(m.guide.map(\.rawID), (0..<1250).map { "p\($0)" })
        XCTAssertEqual(m.guide[700].programmes, ProductionGuideFixture.channels(count: 701, window: window)[700].programmes)
        XCTAssertNil(m.guideError)
        XCTAssertFalse(m.fromCache)
        // And saved as such.
        try await eventually {
            guard let data = try? Data(contentsOf: self.cacheFile()),
                  let saved = try? JSONDecoder().decode(GuideCache.self, from: data) else { return false }
            return saved.version == "swap-2" && saved.window == window && saved.channels.count == 1250
        }
    }

    /// A page of the refresh fails: the old guide stays on screen whole (with the stale notice); Try again resumes the
    /// refresh's paging where it stopped and swaps the new guide in once it is complete.
    func testAFailedRefreshPageLeavesTheOldGuideAndTryAgainFinishesTheSwap() async throws {
        BrowseModel.guidePageRetryDelaysOverride = []
        let m = try await loadedModel()
        let old = m.guide.map(\.programmes)
        SwapServer.version = "swap-2"
        SwapServer.failCursor = "500"
        let changes = watch(m)
        await m.refreshGuideIfStale(maxAge: 0)
        try await eventually { !m.guidePagingActive }
        XCTAssertNotNil(m.guideError)
        XCTAssertEqual(m.guide.map(\.programmes), old, "the old guide stays whole")
        XCTAssertEqual(changes(), [])
        SwapServer.failCursor = nil
        await m.retryGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        XCTAssertNil(m.guideError)
        XCTAssertEqual(changes(), [1250])
        XCTAssertEqual(SwapServer.guideRequests, 3 + 2 + 2, "the refresh's page 2 failed, Try again asked it again, then page 3")
        let window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        XCTAssertEqual(m.guide[1249].programmes, ProductionGuideFixture.channels(count: 1250, window: window)[1249].programmes)
    }

    /// A refresh that finds the same version and a window still covering the next 12 hours downloads nothing, as before.
    func testAnUnchangedGuideIsNotDownloadedAgain() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwapServer.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = BrowseModel(client: client, guideCacheDirectory: cacheDirectory)
        m.publishesTopShelf = false
        m.window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        await m.loadGuide()
        try await eventually { !m.guidePagingActive && !m.guideHasMore }
        await m.refreshGuideIfStale(maxAge: 0)
        XCTAssertEqual(SwapServer.guideRequests, 3)
    }

    private func cacheFile() -> URL {
        ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []).first
            ?? cacheDirectory.appendingPathComponent("none")
    }
}

/// The guide routes from `ProductionGuideFixture` (1,250 channels, pages of 500), with a version that can change, a page
/// that can be made to fail (by its cursor), a count of guide requests and a hook run on the main thread before each
/// guide page is answered.
private final class SwapServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) static var version = "swap-1"
    nonisolated(unsafe) static var failCursor: String?
    nonisolated(unsafe) static var duringGuidePage: (() -> Void)?

    static var guideRequests: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 }; version = "swap-1"; failCursor = nil; duringGuidePage = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200
        var body = Data(#"{"error":"not found"}"#.utf8)
        if url.path == "/api/library/guide/version" {
            body = Data(#"{"version":"\#(Self.version)"}"#.utf8)
        } else if url.path == "/api/library/guide" {
            Self.lock.withLock { Self.requests += 1 }
            if let during = Self.duringGuidePage { DispatchQueue.main.sync(execute: during) }
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value }
            if let fail = Self.failCursor, query["cursor"] == fail {
                status = 500
                body = Data(#"{"error":"down"}"#.utf8)
            } else {
                body = ProductionGuideFixture.pageJSON(query: query, total: 1250)
            }
        } else {
            status = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
