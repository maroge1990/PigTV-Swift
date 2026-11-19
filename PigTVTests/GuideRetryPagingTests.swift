import XCTest
@testable import PigTV

// #355 (Codex final sign-off of 325-335, medium 1): page 2 of the Guide failed, the chosen chip matches only a channel
// on page 3; Try again fetched page 2 (`reset: false`) and cleared the error, but the paging did not resume, so page 3
// was never fetched and the chip showed as settled and empty. A retried page that succeeds with a cursor left now
// resumes the paging. Fails on the commit before (no channel "c", the cursor left behind).
@MainActor
final class GuideRetryPagingTests: XCTestCase {
    override func tearDown() {
        GuideRetryRoutes.reset()
        BrowseModel.guidePageRetryDelaysOverride = nil
        super.tearDown()
    }

    func testARetriedPageResumesThePagingUntilTheLastPage() async throws {
        BrowseModel.guidePageRetryDelaysOverride = [] // a failed page fails at once
        func page(_ id: String, next: String?) -> Data {
            Data(#"{"total":3,"channels":[{"id":"\#(id)","sourceId":1,"name":"\#(id.uppercased())","programmes":[]}]\#(next.map { #","nextCursor":"\#($0)""# } ?? "")}"#.utf8)
        }
        // Request 1: page 1; 2: page 2 fails; 3 (the retry): page 2; 4: page 3, the last.
        GuideRetryRoutes.answers = [(200, page("a", next: "p2")), (500, Data(#"{"error":"down"}"#.utf8)),
                                    (200, page("b", next: "p3")), (200, page("c", next: nil))]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideRetryRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = BrowseModel(client: client, guideCacheDirectory: cache)
        await m.loadGuide()
        for _ in 0..<100 where m.guidePaging { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.guide.map(\.rawID).sorted(), ["a"], "page 2 failed")
        XCTAssertNotNil(m.guideError)
        XCTAssertTrue(m.guideHasMore)
        await m.retryGuide()
        for _ in 0..<100 where m.guidePaging || m.guideHasMore { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.guide.map(\.rawID).sorted(), ["a", "b", "c"], "the retry's page, then the paging on to the last page")
        XCTAssertFalse(m.guideHasMore)
        XCTAssertNil(m.guideError)
        // The chip that matches only "c" now has its row, and the page is content, not settled and empty.
        let drawn = PageState.guideRows(m.guideState, rowsEmpty: !m.guide.contains { $0.rawID == "c" }, paging: m.guidePagingActive)
        XCTAssertEqual(drawn, .content)
    }
}

/// Answers the guide route from a queue, one answer per request.
private final class GuideRetryRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [(Int, Data)] = []
    static func reset() { answers = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var answer: (Int, Data) = (404, Data(#"{"error":"not found"}"#.utf8))
        if path == "/api/library/guide" {
            DispatchQueue.main.sync { if !Self.answers.isEmpty { answer = Self.answers.removeFirst() } }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
