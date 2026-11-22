import XCTest
@testable import PigTV

/// #360 (G7, C3, Apple 385): a forward extension merged the new slice into every channel and trimmed the past on the
/// main actor (about 1,250 channels on the real guide). The merge and trim now run off it on value copies
/// (`GuideNavigation.extended`), and the result is handed back in one assignment unless a reload or a sign-out happened
/// meanwhile. Before 385 `testTheExtensionMergesOffTheMainActor` fails (the merge ran on the main thread; proved with the
/// observer placed in the old loop).
@MainActor
final class GuideExtendOffMainTests: XCTestCase {
    override func tearDown() {
        BrowseModel.extendMergeObserver = nil
        ExtendServer.total = 1250
        super.tearDown()
    }

    /// The merge as it was before 385, on the main actor (the reference the new one must equal).
    private func oldMerge(_ guide: [GuideChannel], _ merged: [String: [GuideProgramme]], keepFrom: Date) -> [GuideChannel] {
        var updated = guide
        for index in updated.indices {
            var programmes = updated[index].programmes
            if let additions = merged[updated[index].id] {
                programmes = GuideNavigation.mergeProgrammes(programmes, adding: additions)
            }
            updated[index] = updated[index].withProgrammes(GuideNavigation.trimmed(programmes, keepFrom: keepFrom))
        }
        return updated
    }

    /// 1,250 channels: a day from 30 hours ago, the next day merged in (the programme across the boundary is in both: a
    /// duplicate start), and the 24 h trim cutting the oldest programmes; a channel with no slice is trimmed only.
    func testTheMergeEqualsTheOldOneOnTheProductionFixture() throws {
        let now = Date()
        let window = GuideNavigation.rounded(now).addingTimeInterval(-30 * 3600)
        let guide = ProductionGuideFixture.channels(count: 1250, window: window)
        let from = window.addingTimeInterval(GuideNavigation.loadedDuration).timeIntervalSince1970 * 1000
        var slice: [String: [GuideProgramme]] = [:]
        for (index, channel) in guide.enumerated() where index % 50 != 7 {
            slice[channel.id] = ProductionGuideFixture.programmes(channel: index, from: from, to: from + GuideNavigation.loadedDuration * 1000)
        }
        let duplicates = guide.indices.filter { index in
            slice[guide[index].id].map { Set(guide[index].programmes.map(\.startTime)).contains($0.first?.startTime ?? -1) } ?? false
        }
        XCTAssertFalse(duplicates.isEmpty, "the fixture has starts repeated across the slices")
        let keepFrom = now.addingTimeInterval(-GuideNavigation.pastTrimMargin)
        XCTAssertTrue(guide.contains { $0.programmes.contains { $0.end <= keepFrom } }, "the trim has something to cut")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(GuideNavigation.extended(guide, with: slice, keepFrom: keepFrom)),
                       try encoder.encode(oldMerge(guide, slice, keepFrom: keepFrom)))
    }

    private func loadedModel(total: Int = 1250) async throws -> BrowseModel {
        ExtendServer.total = total
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExtendServer.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = BrowseModel(client: client, guideCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-extend-\(UUID().uuidString)"))
        m.publishesTopShelf = false
        m.window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        await m.loadGuide()
        for _ in 0..<500 where m.guidePagingActive || m.guideHasMore { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.guide.count, total)
        return m
    }

    func testTheExtensionMergesOffTheMainActor() async throws {
        let m = try await loadedModel()
        let threads = MergeLog<[Bool]>([])
        BrowseModel.extendMergeObserver = { onMain in threads.withLock { $0.append(onMain) } }
        let until = m.guideLoadedUntil
        await m.extendGuideForward()
        XCTAssertEqual(threads.withLock { $0 }, [false], "the merge ran once, off the main thread")
        XCTAssertEqual(m.guideLoadedUntil, until.addingTimeInterval(GuideNavigation.loadedDuration))
        XCTAssertEqual(m.guideProgrammesVersion, 1)
        let next = until.timeIntervalSince1970 * 1000
        XCTAssertEqual(m.guide[3].programmes.last?.startTime,
                       ProductionGuideFixture.programmes(channel: 3, from: next, to: next + GuideNavigation.loadedDuration * 1000).last?.startTime,
                       "the next day is merged in")
    }

    /// A sign-out while the merge runs wins: its result is dropped, the guide and its loaded edge stay as they were.
    func testASignOutDuringTheMergeWins() async throws {
        let m = try await loadedModel(total: 120)
        let before = m.guide.map(\.programmes)
        let until = m.guideLoadedUntil
        BrowseModel.extendMergeObserver = { onMain in
            let signOut = { MainActor.assumeIsolated { m.retirePrivateCaches() } }
            if onMain { signOut() } else { DispatchQueue.main.sync(execute: signOut) }
        }
        await m.extendGuideForward()
        XCTAssertEqual(m.guide.map(\.programmes), before, "the merge's result never reached the guide")
        XCTAssertEqual(m.guideLoadedUntil, until)
        XCTAssertEqual(m.guideProgrammesVersion, 0)
    }
}

/// `ProductionGuideFixture`'s guide for any window, limit and cursor.
private final class ExtendServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var total = 1250
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200
        var body = Data(#"{"error":"not found"}"#.utf8)
        if url.path == "/api/library/guide/version" {
            body = Data(#"{"version":"extend-1"}"#.utf8)
        } else if url.path == "/api/library/guide" {
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value }
            body = ProductionGuideFixture.pageJSON(query: query, total: Self.total)
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

/// A value shared with a closure that runs on another thread.
private final class MergeLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
