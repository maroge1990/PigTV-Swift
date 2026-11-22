import XCTest
@testable import PigTV

/// #54: signing in with a password and pairing, driven against a local server with the real Keychain (each test's server
/// has its own port, so its saved sign-in is its own and is removed afterwards; the saved server address is put back).
/// And a 401 in the middle of a session: one confirming `auth/me` with the saved token; only a second 401 leaves for
/// Sign in, where a 401 at launch leaves (the saved sign-in kept and offered again). The token is never removed.
@MainActor
final class SignInFlowTests: XCTestCase {
    private static let info = #"{"name":"PigTV","version":"3.7.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#
    private static let me = #"{"id":1,"username":"mark","role":"admin"}"#
    private var savedServer: String?
    private var cleanups: [() -> Void] = []

    override func setUp() async throws {
        savedServer = UserDefaults.standard.string(forKey: "pigtv.server")
    }

    override func tearDown() async throws {
        cleanups.reversed().forEach { $0() }
        cleanups = []
        UserDefaults.standard.set(savedServer, forKey: "pigtv.server")
    }

    /// A server for `routes` (path → answer; anything else `[]`), stopped and its Keychain entry removed afterwards.
    private func server(_ routes: @escaping @Sendable (LocalHTTPServer.Request) -> LocalHTTPServer.Response?) throws
        -> (LocalHTTPServer, ServerAddress) {
        let server = try LocalHTTPServer { request in
            if let answer = routes(request) { return answer }
            switch request.path {
            case "/api/info": return .json(Self.info)
            default: return .json("[]")
            }
        }
        let address = try ServerAddress(server.baseURL)
        cleanups.append { server.stop(); try? KeychainStore().remove(for: address) }
        return (server, address)
    }

    private func requests(_ server: LocalHTTPServer, _ path: String) -> Int {
        server.requests.filter { $0.path == path }.count
    }

