import XCTest
@testable import PigTV

// A1.1: a cursor-paged guide response, served page by page as `loadGuide`
// pages through it.
private final class PagedGuideProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pages: [String] = []
    nonisolated(unsafe) static var callCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = min(Self.callCount, Self.pages.count - 1)
        Self.callCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.pages[index].utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Build 33: a guide page that can be made to fail (nil) or succeed (its JSON
// body) at each call index, for the retry-with-backoff and resume-after-
// failure tests below.
private final class FlakyGuideProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var outcomes: [String?] = []
    nonisolated(unsafe) static var callCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = min(Self.callCount, Self.outcomes.count - 1)
        Self.callCount += 1
        if let body = Self.outcomes[index] {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() {}
}

// Guide model behaviour that the large (~18 000 channel) real guide depends
// on: indexed channel lookup (R18) and reorder-stable identity (R12).
@MainActor
final class GuideModelTests: XCTestCase {
    private func model() throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    // A1.1: cursor pages are appended with a single mutation of `guide` against
    // a persistent id set (not a per-page `Set(guide.map(\.id))` rebuild), and
    // a channel repeated across pages must not be duplicated.
    func testGuidePagesMergeAndDedupeAcrossPages() async throws {
        PagedGuideProtocol.callCount = 0
        PagedGuideProtocol.pages = [
            #"{"total":3,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]},{"id":"b","sourceId":1,"name":"B","programmes":[]}],"nextCursor":"p2"}"#,
            #"{"total":3,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]},{"id":"c","sourceId":1,"name":"C","programmes":[]}]}"#
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagedGuideProtocol.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"1","apiVersion":1,"features":{"library":true,"playbackResolve":true,"guideCursor":true}}"#.utf8))
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration), info: info)
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { !browse.guideHasMore }
        XCTAssertEqual(browse.guide.map(\.id).sorted(), ["1:a", "1:b", "1:c"], "Each channel must appear exactly once, in spite of the repeat on page 2")
        XCTAssertEqual(browse.guideTotal, 3)
    }

    // Build 33 ("the guide hits a wall moving forward in time"): a forward
    // extension merges the next slice into existing rows instead of
    // replacing them.
    func testExtendGuideForwardMergesProgrammesAndAdvancesLoadedUntil() async throws {
        PagedGuideProtocol.callCount = 0
        let futureMs = 4_000_000_000_000.0 // safely outside the 24 h past-trim margin
        PagedGuideProtocol.pages = [
            #"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[{"title":"P1","startTime":\#(futureMs),"endTime":\#(futureMs + 1_800_000)}]}]}"#,
            #"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[{"title":"P2","startTime":\#(futureMs + 1_800_000),"endTime":\#(futureMs + 3_600_000)}]}]}"#
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagedGuideProtocol.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration))
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { !browse.guideHasMore }
        XCTAssertEqual(browse.guide.first?.programmes.map(\.title), ["P1"])
        let untilBefore = browse.guideLoadedUntil
        XCTAssertEqual(browse.guideProgrammesVersion, 0)
        await browse.extendGuideForward()
        XCTAssertEqual(browse.guide.first?.programmes.map(\.title), ["P1", "P2"],
                       "the new slice is merged in, not replacing what was already loaded")
        XCTAssertEqual(browse.guideLoadedUntil, untilBefore.addingTimeInterval(GuideNavigation.loadedDuration))
        XCTAssertEqual(browse.guideProgrammesVersion, 1)
        XCTAssertFalse(browse.guideEnded)
    }

    // Perf sanity on a realistic 1 000-channel lineup (the project's usual
    // way of measuring this, see `git log --grep perf`): merging a slice
    // into every row is one array rebuild, not O(n) Combine publishes or a
    // per-channel `Set` rebuild, so it should stay well under a second.
    func testExtendGuideForwardPerformanceOnAThousandChannels() async throws {
        let channelCount = 1000
        let futureMs = 4_000_000_000_000.0
        func channelsJSON(programme: Bool) -> String {
            "[" + (0..<channelCount).map { i in
                let programmes = programme
                    ? #"[{"title":"Next","startTime":\#(futureMs),"endTime":\#(futureMs + 1_800_000)}]"#
                    : "[]"
                return #"{"id":"ch\#(i)","sourceId":1,"name":"Channel \#(i)","programmes":\#(programmes)}"#
            }.joined(separator: ",") + "]"
        }
        PagedGuideProtocol.callCount = 0
        PagedGuideProtocol.pages = [
            #"{"total":\#(channelCount),"channels":\#(channelsJSON(programme: false))}"#,
            #"{"total":\#(channelCount),"channels":\#(channelsJSON(programme: true))}"#
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagedGuideProtocol.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration))
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { !browse.guideHasMore }
        XCTAssertEqual(browse.guide.count, channelCount)
        let start = Date()
        await browse.extendGuideForward()
        let elapsed = Date().timeIntervalSince(start)
        print("extendGuideForward on \(channelCount) channels: \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(browse.guide.first?.programmes.count, 1)
        XCTAssertLessThan(elapsed, 2.0, "merging a slice into 1 000 channels should stay well under a second")
    }

    // A slice with no programmes at all means the provider's guide has
    // ended: extension stops for good, with nothing left to retry.
    func testExtendGuideForwardEndsCleanlyWhenASliceHasNoProgrammes() async throws {
        PagedGuideProtocol.callCount = 0
        PagedGuideProtocol.pages = [
            #"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]}]}"#,
            #"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]}]}"#
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagedGuideProtocol.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration))
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { !browse.guideHasMore }
        await browse.extendGuideForward()
        XCTAssertTrue(browse.guideEnded)
        let callsAfterEnding = PagedGuideProtocol.callCount
        await browse.extendGuideForward()
        XCTAssertEqual(PagedGuideProtocol.callCount, callsAfterEnding, "once the guide has ended, nothing fetches again")
    }

    // A transient failure is retried with backoff before it would show as an
    // error — the override shrinks the wait so the test does not take ~20 s.
    func testAFailedGuidePageIsRetriedBeforeGivingUp() async throws {
        BrowseModel.guidePageRetryDelaysOverride = [0.01, 0.01]
        defer { BrowseModel.guidePageRetryDelaysOverride = nil }
        FlakyGuideProtocol.callCount = 0
        FlakyGuideProtocol.outcomes = [nil, #"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]}]}"#]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyGuideProtocol.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration))
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { !browse.guideBusy }
        XCTAssertNil(browse.guideError, "one transient failure recovers via the retry before the banner would show")
        XCTAssertEqual(browse.guide.map(\.id), ["1:a"])
        XCTAssertEqual(FlakyGuideProtocol.callCount, 2, "the same page is retried, not skipped")
    }

    // The guide error banner's Retry resumes paging from the cursor where it
    // stopped, instead of starting the whole guide over.
    func testRetryGuideResumesPagingRatherThanStartingOver() async throws {
        BrowseModel.guidePageRetryDelaysOverride = [] // fail at once: no internal retry to wait through
        defer { BrowseModel.guidePageRetryDelaysOverride = nil }
        FlakyGuideProtocol.callCount = 0
        FlakyGuideProtocol.outcomes = [
            #"{"total":2,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]}],"nextCursor":"p2"}"#,
            nil,
            #"{"total":2,"channels":[{"id":"b","sourceId":1,"name":"B","programmes":[]}]}"#
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyGuideProtocol.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"1","apiVersion":1,"features":{"library":true,"playbackResolve":true,"guideCursor":true}}"#.utf8))
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration), info: info)
        let browse = BrowseModel(client: client)
        await browse.loadGuide()
        try await eventually { browse.guideError != nil }
        XCTAssertEqual(browse.guide.map(\.id), ["1:a"], "the first page landed before the second failed")
        await browse.retryGuide()
        try await eventually { !browse.guideBusy && !browse.guideHasMore }
        XCTAssertNil(browse.guideError)
        XCTAssertEqual(browse.guide.map(\.id).sorted(), ["1:a", "1:b"], "Retry resumed after the cursor from page 1, not from the top")
        XCTAssertEqual(FlakyGuideProtocol.callCount, 3, "exactly the failed page was retried; page 1 was not re-fetched")
    }

    private func guideChannel(_ raw: String, stable: String? = nil, category: String = "News") -> GuideChannel {
        GuideChannel(rawID: raw, sourceId: 1, name: "Channel \(raw)", logo: nil, category: category,
                     programmes: [], stableId: stable)
    }

    private func channel(_ raw: String, stable: String? = nil) -> Channel {
        Channel(rawID: raw, sourceId: 1, name: "Channel \(raw)", logo: nil, category: nil,
                now: nil, next: nil, stableId: stable)
    }

    func testIndexedLookupFollowsGuideChanges() throws {
        let browse = try model()
        browse.guide = (0..<18_000).map { guideChannel("pos_\($0)") }
        XCTAssertEqual(browse.guideChannel(id: "1:pos_17999")?.name, "Channel pos_17999")
        XCTAssertNil(browse.guideChannel(id: "1:missing"))
        // A replaced guide (refresh or provider reorder) invalidates the index.
        browse.guide = [guideChannel("pos_0", stable: "abc")]
        XCTAssertNil(browse.guideChannel(id: "1:pos_17999"))
        XCTAssertEqual(browse.guideChannel(id: "1:pos_0")?.stableId, "abc")
        browse.guide.append(guideChannel("pos_1"))
        XCTAssertEqual(browse.guideChannel(id: "1:pos_1")?.name, "Channel pos_1")
    }

    func testIdentityKeyPrefersStableIdAndFallsBack() {
        XCTAssertEqual(guideChannel("pos_4", stable: "s1").identityKey, "1:s:s1")
        XCTAssertEqual(guideChannel("pos_4").identityKey, "1:pos_4")
        XCTAssertEqual(channel("pos_9", stable: "s1").identityKey, guideChannel("pos_4", stable: "s1").identityKey)
    }

    func testFavouriteCoversEveryListingOfACrossListedChannel() throws {
        let browse = try model()
        // Server 0097: one favourite, returned under one listing's id.
        browse.favourites = [channel("pos_10", stable: "s1")]
        XCTAssertTrue(browse.isFavourite(channel("pos_10", stable: "s1")))
        XCTAssertTrue(browse.isFavourite(channel("pos_250", stable: "s1")), "other listing of the same channel")
        XCTAssertFalse(browse.isFavourite(channel("pos_11", stable: "s2")))
        // Older servers without stableId keep plain id matching.
        browse.favourites = [channel("pos_10")]
        XCTAssertTrue(browse.isFavourite(channel("pos_10")))
        XCTAssertFalse(browse.isFavourite(channel("pos_11")))
    }

    func testProgrammeLookupUsesIndexOnLargeGuide() throws {
        let browse = try model()
        browse.guide = (0..<18_000).map { guideChannel("pos_\($0)") }
        let targets = (0..<500).map { channel("pos_\($0 * 36)") }
        measure {
            for target in targets { _ = browse.programmes(for: target) }
        }
    }
}
