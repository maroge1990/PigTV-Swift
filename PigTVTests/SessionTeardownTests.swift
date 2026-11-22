import XCTest
@testable import PigTV

/// #54 (Codex review of 394): what a session's end leaves behind. A confirmed refusal (or Sign out) dropped the browse
/// model but left the shared presenter's page, its queue and the actions waiting for it, which the next session (another
/// server or account) would reopen; a play link arriving while the refused session's play was being stopped replaced it,
/// and the session never ended; the stream's release on the refused token raised an alert over Sign in. Each test failed
/// on 394. Live plays run for real (the real-playback harness's fake server and fixture).
@MainActor
final class SessionTeardownTests: XCTestCase {
    nonisolated private static let me = #"{"id":1,"username":"mark","role":"admin"}"#
    nonisolated private static let info = #"{"name":"PigTV","version":"3.9.0","build":"0503","apiVersion":1,"features":{"library":true,"playbackResolve":true,"viewerConflict":true}}"#
    private var cleanups: [() -> Void] = []
    private var savedServer: String?
    private var deadline: Duration?

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "pigtv.server")
        deadline = AppModel.playerAppearDeadline
        AppModel.playerAppearDeadline = nil // no player screen here
    }

    override func tearDown() async throws {
        cleanups.reversed().forEach { $0() }
        cleanups = []
        UserDefaults.standard.set(savedServer, forKey: "pigtv.server")
        AppModel.playerAppearDeadline = deadline
    }

    private func eventually(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ok(), what, file: file, line: line)
    }

    /// The answers of a server that signs in until `refused` is set, then refuses everything with 401.
    nonisolated private static func signIn(_ refused: Locked<Bool>, _ request: LocalHTTPServer.Request) -> LocalHTTPServer.Response? {
        switch request.path {
        case "/api/info": return .json(info)
        case "/api/auth/me": return refused.value ? .json(#"{"error":"Invalid token"}"#, status: 401) : .json(me)
        case "/api/library/categories": return .json("[]")
        case "/api/library/favourites":
            return refused.value ? .json(#"{"error":"Invalid token"}"#, status: 401) : .json("[]")
        default: return nil
        }
    }

    /// A plain server for `routes` (else `[]`), with a saved sign-in, removed afterwards.
    private func plainServer(_ routes: @escaping @Sendable (LocalHTTPServer.Request) -> LocalHTTPServer.Response?) throws
        -> (LocalHTTPServer, ServerAddress) {
        let server = try LocalHTTPServer { routes($0) ?? .json("[]") }
        let address = try ServerAddress(server.baseURL)
        try KeychainStore().save(token: "saved-token", for: address)
        cleanups.append { server.stop(); try? KeychainStore().remove(for: address) }
        return (server, address)
    }

    private func signedIn(at url: String) async throws -> AppModel {
        let model = AppModel()
        model.serverText = url
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        return model
    }

    private func refuse(_ model: AppModel, _ refused: Locked<Bool>) async throws {
        refused.value = true
        await model.browse?.loadFavourites()
        try await eventually("Sign in, as after a 401 at launch") { !model.loggedIn }
    }

    // MARK: 1. the presenter

    func testAConfirmedRefusalWithARecordPageOpenLeavesNothingForTheNextSession() async throws {
        let refused = Locked(false)
        let (a, _) = try plainServer { Self.signIn(refused, $0) }
        let (b, _) = try plainServer { Self.signIn(Locked(false), $0) }
        let model = try await signedIn(at: a.baseURL)
        let browse = try XCTUnwrap(model.browse)
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        let channel = SportEventChannel(sourceId: 1, rawID: "fox-old", name: "Fox", startTime: Double(start), endTime: Double(start + 3_600_000))
        let event = SportEvent(id: "old-event", title: "B v C", league: "AFL", startTime: Double(start),
                               endTime: Double(start + 3_600_000), channels: [channel])
        let request = try XCTUnwrap(browse.recordRequest(event: event, card: "espn:afl:old"))
        model.presenter.present(.record(request))
        XCTAssertNotNil(model.presenter.presented)
        try await refuse(model, refused)
        XCTAssertNil(model.presenter.presented, "the Record page of the ended session is closed")
        XCTAssertNil(model.presenter.queued)
        model.presenter.didDismiss() // the host's late onDismiss for it
        // Signed in again, to another server.
        model.serverText = b.baseURL
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        XCTAssertNil(model.presenter.presented, "nothing of the old session is presented in the new one")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(b.requests.contains { $0.path.contains("fox-old") || ($0.query ?? "").contains("fox-old") },
                       "no request for the old session's item reaches the new server")
    }

    func testSignOutDropsTheQueuedPageAndTheActionsWaitingForIt() async throws {
        let (a, _) = try plainServer { Self.signIn(Locked(false), $0) }
        let model = try await signedIn(at: a.baseURL)
        let decode = { (id: Int) in
            try JSONDecoder().decode(Recording.self, from: Data(#"{"id":\#(id),"title":"News","status":"completed","channel_name":"A"}"#.utf8))
        }
        let ran = Locked(false)
        model.presenter.present(.recording(try decode(1)))
        model.presenter.dismiss { ran.value = true } // e.g. a Watch from the page, once it has closed
        model.presenter.present(.recording(try decode(2))) // queued behind the closing one
        XCTAssertNotNil(model.presenter.queued)
        await model.logout()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(model.presenter.presented)
        XCTAssertNil(model.presenter.queued, "the queued page is dropped")
        model.presenter.didDismiss() // the host's onDismiss for the page that was closing
        XCTAssertNil(model.presenter.presented, "the queued page does not open after Sign out")
        XCTAssertFalse(ran.value, "an action waiting for the page to close never runs on the ended session")
    }

    // MARK: 2 and 3. a live play

    private func requireFixture() throws {
        guard HLSFixture.isComplete else { throw XCTSkip("no fixture") }
    }

    /// A live play on the fake server, signed in by a restore, running (its session `s1` resolved).
    private func playing(release: @escaping @Sendable () -> LocalHTTPServer.Response?, refused: Locked<Bool>) async throws
        -> (AppModel, FakePigTVServer) {
        try requireFixture()
        let server = try FakePigTVServer(routes: .init { request in
            if request.method == "DELETE", request.path.hasPrefix("/api/playback/"), let answer = release() { return answer }
            return Self.signIn(refused, request)
        })
        let address = try ServerAddress(server.http.baseURL)
        try KeychainStore().save(token: "saved-token", for: address)
        cleanups.append { server.http.stop(); try? KeychainStore().remove(for: address) }
        let model = try await signedIn(at: server.http.baseURL)
        model.beginPlayback(Channel(rawID: "harness-a", sourceId: 1, name: "Harness", logo: nil, category: nil, now: nil, next: nil))
        let playback = try XCTUnwrap(model.playback)
        playback.start()
        try await eventually("the play is resolved and installed") { playback.ready }
        return (model, server)
    }

    func testAPlayLinkDuringTheRefusedSessionsStopIsDroppedAndTheSessionEnds() async throws {
        let refused = Locked(false)
        let slowRelease = Locked(false)
        let (model, server) = try await playing(release: {
            guard slowRelease.value else { return nil }
            var answer = LocalHTTPServer.Response.json(#"{"success":true}"#)
            answer.delay = 1.5 // the stop is suspended here
            return answer
        }, refused: refused)
        slowRelease.value = true
        refused.value = true
        await model.browse?.loadFavourites()
        try await eventually("the stop is releasing the stream") {
            server.http.requests(path: "/api/playback/s1", method: "DELETE").count == 1
        }
        model.open(try XCTUnwrap(URL(string: "pigtv://play?sourceId=1&id=harness-b")))
        try await eventually("the session still ends") { !model.loggedIn }
        XCTAssertNil(model.playback, "nothing plays")
        XCTAssertFalse(model.playerPresented)
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted")
        // Signed in again: the link was dropped, not kept for this session.
        refused.value = false
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(model.playback, "the link is not played in the next session")
        XCTAssertEqual(server.resolves.count, 1, "only the first play was ever resolved")
    }

    func testARefusedReleaseShowsSignInWithNoAlert() async throws {
        let refused = Locked(false)
        let (model, server) = try await playing(release: {
            refused.value ? .json(#"{"error":"Invalid token"}"#, status: 401) : nil
        }, refused: refused)
        refused.value = true
        await model.browse?.loadFavourites()
        try await eventually("Sign in, as after a 401 at launch") { !model.loggedIn }
        XCTAssertEqual(server.http.requests(path: "/api/playback/s1", method: "DELETE").count, 1, "the release was tried")
        XCTAssertNil(model.error, "no alert over Sign in")
        XCTAssertTrue(model.canRestore)
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted")
        XCTAssertNil(model.playback)
        XCTAssertEqual(server.http.requests(path: "/api/auth/me").count, 2, "the restore's and one confirming call")
    }

    // MARK: Codex sign-off of 395

    /// A refused play whose release is answered 401 after `delay`, its stop then suspended for that long.
    private func refusedPlayWithSlowRelease(_ delay: TimeInterval = 1.5) async throws -> (AppModel, FakePigTVServer, Locked<Bool>) {
        let refused = Locked(false)
        let (model, server) = try await playing(release: {
            guard refused.value else { return nil }
            var answer = LocalHTTPServer.Response.json(#"{"error":"Invalid token"}"#, status: 401)
            answer.delay = delay
            return answer
        }, refused: refused)
        return (model, server, refused)
    }

    private func releaseAsked(_ server: FakePigTVServer) async throws {
        try await eventually("the stop is releasing the stream") {
            server.http.requests(path: "/api/playback/s1", method: "DELETE").count >= 1
        }
    }

    /// A link that arrives while the scene is inactive and the refused session is ending is never played, not even after
    /// a Retry within a minute (it was held by the link gate, delivered after the teardown, kept as pending, played).
    func testALinkHeldWhileTheRefusedSessionEndsIsNotPlayedAfterRetry() async throws {
        let (model, server, refused) = try await refusedPlayWithSlowRelease()
        var gate = LinkGate()
        gate.sceneChanged(active: true, into: model)
        gate.sceneChanged(active: false, into: model) // the scene goes inactive
        refused.value = true
        await model.browse?.loadFavourites()
        try await releaseAsked(server)
        gate.receive(try XCTUnwrap(URL(string: "pigtv://play?sourceId=1&id=harness-b")), into: model)
        try await eventually("the session ends") { !model.loggedIn }
        gate.sceneChanged(active: true, into: model) // active again: the gate releases what it holds
        refused.value = false
        await model.restore() // Retry
        XCTAssertTrue(model.loggedIn)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(model.playback, "the link is not played")
        XCTAssertEqual(server.resolves.count, 1)
    }

    /// The trip to the background joins the refused teardown's stop (one shared stop task) and may finish first: its
    /// release failure must not become an alert over Sign in either.
    func testTheBackgroundsStopJoiningARefusedReleaseShowsNoAlert() async throws {
        let (model, server, refused) = try await refusedPlayWithSlowRelease()
        refused.value = true
        await model.browse?.loadFavourites() // the refusal, confirmed: the teardown's stop releases the stream
        try await releaseAsked(server)
        await model.background() // the trip to the background joins the same stop, and finishes first
        try await eventually("Sign in") { !model.loggedIn }
        XCTAssertNil(model.error, "no alert over Sign in")
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted")
    }

    /// A page's dismissal reported while the teardown waits for the stop runs nothing and opens nothing.
    func testADismissalDuringTheSuspendedStopRunsNothingAndPresentsNothing() async throws {
        let (model, server, refused) = try await refusedPlayWithSlowRelease()
        let decode = { (id: Int) in
            try JSONDecoder().decode(Recording.self, from: Data(#"{"id":\#(id),"title":"News","status":"completed","channel_name":"A"}"#.utf8))
        }
        let ran = Locked(false)
        model.presenter.present(.recording(try decode(1)))
        model.presenter.dismiss { ran.value = true }
        model.presenter.present(.recording(try decode(2)))
        refused.value = true
        await model.browse?.loadFavourites()
        try await releaseAsked(server)
        model.presenter.didDismiss() // the host's onDismiss, during the stop
        XCTAssertFalse(ran.value, "an action of the ending session ran")
        XCTAssertNil(model.presenter.presented, "a page opened while the session ends")
        try await eventually("Sign in") { !model.loggedIn }
        XCTAssertFalse(ran.value)
        XCTAssertNil(model.presenter.presented)
    }

    // MARK: Codex sign-off of 396

    /// A live play whose release answers `release` once `refusing` is set, on a server whose confirming `auth/me` then
    /// answers `confirm` (401 or 200) after `confirmDelay`.
    private func backgroundPlay(release: LocalHTTPServer.Response, confirmRefuses: Bool, confirmDelay: TimeInterval = 1.5)
        async throws -> (AppModel, FakePigTVServer, Locked<Bool>) {
        try requireFixture()
        let refusing = Locked(false)
        let server = try FakePigTVServer(routes: .init { request in
            switch (request.method, request.path) {
            case ("GET", "/api/info"): return .json(Self.info)
            case ("GET", "/api/library/categories"): return .json("[]")
            case ("GET", "/api/auth/me"):
                guard refusing.value else { return .json(Self.me) }
                var answer = confirmRefuses ? LocalHTTPServer.Response.json(#"{"error":"Invalid token"}"#, status: 401) : .json(Self.me)
                answer.delay = confirmDelay
                return answer
            default:
                if request.method == "DELETE", request.path.hasPrefix("/api/playback/"), refusing.value { return release }
                return nil
            }
        })
        let address = try ServerAddress(server.http.baseURL)
        try KeychainStore().save(token: "saved-token", for: address)
        cleanups.append { server.http.stop(); try? KeychainStore().remove(for: address) }
        let model = try await signedIn(at: server.http.baseURL)
        model.beginPlayback(Channel(rawID: "harness-a", sourceId: 1, name: "Harness", logo: nil, category: nil, now: nil, next: nil))
        let playback = try XCTUnwrap(model.playback)
        playback.start()
        try await eventually("the play is resolved and installed") { playback.ready }
        return (model, server, refusing)
    }

    /// The trip to the background stops the play first; its release is answered 401, which starts the refusal check, and
    /// the stop returns before the check is answered, and its failure is shown. The check then confirms the refusal:
    /// Sign in, with no alert (the teardown takes the old session's alert down; on 396 it stayed over Sign in).
    func testABackgroundReleaseRefusedBeforeTheCheckConfirmsShowsSignInWithNoAlert() async throws {
        let (model, server, refusing) = try await backgroundPlay(release: .json(#"{"error":"Invalid token"}"#, status: 401),
                                                                 confirmRefuses: true)
        refusing.value = true
        await model.background()
        XCTAssertEqual(server.http.requests(path: "/api/playback/s1", method: "DELETE").count, 1)
        try await eventually("Sign in, once the check confirms the refusal") { !model.loggedIn }
        XCTAssertNil(model.error, "no alert over Sign in")
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted")
    }

    /// The same, but the check does not confirm a refusal: the session stays and the release's failure is shown (at once).
    func testABackgroundReleaseRefusedButNotConfirmedStillShowsItsFailure() async throws {
        let (model, _, refusing) = try await backgroundPlay(release: .json(#"{"error":"Invalid token"}"#, status: 401),
                                                            confirmRefuses: false)
        refusing.value = true
        await model.background()
        try await eventually("the release's failure is shown once the check is answered") { model.error != nil }
        XCTAssertTrue(model.loggedIn)
    }

    /// A release that fails with no 401 at all is shown at once, as before.
    func testABackgroundReleaseFailingWithoutARefusalIsShown() async throws {
        let (model, _, refusing) = try await backgroundPlay(release: .json(#"{"error":"boom"}"#, status: 500),
                                                            confirmRefuses: false)
        refusing.value = true
        await model.background()
        XCTAssertNotNil(model.error, "the release's failure is shown")
        XCTAssertTrue(model.loggedIn)
    }
}
