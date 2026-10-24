import XCTest
@testable import PigTV

// R14: private caches are per server and account, artwork is keyed by
// canonical URL, fetched once, bounded; Home sees same-id changes.
private final class LogoProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    nonisolated(unsafe) static var body = Data("logo".utf8)
    nonisolated(unsafe) static var declareLength = true
    private static let lock = NSLock()
    static func reset(body: Data = Data("logo".utf8), declareLength: Bool = true) {
        lock.lock(); requests = []; self.body = body; self.declareLength = declareLength; lock.unlock()
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url!); let body = Self.body, declare = Self.declareLength; Self.lock.unlock()
        var headers = ["Content-Type": "image/png"]
        if declare { headers["Content-Length"] = String(body.count) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        // Deliver after a beat so concurrent callers overlap.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class CacheTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("CacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        LogoProtocol.reset()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func client(_ server: String = "http://one.local:3000", token: String? = "t") throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogoProtocol.self]
        return APIClient(address: try ServerAddress(server), token: token, session: URLSession(configuration: configuration),
                         artworkStore: ArtworkDiskStore(directory: temp.appendingPathComponent("art")))
    }

    // MARK: Keys and scopes

    func testRelativeLogosOnTwoServersHaveDifferentKeysAndTokensAreIgnored() throws {
        let a = try ServerAddress("http://one.local:3000"), b = try ServerAddress("http://two.local:3000")
        let keyA = try XCTUnwrap(ArtworkKey.key(logo: "/api/logo/7", address: a))
        let keyB = try XCTUnwrap(ArtworkKey.key(logo: "/api/logo/7", address: b))
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(ArtworkKey.key(logo: "/api/logo/7?token=abc&size=full", address: a),
                       ArtworkKey.key(logo: "/api/logo/7?size=full&token=zzz", address: a))
        XCTAssertEqual(keyA, ArtworkKey.key(logo: "/api/logo/7?token=abc", address: a))
        XCTAssertNil(ArtworkKey.key(logo: "", address: a))
    }

    func testDecodedCacheKeepsTwoServersApart() throws {
        let a = try ServerAddress("http://one.local:3000"), b = try ServerAddress("http://two.local:3000")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        ChannelArtwork.preload(image, for: "/api/logo/cache-test", address: a)
        XCTAssertNotNil(ChannelArtwork.cachedImage(for: "/api/logo/cache-test", address: a))
        XCTAssertNil(ChannelArtwork.cachedImage(for: "/api/logo/cache-test", address: b))
    }

    func testGuideCacheIsPerAccountAndDeletedOnRetire() throws {
        let address = try ServerAddress("http://one.local:3000")
        let dir = temp.appendingPathComponent("guide")
        let a = GuideCacheStore(scope: CacheScope(address: address, accountID: 1), directory: dir)
        let b = GuideCacheStore(scope: CacheScope(address: address, accountID: 2), directory: dir)
        let other = GuideCacheStore(scope: CacheScope(address: try ServerAddress("http://two.local:3000"), accountID: 1), directory: dir)
        XCTAssertTrue(a.save(Data("A".utf8)))
        XCTAssertNil(b.load(), "account B never reads account A's guide")
        XCTAssertNil(other.load(), "nor does another server")
        XCTAssertEqual(a.load(), Data("A".utf8))
        a.retire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
    }

    func testLateSaveAfterSignOutIsDroppedAndNeverReachesTheNextSession() throws {
        let address = try ServerAddress("http://one.local:3000")
        let dir = temp.appendingPathComponent("guide")
        let old = GuideCacheStore(scope: CacheScope(address: address, accountID: 1), directory: dir)
        old.retire()
        let next = GuideCacheStore(scope: CacheScope(address: address, accountID: 1), directory: dir)
        XCTAssertFalse(old.save(Data("late".utf8)))
        XCTAssertNil(next.load())
        XCTAssertNil(old.load())
    }

    func testBrowseModelRetireDeletesItsGuideCache() throws {
        let address = try ServerAddress("http://one.local:3000")
        let dir = temp.appendingPathComponent("guide")
        let model = BrowseModel(client: APIClient(address: address, token: "t"), accountID: 5, guideCacheDirectory: dir)
        let probe = GuideCacheStore(scope: CacheScope(address: address, accountID: 5), directory: dir)
        probe.save(Data("x".utf8))
        model.retirePrivateCaches()
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.fileURL.path))
    }

    // MARK: Fetching

    func testConcurrentRequestsForOneLogoMakeOneFetch() async throws {
        let client = try client()
        let results = try await withThrowingTaskGroup(of: Data?.self) { group in
            for _ in 0..<6 { group.addTask { @MainActor in try await client.artworkData("/api/logo/1?token=x") } }
            var all: [Data?] = []
            for try await value in group { all.append(value) }
            return all
        }
        XCTAssertEqual(LogoProtocol.count, 1)
        XCTAssertTrue(results.allSatisfy { $0 == Data("logo".utf8) })
        _ = try await client.artworkData("/api/logo/1")
        XCTAssertEqual(LogoProtocol.count, 1, "served from memory afterwards")
    }

    func testCancellingOneAwaiterDoesNotCancelTheSharedFetch() async throws {
        let client = try client()
        let first = Task { @MainActor in try await client.artworkData("/api/logo/2") }
        let second = Task { @MainActor in try await client.artworkData("/api/logo/2") }
        first.cancel()
        let data = try await second.value
        XCTAssertEqual(data, Data("logo".utf8))
        XCTAssertEqual(LogoProtocol.count, 1)
    }

    func testOversizedResponsesAreRejectedWithAndWithoutContentLength() async throws {
        for declare in [true, false] {
            LogoProtocol.reset(body: Data(repeating: 7, count: 5_000), declareLength: declare)
            let client = try client()
            client.artworkMaxBytes = 1_000
            let data = try await client.artworkData("/api/logo/big\(declare)")
            XCTAssertNil(data)
        }
    }

    // MARK: Disk

    func testPruneRemovesTheOldestPastTheSizeCapAndAnythingPastTheAgeCap() throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("prune"))
        let now = Date()
        let ages: [(String, TimeInterval)] = [("a", 3_000), ("b", 2_000), ("c", 1_000), ("stale", 40 * 24 * 3600)]
        for (key, age) in ages {
            store.write(Data(repeating: 1, count: 100), key: key)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                  ofItemAtPath: store.fileURL(forKey: key).path)
        }
        store.prune(maxBytes: 200, maxAge: ArtworkDiskStore.maxAge, now: now)
        let exists = { (key: String) in FileManager.default.fileExists(atPath: store.fileURL(forKey: key).path) }
        XCTAssertFalse(exists("stale"))
        XCTAssertFalse(exists("a"), "oldest goes first")
        XCTAssertTrue(exists("b") && exists("c"))
    }

    func testReadingRefreshesRecencySoItSurvivesPruning() throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("lru"))
        let now = Date()
        for (key, age) in [("old", 3_000.0), ("new", 1_000.0)] {
            store.write(Data(repeating: 1, count: 100), key: key)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                                  ofItemAtPath: store.fileURL(forKey: key).path)
        }
        XCTAssertNotNil(store.read(key: "old", now: now))
        store.prune(maxBytes: 100, maxAge: ArtworkDiskStore.maxAge, now: now)
        XCTAssertNotNil(store.read(key: "old", now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forKey: "new").path))
    }

    // MARK: A5 (build 48): the cap holds during use, not only at launch

    private func folderBytes(_ store: ArtworkDiskStore) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    func testWritesPastTheCapArePrunedWithoutANewStoreAndPrunesAreCoalesced() async throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("budget"), limit: 10_000)
        for i in 0..<40 { store.write(Data(repeating: UInt8(i), count: 1_000), key: "logo\(i)") }
        await store.budget.idle()
        XCTAssertLessThanOrEqual(folderBytes(store), 10_000, "the cap holds while the app runs")
        XCTAssertNotNil(store.read(key: "logo39"), "the newest is kept")
        XCTAssertLessThan(store.budget.prunes, 20, "the folder is listed per prune, not per image (\(store.budget.prunes))")
        XCTAssertEqual(store.budget.counted, folderBytes(store), "the running count matches the disk")
    }

    func testConcurrentWritesStayBoundedAndARecentlyReadLogoSurvives() async throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("budget-concurrent"), limit: 20_000)
        store.write(Data(repeating: 7, count: 1_000), key: "favourite")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask {
                    store.write(Data(repeating: UInt8(i % 250), count: 1_000), key: "logo\(i)")
                    if i % 10 == 0 { _ = store.read(key: "favourite", now: Date().addingTimeInterval(3600)) } // kept in use
                }
            }
        }
        await store.budget.idle()
        XCTAssertLessThanOrEqual(folderBytes(store), 20_000)
        XCTAssertNotNil(store.read(key: "favourite"), "least recently used goes first: the one in use stays")
    }

    // MARK: A5-R (build 53): replacement, removal and the count are one change at a time

    /// Pauses a write of `key` between reading the old size and replacing the file (once), and
    /// reports when another change has to wait for it. Scheduling barriers: no timers.
    private final class ReplaceBarrier: @unchecked Sendable {
        let arrived = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let progress = DispatchSemaphore(value: 0)   // another change waited, or finished
        private let lock = NSLock()
        private var armed = true

        init(key: String) {
            ArtworkDiskStore.beforeReplacing = { [unowned self] written in
                guard written == key, self.lock.withLock({ () -> Bool in defer { self.armed = false }; return self.armed }) else { return }
                self.arrived.signal()
                self.resume.wait()
            }
            ArtworkBudget.waitingForFiles = { [unowned self] in self.progress.signal() }
        }

        func remove() {
            ArtworkDiskStore.beforeReplacing = nil
            ArtworkBudget.waitingForFiles = nil
        }
    }

    private nonisolated static func block(_ semaphore: DispatchSemaphore) { semaphore.wait() }

    private func wait(_ semaphore: DispatchSemaphore) async {
        await Task.detached { Self.block(semaphore) }.value
    }

    func testAPruneBetweenAReplacementsSizeReadAndItsWriteLeavesTheCountEqualToTheDisk() async throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("budget-replace"), limit: 1_500)
        store.write(Data(repeating: 1, count: 1_000), key: "old")
        await store.budget.idle()
        XCTAssertEqual(store.budget.counted, 1_000)
        _ = store.read(key: "old", now: Date().addingTimeInterval(-60)) // the least recently used
        let barrier = ReplaceBarrier(key: "old")
        defer { barrier.remove() }

        let replacing = Task.detached { store.write(Data(repeating: 2, count: 1_000), key: "old") }
        await wait(barrier.arrived) // the old size is read; the replacement has not been written
        let other = Task.detached {
            store.write(Data(repeating: 3, count: 1_000), key: "new") // crosses the cap: a prune
            barrier.progress.signal()
        }
        await wait(barrier.progress) // it waited for the replacement, or it ran (and started its prune)
        await store.budget.idle()    // a prune it started has removed what it could
        barrier.resume.signal()
        await replacing.value
        await other.value
        await store.budget.idle()

        XCTAssertEqual(store.budget.counted, folderBytes(store), "the count is what is on disk")
        XCTAssertLessThanOrEqual(folderBytes(store), store.limit, "and the cap holds once no prune runs")
    }

    func testTwoWritersOfTheSameKeyAreCountedOnce() async throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("budget-same-key"), limit: 100_000)
        store.write(Data(repeating: 9, count: 500), key: "seed")
        await store.budget.idle() // counted from here on
        let barrier = ReplaceBarrier(key: "same")
        defer { barrier.remove() }

        let first = Task.detached { store.write(Data(repeating: 1, count: 1_000), key: "same") }
        await wait(barrier.arrived) // it read "no file yet"
        let second = Task.detached {
            store.write(Data(repeating: 2, count: 1_000), key: "same")
            barrier.progress.signal()
        }
        await wait(barrier.progress)
        barrier.resume.signal()
        await first.value
        await second.value
        await store.budget.idle()

        XCTAssertEqual(folderBytes(store), 1_500)
        XCTAssertEqual(store.budget.counted, 1_500, "one file of 1000 bytes, counted once")
    }

    func testAfterManyConcurrentWritersAndPrunesTheCountIsTheDiskAndUnderTheCap() async throws {
        let store = ArtworkDiskStore(directory: temp.appendingPathComponent("budget-eventual"), limit: 8_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask { store.write(Data(repeating: UInt8(i % 250), count: 700 + (i % 5) * 100), key: "logo\(i % 25)") }
                if i % 20 == 0 { group.addTask { _ = store.prune(maxBytes: 8_000) } }
            }
        }
        await store.budget.idle()
        XCTAssertEqual(store.budget.counted, folderBytes(store), "the count is what is on disk")
        XCTAssertLessThanOrEqual(folderBytes(store), 8_000)
    }

    // MARK: Home

    func testARecordingWhoseStatusChangesWithTheSameIDIsNotEqualAndChangesHomesRows() throws {
        func recording(_ status: String, native: String?) throws -> Recording {
            let nativeJSON = native.map { "\"\($0)\"" } ?? "null"
            return try JSONDecoder().decode(Recording.self, from: Data(
                #"{"id":9,"title":"Show","status":"\#(status)","native_status":\#(nativeJSON)}"#.utf8))
        }
        let preparing = try recording("completed", native: "preparing"), ready = try recording("completed", native: "ready")
        XCTAssertEqual(preparing.id, ready.id)
        XCTAssertNotEqual([preparing], [ready], "Home's onChange(of: recordings) fires")
        XCTAssertEqual([preparing], [try recording("completed", native: "preparing")], "and not for an identical publish")
        XCTAssertTrue(HomeRows.recordings([preparing]).first?.isPreparingForPlayback == true)
        XCTAssertTrue(HomeRows.recordings([ready]).first?.isPreparingForPlayback == false)
    }
}