    private func eventually(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ok(), what, file: file, line: line)
    }

    // MARK: Username and password

    func testASignInSavesTheTokenAndLandsSignedIn() async throws {
        let (server, address) = try server { request in
            switch (request.method, request.path) {
            case ("POST", "/api/auth/login"): return .json(#"{"token":"login-token","user":\#(Self.me)}"#)
            default: return nil
            }
        }
        let model = AppModel()
        model.serverText = server.baseURL
        model.username = "mark"
        model.password = "secret"
        await model.login()
        XCTAssertTrue(model.loggedIn)
        XCTAssertEqual(try KeychainStore().token(for: address), "login-token")
        XCTAssertNotNil(model.browse)
        XCTAssertEqual(model.password, "", "the password is not kept")
        XCTAssertNil(model.signInError)
        let login = try XCTUnwrap(server.requests.first { $0.path == "/api/auth/login" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: login.body) as? [String: String], ["username": "mark", "password": "secret"])
    }

    func testARefusedSignInSaysSoAndSavesNothing() async throws {
        let (server, address) = try server { request in
            request.path == "/api/auth/login" ? .json(#"{"error":"Invalid username or password"}"#, status: 401) : nil
        }
        let model = AppModel()
        model.serverText = server.baseURL
        model.username = "mark"
        model.password = "wrong"
        await model.login()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(try KeychainStore().token(for: address), "nothing is saved")
        XCTAssertEqual(model.signInError?.title, "That username or password wasn’t accepted")
        XCTAssertNil(model.signInRetry, "trying the same again cannot help")
        XCTAssertEqual(model.password, "wrong", "what was typed is kept")
    }

    func testTooManyAttemptsSaysHowLongToWait() async throws {
        let (server, address) = try server { request in
            request.path == "/api/auth/login" ? .json(#"{"error":"Too many attempts","retryAfterSec":120}"#, status: 429) : nil
        }
        let model = AppModel()
        model.serverText = server.baseURL
        model.username = "mark"
        model.password = "wrong"
        await model.login()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(try KeychainStore().token(for: address))
        XCTAssertEqual(model.signInError?.title, "Too many attempts")
        XCTAssertEqual(model.signInError?.check, "Wait 2 minutes, then try again.")
        // A second attempt meanwhile asks nothing.
        await model.login()
        XCTAssertEqual(requests(server, "/api/auth/login"), 1)
    }

    // MARK: Pairing

    /// A pairing server: `start` answers a code expiring `expiresIn` seconds from now; each poll answers `poll(n)` (n from 1).
    private func pairingServer(expiresIn: TimeInterval = 60, poll: @escaping @Sendable (Int) -> String)
        throws -> (LocalHTTPServer, ServerAddress) {
        let polls = Locked(0)
        return try server { request in
            switch request.path {
            case "/api/devices/pair/start":
                let at = (Date().timeIntervalSince1970 + expiresIn) * 1000
                return .json(#"{"code":"ABCD12","expiresAt":\#(at),"expiresInSec":\#(Int(expiresIn))}"#)
            case "/api/devices/pair/poll":
                polls.value += 1
                return .json(poll(polls.value))
            case "/api/auth/me":
                return .json(Self.me)
            default: return nil
            }
        }
    }

    func testPairingShowsTheCodePollsAndAnApprovalSavesTheTokenAndSignsIn() async throws {
        let (server, address) = try pairingServer { n in
            n < 2 ? #"{"status":"pending"}"# : #"{"status":"approved","token":"paired-token"}"#
        }
        let model = AppModel()
        model.serverText = server.baseURL
        model.startPairing()
        try await eventually("the code is shown") { model.pairing?.code == "ABCD12" }
        XCTAssertTrue(model.authBusy)
        // Signed in once the token is accepted; the pairing is over once its categories have loaded too.
        try await eventually("approved after the second poll", timeout: 15) { model.loggedIn && !model.authBusy }
        XCTAssertEqual(try KeychainStore().token(for: address), "paired-token")
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.authBusy)
        XCTAssertEqual(requests(server, "/api/devices/pair/poll"), 2)
        let poll = try XCTUnwrap(server.requests.first { $0.path == "/api/devices/pair/poll" })
        XCTAssertEqual(poll.query, "code=ABCD12")
        let me = try XCTUnwrap(server.requests.first { $0.path == "/api/auth/me" })
        XCTAssertEqual(me.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer paired-token")
    }

    func testADeniedOrExpiredCodeSaysSoAndSavesNothing() async throws {
        let (server, address) = try pairingServer { _ in #"{"status":"expired"}"# }
        let model = AppModel()
        model.serverText = server.baseURL
        model.startPairing()
        try await eventually("the refusal is said", timeout: 15) { model.signInError != nil }
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(try KeychainStore().token(for: address))
        XCTAssertEqual(model.signInError?.title, "Pairing didn’t finish")
        XCTAssertEqual(model.signInError?.check, "This pairing code is no longer available. Request another code.")
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.authBusy)
    }

    func testACodePastItsExpiryStopsPolling() async throws {
        let (server, address) = try pairingServer(expiresIn: 1) { _ in #"{"status":"pending"}"# }
        let model = AppModel()
        model.serverText = server.baseURL
        model.startPairing()
        try await eventually("the expiry is said", timeout: 15) { model.signInError != nil }
        XCTAssertEqual(model.signInError?.check, "The pairing code expired. Request another code.")
        XCTAssertNil(try KeychainStore().token(for: address))
        let polls = requests(server, "/api/devices/pair/poll")
        XCTAssertLessThanOrEqual(polls, 1)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(requests(server, "/api/devices/pair/poll"), polls, "no poll after the code expired")
    }

    func testCancellingPairingStopsThePolling() async throws {
        let (server, address) = try pairingServer { _ in #"{"status":"pending"}"# }
        let model = AppModel()
        model.serverText = server.baseURL
        model.startPairing()
        try await eventually("the code is shown") { model.pairing != nil }
        model.cancelPairing()
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.authBusy)
        let polls = requests(server, "/api/devices/pair/poll")
        try await Task.sleep(for: .seconds(5)) // two polling intervals
        XCTAssertEqual(requests(server, "/api/devices/pair/poll"), polls, "no request after Cancel")
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(model.signInError, "a cancel is not a failure")
        XCTAssertNil(try KeychainStore().token(for: address))
    }

    // MARK: A 401 mid-session

    /// What `auth/me` answers once signed in (the confirming call).
    enum Confirm: Sendable { case accepted, refused, dropped, failing }

    /// Signed in by a restore with a saved token, on a server whose `library/favourites` answers 401 (an authenticated
    /// request refused mid-session) and whose `auth/me` answers `confirm` after the restore's, `delay` late.
    private func signedIn(confirm: Confirm, delay: TimeInterval = 0) async throws
        -> (AppModel, LocalHTTPServer, ServerAddress, Locked<Int>) {
        let confirms = Locked(-1) // the restore's own auth/me is 0
        let (server, address) = try server { request in
            switch request.path {
            case "/api/auth/me":
                confirms.value += 1
                guard confirms.value > 0 else { return .json(Self.me) }
                var answer: LocalHTTPServer.Response = switch confirm {
                case .accepted: .json(Self.me)
                case .refused: .json(#"{"error":"Invalid token"}"#, status: 401)
                case .failing: .json(#"{"error":"Database unavailable"}"#, status: 503)
                case .dropped: { var r = LocalHTTPServer.Response.json("{}"); r.drop = true; return r }()
                }
                answer.delay = delay
                return answer
            case "/api/library/favourites":
                return .json(#"{"error":"Invalid token"}"#, status: 401)
            default: return nil
            }
        }
        try KeychainStore().save(token: "saved-token", for: address)
        let model = AppModel()
        model.serverText = server.baseURL
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        return (model, server, address, confirms)
    }

    private func refuseOneRequest(_ model: AppModel) async throws {
        let browse = try XCTUnwrap(model.browse)
        await browse.loadFavourites()
    }

    func testA401ConfirmedByASecond401LandsOnSignInWithTheTokenKept() async throws {
        let (model, server, address, confirms) = try await signedIn(confirm: .refused)
        try await refuseOneRequest(model)
        try await eventually("Sign in, as after a 401 at launch") { !model.loggedIn }
        XCTAssertEqual(confirms.value, 1, "one confirming call")
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token", "the saved sign-in is kept")
        XCTAssertTrue(model.canRestore, "Retry saved sign-in is offered")
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted")
        XCTAssertEqual(model.signInRetry, .saved)
        XCTAssertNil(model.unreachable)
        XCTAssertNil(model.browse)
        XCTAssertNil(model.error, "no alert")
        let confirm = try XCTUnwrap(server.requests.last { $0.path == "/api/auth/me" })
        XCTAssertEqual(confirm.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer saved-token",
                       "confirmed with the saved token")
    }

    func testA401ThatTheConfirmingCallAcceptsChangesNothing() async throws {
        let (model, _, address, confirms) = try await signedIn(confirm: .accepted)
        try await refuseOneRequest(model)
        try await eventually("the confirming call is answered") { confirms.value == 1 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(model.loggedIn)
        XCTAssertNotNil(model.browse)
        XCTAssertNil(model.signInError)
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token")
        // Rate-limited: another 401 within 30 s asks again nothing.
        try await refuseOneRequest(model)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(confirms.value, 1, "at most one confirming call per 30 s")
        XCTAssertTrue(model.loggedIn)
    }

    func testTenSimultaneous401sMakeOneConfirmingCall() async throws {
        let (model, _, address, confirms) = try await signedIn(confirm: .refused, delay: 0.5)
        let client = try XCTUnwrap(model.browse?.client)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { @MainActor in _ = try? await client.response("library/favourites") }
            }
        }
        try await eventually("Sign in") { !model.loggedIn }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(confirms.value, 1, "one confirming call for ten 401s")
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token")
        XCTAssertTrue(model.canRestore)
    }

    func testA401ThenANetworkErrorChangesNothing() async throws {
        let (model, _, address, confirms) = try await signedIn(confirm: .dropped)
        try await refuseOneRequest(model)
        // (The URL loading system may send a GET whose connection dropped once more: still one confirming call.)
        try await eventually("the confirming call is made") { confirms.value >= 1 }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(model.loggedIn)
        XCTAssertNil(model.signInError)
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token")
    }

    func testA401ThenAServerErrorChangesNothing() async throws {
        let (model, _, address, confirms) = try await signedIn(confirm: .failing)
        try await refuseOneRequest(model)
        try await eventually("the confirming call is made") { confirms.value == 1 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(model.loggedIn)
        XCTAssertNil(model.signInError)
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token")
    }

    /// After a confirmed refusal, Retry saved sign-in (a restore) signs in again with the same saved token.
    func testRetryAfterAConfirmedRefusalSignsInAgain() async throws {
        let accepted = Locked(true)
        let (server, address) = try server { request in
            switch request.path {
            case "/api/auth/me": return accepted.value ? .json(Self.me) : .json(#"{"error":"Invalid token"}"#, status: 401)
            case "/api/library/favourites":
                return accepted.value ? .json("[]") : .json(#"{"error":"Invalid token"}"#, status: 401)
            default: return nil
            }
        }
        _ = server
        try KeychainStore().save(token: "saved-token", for: address)
        let model = AppModel()
        model.serverText = server.baseURL
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        accepted.value = false
        try await refuseOneRequest(model)
        try await eventually("Sign in") { !model.loggedIn }
        accepted.value = true
        await model.restore()
        XCTAssertTrue(model.loggedIn, "the same saved sign-in works again")
        XCTAssertEqual(try KeychainStore().token(for: address), "saved-token")
    }
}
