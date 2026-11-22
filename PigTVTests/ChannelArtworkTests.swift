import SwiftUI
import XCTest
@testable import PigTV

/// maroge1990/PigTV#360 (G4): channel logos. A logo already decoded is drawn on the view's first frame (it used to be read
/// only in `.task`, so a reused guide tile drew its placeholder first and the logo a frame or more later), and a logo
/// fetch is cancelled, down to its URLSession task, once nothing waits for it: the view went away or was reused for
/// another logo, or the guide tile left the screen (it used to run on regardless).
@MainActor
final class ChannelArtworkTests: XCTestCase {
    private var window: UIWindow?
    private var directory: URL?

    override func setUp() async throws {
        HeldLogoServer.reset()
        GuidePerf.resetForTests()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        HeldLogoServer.reset()
    }

    private func spin(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func until(_ what: String, timeout: TimeInterval = 5, _ ok: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ok(), what)
    }

    /// A client whose logos are answered by `HeldLogoServer` (never the network) and stored in a fresh folder.
    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldLogoServer.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChannelArtworkTests-\(UUID().uuidString)")
        self.directory = directory
        return APIClient(address: try ServerAddress(HeldLogoServer.address), session: URLSession(configuration: configuration),
                         artworkStore: ArtworkDiskStore(directory: directory))
    }

    private func show<V: View>(_ view: V) -> UIHostingController<V> {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        host.view.layoutIfNeeded()
        return host
    }

    // MARK: (i) a logo in memory draws at once

    /// A view whose logo is already decoded draws it in its first layout pass, from memory (the probe's sync hit), never
    /// through its task a frame later (a late hit: 377 read the cache only in `.task`, so the first frame was the
    /// placeholder), and fetches nothing.
    func testALogoAlreadyInMemoryIsDrawnOnTheFirstFrame() async throws {
        let client = try client()
        let logo = "/api/logo/sync-\(UUID().uuidString)"
        let green = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 0, green: 1, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        ChannelArtwork.preload(green, for: logo, address: client.address)
        _ = show(ChannelArtwork(logo: logo, client: client).frame(width: 64, height: 64)) // one layout pass, no run loop turn
        XCTAssertGreaterThanOrEqual(GuidePerf.logoSyncHitsForTesting, 1, "the first layout pass did not draw the logo in memory")
        try await spin(0.3) // the view's task runs
        XCTAssertEqual(GuidePerf.logoLateHitsForTesting, 0, "the logo was drawn a frame late, by the view's task")
        XCTAssertEqual(HeldLogoServer.startedCount, 0, "a logo in memory is not fetched")
    }

    /// Review of 379: a logo drawn from the shared memory cache was not kept by the view, so once the cache evicted it the
    /// view's next body drew the placeholder (and fetched the logo again). The view keeps what it drew for that logo.
    func testALogoDrawnFromMemoryStaysWhenTheCacheEvictsIt() async throws {
        let client = try client()
        let logo = "/api/logo/held-evicted-\(UUID().uuidString)" // a fetch of it never answers
        let green = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 0, green: 1, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        ChannelArtwork.preload(green, for: logo, address: client.address)
        let host = show(ChannelArtwork(logo: logo, client: client).frame(width: 64, height: 64))
        XCTAssertEqual(ChannelArtwork.drawnForTesting[logo], true, "drawn from memory at first")
        try await spin(0.2)
        ChannelArtwork.clearCacheForTesting() // NSCache let it go
        host.rootView = ChannelArtwork(logo: logo, client: client, fill: true).frame(width: 64, height: 64) // the same view, again
        host.view.layoutIfNeeded()
        XCTAssertEqual(ChannelArtwork.drawnForTesting[logo], true, "the view drew its placeholder once the cache evicted the logo")
        try await spin(0.3)
        XCTAssertFalse(HeldLogoServer.startedPaths.contains(logo), "the view fetched a logo it had already drawn")
    }

    // MARK: (ii) fetches stop when nothing waits

    /// A view reused for another logo (as a guide tile is), then taken away: each fetch it started is cancelled, and the
    /// URLSession task under it stops (the protocol's `stopLoading` before it answered), well inside the 10 s timeout.
    func testAViewThatChangesLogoOrGoesAwayCancelsItsFetch() async throws {
        let client = try client()
        let first = "/api/logo/held-a-\(UUID().uuidString)", second = "/api/logo/held-b-\(UUID().uuidString)"
        let host = show(ChannelArtwork(logo: first, client: client).frame(width: 120, height: 80))
        try await until("the first logo is requested") { HeldLogoServer.startedPaths.contains(first) }
        host.rootView = ChannelArtwork(logo: second, client: client).frame(width: 120, height: 80)
        host.view.layoutIfNeeded()
        try await until("the first logo's request stops when the view shows another logo", timeout: 3) {
            HeldLogoServer.stoppedPaths.contains(first)
        }
        try await until("the second logo is requested") { HeldLogoServer.startedPaths.contains(second) }
        window?.rootViewController = UIViewController()
        try await until("the second logo's request stops when the view goes away", timeout: 3) {
            HeldLogoServer.stoppedPaths.contains(second)
        }
    }

    /// Two views waiting for one logo share one request; one going away leaves it running for the other.
    func testAFetchAnotherViewWaitsForKeepsGoing() async throws {
        let client = try client()
        let logo = "/api/logo/held-shared-\(UUID().uuidString)"
        let host = show(VStack {
            ChannelArtwork(logo: logo, client: client).frame(width: 120, height: 80)
            ChannelArtwork(logo: logo, client: client).frame(width: 120, height: 80)
        })
        try await until("the logo is requested") { HeldLogoServer.startedPaths.contains(logo) }
        try await spin(0.3)
        XCTAssertEqual(HeldLogoServer.startedPaths.filter { $0 == logo }.count, 1, "one request for both views")
        host.rootView = VStack {
            ChannelArtwork(logo: logo, client: client).frame(width: 120, height: 80)
            ChannelArtwork(logo: nil, client: client).frame(width: 120, height: 80)
        }
        host.view.layoutIfNeeded()
        try await spin(1)
        XCTAssertFalse(HeldLogoServer.stoppedPaths.contains(logo), "the other view still waits for it")
    }

    /// Callers that do not cancel (the Top Shelf, Sport banners) keep a shared fetch going to its end, as before #360.
    func testAFetchACallerThatDoesNotCancelWaitsForKeepsGoing() async throws {
        let client = try client()
        let logo = "/api/logo/held-pinned-\(UUID().uuidString)"
        let pinned = Task { try? await client.artworkData(logo) }
        try await until("the logo is requested") { HeldLogoServer.startedPaths.contains(logo) }
        let cancelling = Task { try? await client.artworkData(logo, cancellable: true) }
        try await spin(0.2)
        cancelling.cancel()
        pinned.cancel()
        try await spin(1)
        XCTAssertFalse(HeldLogoServer.stoppedPaths.contains(logo), "a fetch a non-cancelling caller asked for was stopped")
        XCTAssertEqual(HeldLogoServer.startedPaths.filter { $0 == logo }.count, 1, "one request for both callers")
    }

    /// The TV Guide: tiles whose logos are still loading scroll off screen; their fetches stop (the grid tells each tile's
    /// cell it ended display), and nothing is left loading for a row that is not on screen.
    func testGuideTilesThatLeaveTheScreenCancelTheirLogoFetches() async throws {
        let (controller, rows) = try await hostHeldGrid()
        let grid = try XCTUnwrap(controller.collectionView)
        for step in 1...6 {
            grid.contentOffset.y = CGFloat(step) * 1200
            grid.layoutIfNeeded()
            try await spin(0.2)
        }
        let shown = Set(grid.indexPathsForVisibleItems.map(\.section))
        let left = rows.indices.filter { !shown.contains($0) && HeldLogoServer.startedPaths.contains(rows[$0].logo!) }
        XCTAssertFalse(left.isEmpty, "rows whose logos were loading left the screen")
        try await until("every row that left the screen stopped loading its logo", timeout: 3) {
            left.allSatisfy { HeldLogoServer.stoppedPaths.contains(rows[$0].logo!) }
        }
        let stillLoading = left.filter { !HeldLogoServer.stoppedPaths.contains(rows[$0].logo!) }
        XCTAssertEqual(stillLoading, [], "rows off screen still loading their logos")
    }

    /// Review of 379: on a reload UIKit can end the display of a reused cell's old item after it began displaying the new
    /// one (willDisplay, then didEndDisplaying for the old index path, or for the same one while the cell stays). The tile
    /// was then marked off screen while on screen, and its logo never loaded. A stale end is ignored.
    func testAStaleEndOfDisplayLeavesAVisibleTileLoadingItsLogo() async throws {
        let (controller, rows) = try await hostHeldGrid()
        let grid = try XCTUnwrap(controller.collectionView)
        func requests(_ paths: [String], _ section: Int) -> Int { paths.filter { $0 == rows[section].logo! }.count }
        let visible = grid.indexPathsForVisibleItems.filter { $0.item == 0 }.sorted()
        let at = try XCTUnwrap(visible.first {
            requests(HeldLogoServer.startedPaths, $0.section) > requests(HeldLogoServer.stoppedPaths, $0.section)
        }, "a visible tile is loading its logo")
        let tile = try XCTUnwrap(grid.cellForItem(at: at) as? GuideGridTileCell)
        XCTAssertTrue(tile.artworkLifetime.isDisplayed)
        let stops = requests(HeldLogoServer.stoppedPaths, at.section)
        let elsewhere = IndexPath(item: 0, section: (at.section + 60) % rows.count) // the item it showed before a reload
        controller.collectionView(grid, willDisplay: tile, forItemAt: at)
        controller.collectionView(grid, didEndDisplaying: tile, forItemAt: elsewhere)
        controller.collectionView(grid, didEndDisplaying: tile, forItemAt: at) // the same item, still on screen
        try await spin(0.5)
        XCTAssertTrue(tile.artworkLifetime.isDisplayed, "a tile on screen is marked off screen")
        XCTAssertEqual(requests(HeldLogoServer.stoppedPaths, at.section), stops, "a tile on screen stopped loading its logo")
    }

    /// The same on a real reload: every tile on screen afterwards is marked on screen.
    func testAfterAReloadEveryTileOnScreenIsMarkedOnScreen() async throws {
        let (controller, _) = try await hostHeldGrid()
        let grid = try XCTUnwrap(controller.collectionView)
        XCTAssertFalse(grid.indexPathsForVisibleItems.isEmpty, "tiles on screen before the reload")
        grid.reloadData()
        grid.layoutIfNeeded()
        try await spin(0.3)
        XCTAssertFalse(grid.indexPathsForVisibleItems.isEmpty, "tiles on screen after the reload")
        for indexPath in grid.indexPathsForVisibleItems where indexPath.item == 0 {
            XCTAssertEqual((grid.cellForItem(at: indexPath) as? GuideGridTileCell)?.artworkLifetime.isDisplayed, true,
                           "after a reload, the tile at \(indexPath) is marked off screen")
        }
    }

    /// 120 rows whose logos never answer, in a grid in a window, laid out.
    private func hostHeldGrid() async throws -> (GuideGridViewController, [GuideChannel]) {
        let client = try client()
        let model = BrowseModel(client: client, guideCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelArtworkTests-guide-\(UUID().uuidString)"))
        let now = Date()
        let tag = UUID().uuidString
        let rows = (0..<120).map { index in
            GuideChannel(rawID: "h\(index)", sourceId: 1, name: "Held \(index)", logo: "/api/logo/held-row\(index)-\(tag)",
                         category: "News", programmes: [GuideProgramme(title: "Show \(index)", description: nil,
                                                                       startTime: (now - 600).timeIntervalSince1970 * 1000,
                                                                       endTime: (now + 3000).timeIntervalSince1970 * 1000)])
        }
        let controller = GuideGridViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        controller.loadViewIfNeeded()
        controller.update(from: GuideGridView(rows: rows, rowsVersion: 1, model: model, origin: now - 1800,
                                              loadedDuration: GuideNavigation.loadedDuration, clock: now, scheduled: [],
                                              recording: [], request: nil, resetToken: 0,
                                              actions: GuideGridActions(select: { _, _ in }, play: { _ in },
                                                                        focusChanged: { _, _ in }, viewportChanged: { _ in })))
        controller.view.layoutIfNeeded()
        try await spin(0.5)
        // A window with no scene gets no layout pass of its own: lay the rows out (the first fill arrived meanwhile).
        controller.collectionView.layoutIfNeeded()
        try await spin(0.3)
        return (controller, rows)
    }

    // MARK: (iii) no blocking read on the main thread

    /// The logo bytes are read (the disk store, then the response body) off the main thread: the injected loader checks
    /// where it runs.
    func testTheLogoBytesAreNeverReadOnTheMainThread() async throws {
        let client = try client()
        let logo = "/api/logo/png-\(UUID().uuidString)"
        let reads = ReadThreads()
        APIClient.artworkReadObserver = { onMain in reads.record(onMain) }
        defer { APIClient.artworkReadObserver = nil }
        let host = show(ChannelArtwork(logo: logo, client: client).frame(width: 120, height: 80))
        _ = host
        try await until("the logo is read") { reads.count > 0 }
        XCTAssertEqual(reads.onMain, 0, "a logo read ran on the main thread")
    }
}

