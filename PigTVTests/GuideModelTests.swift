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
