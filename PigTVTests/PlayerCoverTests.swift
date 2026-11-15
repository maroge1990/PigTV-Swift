import XCTest
import SwiftUI
@testable import PigTV

/// #301 (batch J review, lows): a recording's own full-screen cover rests the pages beneath it like the live player's,
/// and the Top Shelf is written as the app goes to the background.
@MainActor
final class PlayerCoverTests: XCTestCase {
    func testARecordingPlayerCoversThePagesUntilItCloses() {
        let app = AppModel()
        XCTAssertFalse(app.pagesCovered)
        app.recordingPlayer(presented: true)
        XCTAssertTrue(app.pagesCovered, "a playing recording rests the pages and the minute pass")
        XCTAssertFalse(app.playerPresented, "it is not the live player")
        app.recordingPlayer(presented: false)
        XCTAssertFalse(app.pagesCovered)
        app.recordingPlayer(presented: false)
        app.recordingPlayer(presented: true)
        XCTAssertTrue(app.pagesCovered, "a stray close never leaves a negative count")
    }

    /// Opus review of Apple 1 (medium): a session that ends with a recording's cover up (signed out, or the tree replaced)
    /// may never see its close; the next session's pages must not stay covered, so the count starts again with each one.
    func testANewSessionStartsWithThePagesUncovered() throws {
        let app = AppModel()
        app.recordingPlayer(presented: true)
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", info: info))
        app.configureClientForTesting(browse.client, browse: browse)
        XCTAssertFalse(app.pagesCovered, "a new session's pages poll: the old cover's count is gone")
    }

    func testTheLivePlayerStillCoversThePages() {
        let app = AppModel()
        app.playerPresented = true
        XCTAssertTrue(app.pagesCovered)
    }

    /// The screen itself reports: presented on appear, not presented once it is gone.
    func testTheRecordingPlayerScreenReportsItsCover() async throws {
        final class Log: @unchecked Sendable { var events: [Bool] = [] }
        let log = Log()
        let client = APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "fixture")
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let root = RecordingPlayerScreen(recording: recording, client: client)
            .environment(\.pigRecordingPlayerCover, { log.events.append($0) })
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        for _ in 0..<100 where log.events.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(log.events, [true], "appearing marks the pages covered")
        window.rootViewController = nil
        window.isHidden = true
        for _ in 0..<100 where log.events.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(log.events, [true, false], "going away clears it")
    }

    func testTheTopShelfIsExportedOnceInTheBackgroundWithNoRequest() async throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"channelNumbers":true}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "t", info: info))
        var exports = 0
        AppFreshness.exportOnBackground(browse, export: { _ in exports += 1 }, hold: { _, work in Task { await work() } })
        for _ in 0..<100 where exports == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(exports, 1)
    }

    /// #313 item 1: the background export holds a background task from before it starts until its snapshot is written.
    func testTheBackgroundExportHoldsABackgroundTaskUntilWritten() async throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "t", info: info))
        var log: [String] = []
        var write: CheckedContinuation<Void, Never>?
        var held: (@MainActor () async -> Void)?
        AppFreshness.exportOnBackground(browse, export: { _ in
            log.append("export began")
            await withCheckedContinuation { write = $0 }
            log.append("written")
        }, hold: { name, work in
            log.append("held: \(name)")
            held = work
        })
        XCTAssertEqual(log, ["held: PigTV: Top Shelf export"], "the background task is taken before the export starts")
        let work = try XCTUnwrap(held)
        let running = Task { await work(); log.append("released") }
        for _ in 0..<100 where write == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.last, "export began")
        XCTAssertFalse(log.contains("released"), "still held while the snapshot is being written")
        write?.resume()
        await running.value
        XCTAssertEqual(log, ["held: PigTV: Top Shelf export", "export began", "written", "released"])
    }

    // MARK: #313 item 5: ContentView's wiring (`AppRootCover`), which no test exercised

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The pages see `pigCoveredByPlayer` follow the live player and a recording's cover, and a recording's screen
    /// reaches the model through `pigRecordingPlayerCover`.
    func testTheRootTellsThePagesWhileAPlayerCoversThem() async throws {
        let app = AppModel()
        final class Seen { var covered: [Bool] = []; var report: (@MainActor (Bool) -> Void)? }
        let seen = Seen()
        let window = try host(CoverProbe(seen: { seen.covered.append($0) }, report: { seen.report = $0 })
            .modifier(AppRootCover(model: app)))
        defer { window.rootViewController = nil; window.isHidden = true }
        try await until { seen.covered == [false] && seen.report != nil }
        XCTAssertEqual(seen.covered, [false], "uncovered at first")
        app.playerPresented = true
        try await until { seen.covered.last == true }
        XCTAssertEqual(seen.covered.last, true, "the live player covers the pages")
        app.playerPresented = false
        try await until { seen.covered.last == false }
        XCTAssertEqual(seen.covered.last, false)
        seen.report?(true)
        XCTAssertTrue(app.pagesCovered, "a recording's screen reaches the model")
        try await until { seen.covered.last == true }
        XCTAssertEqual(seen.covered.last, true, "and the pages are told")
        seen.report?(false)
        XCTAssertFalse(app.pagesCovered)
    }

    /// Going to the background settles the open Undo and exports the Top Shelf once, for the session's guide; other
    /// phases do neither.
    func testGoingToTheBackgroundExportsTheTopShelfOnce() throws {
        let app = AppModel()
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "t", info: info))
        app.configureClientForTesting(browse.client, browse: browse)
        var exported: [ObjectIdentifier] = []
        var committed = false
        app.presenter.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        app.presenter.offerUndo("Recording deleted", commit: { committed = true })
        AppRootCover.sceneChanged(to: .inactive, model: app, exportOnBackground: { exported.append(ObjectIdentifier($0)) })
        XCTAssertTrue(exported.isEmpty)
        XCTAssertFalse(committed)
        AppRootCover.sceneChanged(to: .background, model: app, exportOnBackground: { exported.append(ObjectIdentifier($0)) })
        XCTAssertEqual(exported, [ObjectIdentifier(browse)], "once, for the session's guide")
        XCTAssertTrue(committed, "the open Undo is settled first")
        AppRootCover.sceneChanged(to: .active, model: app, exportOnBackground: { exported.append(ObjectIdentifier($0)) })
        XCTAssertEqual(exported.count, 1)
    }

    /// The minute pass rests while a recording's cover is up (not only the live player's) and runs once it closes.
    func testTheMinutePassRestsWhileARecordingCoversThePages() async throws {
        let app = AppModel()
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "t", info: info))
        app.recordingPlayer(presented: true)
        var passes: [Bool] = []
        let loop = Task { @MainActor in
            await AppRootCover.keepFresh(browse, model: app, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) },
                                         pass: { passes.append($0) })
        }
        defer { loop.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(passes.isEmpty, "no pass while the recording plays")
        app.recordingPlayer(presented: false)
        try await until { !passes.isEmpty }
        XCTAssertEqual(passes.first, false, "a pass once it has closed, with the pages uncovered")
    }
}

/// Reads what `AppRootCover` puts in the environment.
private struct CoverProbe: View {
    @Environment(\.pigCoveredByPlayer) private var covered
    @Environment(\.pigRecordingPlayerCover) private var cover
    let seen: (Bool) -> Void
    let report: (@escaping @MainActor (Bool) -> Void) -> Void
    var body: some View {
        Color.clear
            .onChange(of: covered, initial: true) { _, value in seen(value) }
            .onAppear { report(cover) }
    }
}