/// Where each logo read ran (written from the loader's thread).
private final class ReadThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var all = 0, main = 0
    func record(_ onMain: Bool) { lock.withLock { all += 1; if onMain { main += 1 } } }
    var count: Int { lock.withLock { all } }
    var onMain: Int { lock.withLock { main } }
}

/// Logos for the tests, in the client's own URL loading (never the network): `/api/logo/held-…` never answers (until
/// cancelled: `stopLoading` before an answer is recorded), `/api/logo/png-…` answers at once with a small PNG.
final class HeldLogoServer: URLProtocol, @unchecked Sendable {
    static let address = "http://127.0.0.1:3987"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: [String] = []
    nonisolated(unsafe) private static var stopped: [String] = []
    static var startedPaths: [String] { lock.withLock { started } }
    static var stoppedPaths: [String] { lock.withLock { stopped } }
    static var startedCount: Int { lock.withLock { started.count } }
    static func reset() { lock.withLock { started = []; stopped = [] } }

    private var answered = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 3987 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.started.append(url.path) }
        guard url.path.hasPrefix("/api/logo/png-") else { return } // held: no answer
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData() ?? Data()
        Self.lock.withLock { answered = true }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png", "Content-Length": String(png.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let path = request.url?.path else { return }
        Self.lock.withLock { if !answered { Self.stopped.append(path) } }
    }
}
