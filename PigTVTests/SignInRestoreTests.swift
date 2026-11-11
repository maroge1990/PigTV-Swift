import XCTest
@testable import PigTV

/// #54 (AUD-APL-12): a single 401 at launch deleted the saved sign-in, so a passing server fault (a database restore)
/// forced the Apple TV to be paired again. The sign-in is now kept and can be retried.
@MainActor
final class SignInRestoreTests: XCTestCase {
    func testA401AtLaunchKeepsTheSavedSignInAndOffersRetry() async throws {
        let accepted = Locked(false)
        let server = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info":
                return .json(#"{"name":"PigTV","version":"3.7.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
            case "/api/auth/me":
                return accepted.value ? .json(#"{"id":1,"username":"mark","role":"admin"}"#) : .json(#"{"error":"Invalid token"}"#, status: 401)
            default:
                return .json("[]")
            }
        }
        defer { server.stop() }
        let address = try ServerAddress(server.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let model = AppModel()
        model.serverText = server.baseURL
        await model.restore()
        XCTAssertFalse(model.loggedIn)
        XCTAssertEqual(try keychain.token(for: address), "fixture-token", "the saved sign-in is kept")
        XCTAssertTrue(model.canRestore, "Retry saved sign-in is offered")
        XCTAssertNil(model.error, "#280: no alert")
        XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted", "#280: said on the form")
        accepted.value = true
        await model.restore()
        XCTAssertTrue(model.loggedIn, "the retry signs in with the same saved sign-in")
    }

    /// #55 (AUD-APL-13): launch asked info, then who is signed in, then the categories, one after another, before the
    /// app showed anything. The first two now go together and the categories are not waited for.
    func testRestoreAsksInfoAndTheUserTogetherAndDoesNotWaitForCategories() async throws {
        let server = try LocalHTTPServer { request in
            var answer: LocalHTTPServer.Response
            switch request.path {
            case "/api/info":
                answer = .json(#"{"name":"PigTV","version":"3.7.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
            case "/api/auth/me":
                answer = .json(#"{"id":1,"username":"mark","role":"admin"}"#)
            default:
                answer = .json("[]")
            }
            answer.delay = 0.5
            return answer
        }
        defer { server.stop() }
        let address = try ServerAddress(server.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let saved = UserDefaults.standard.string(forKey: "pigtv.guide.filter")
        UserDefaults.standard.set("all", forKey: "pigtv.guide.filter") // no category filter: nothing waits for them
        defer { UserDefaults.standard.set(saved, forKey: "pigtv.guide.filter") }
        let model = AppModel()
        model.serverText = server.baseURL
        let began = Date()
        await model.restore()
        let took = Date().timeIntervalSince(began)
        XCTAssertTrue(model.loggedIn)
        XCTAssertLessThan(took, 0.95, "two answers at once, categories not awaited (one after another: 1.5 s); took \(took)")
    }

    /// Apple 162 (161 Codex round 1, medium): the categories load after the tabs show, so a sign-out before it answers
    /// must not let the old session's categories (or its error) land in the next one.
    func testCategoriesThatAnswerAfterSignOutAreDropped() async throws {
        let server = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info":
                return .json(#"{"name":"PigTV","version":"3.7.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
            case "/api/auth/me":
                return .json(#"{"id":1,"username":"mark","role":"admin"}"#)
            case "/api/library/categories":
                var answer = LocalHTTPServer.Response.json(#"[{"id":"sport","sourceId":1,"name":"Sport","channelCount":3}]"#)
                answer.delay = 1
                return answer
            default:
                return .json("{}")
            }
        }
        defer { server.stop() }
        let address = try ServerAddress(server.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let model = AppModel()
        model.serverText = server.baseURL
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        try await Task.sleep(for: .milliseconds(200)) // the categories request is on its way
        await model.logout()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(model.categories.isEmpty, "the old session's categories never land after sign-out")
        XCTAssertNil(model.error)
    }

    /// Apple 163 (161 Codex round 2, medium): with a category filter saved, the guide would draw its rows before the
    /// categories arrived (Sport empty, a category showing every channel): the restore then still waits for them.
    func testASavedCategoryFilterWaitsForTheCategories() async throws {
        XCTAssertFalse(AppModel.guideFilterNeedsCategories(nil))
        XCTAssertFalse(AppModel.guideFilterNeedsCategories("all"))
        XCTAssertFalse(AppModel.guideFilterNeedsCategories("favourites"))
        XCTAssertTrue(AppModel.guideFilterNeedsCategories("sport"))
        let server = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info":
                return .json(#"{"name":"PigTV","version":"3.7.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
            case "/api/auth/me":
                return .json(#"{"id":1,"username":"mark","role":"admin"}"#)
            case "/api/library/categories":
                var answer = LocalHTTPServer.Response.json(#"[{"id":"sport","sourceId":1,"name":"Sport","channelCount":3,"sport":true}]"#)
                answer.delay = 0.5
                return answer
            default:
                return .json("{}")
            }
        }
        defer { server.stop() }
        let address = try ServerAddress(server.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let saved = UserDefaults.standard.string(forKey: "pigtv.guide.filter")
        UserDefaults.standard.set("sport", forKey: "pigtv.guide.filter")
        defer { UserDefaults.standard.set(saved, forKey: "pigtv.guide.filter") }
        let model = AppModel()
        model.serverText = server.baseURL
        await model.restore()
        XCTAssertEqual(model.categories.map(\.name), ["Sport"], "the categories are there before the guide draws")
    }

    // MARK: Review of 205 (H1, M3): where a restore that did not finish goes, and the note's life

    nonisolated private static let info = #"{"name":"PigTV","version":"3.9.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#
    nonisolated private static let tooOldInfo = #"{"name":"PigTV","version":"3.9.0","build":"0475","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#
    private static let tooOld = SignInFailure(title: "PigTV can’t use this server",
                                              check: "This PigTV server is too old for this app. Update the server, then try again.")

    /// The three answers a reachable server can give a restore that does not sign in: the saved sign-in refused (401),
    /// a server too old for this app, a server error (503).
    private enum Answer: CaseIterable { case refused, tooOld, serverError }

    private func server(_ answer: Answer) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            switch (request.path, answer) {
            case ("/api/info", .tooOld): return .json(Self.tooOldInfo)
            case ("/api/info", _): return .json(Self.info)
            case ("/api/auth/me", .refused): return .json(#"{"error":"Invalid token"}"#, status: 401)
            case ("/api/auth/me", .serverError): return .json(#"{"error":"Starting"}"#, status: 503)
            case ("/api/auth/me", _): return .json(#"{"id":1,"username":"mark","role":"admin"}"#)
            default: return .json("[]")
            }
        }
    }

    /// An address nothing answers on (a server that was listening there has stopped): the restore's network failure.
    private func deadAddress() throws -> String {
        let gone = try LocalHTTPServer { _ in .notFound }
        let address = gone.baseURL
        gone.stop()
        return address
    }

    private func assertOutcome(_ model: AppModel, after answer: Answer, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.loggedIn, context, file: file, line: line)
        XCTAssertNil(model.error, "no alert: \(context)", file: file, line: line)
        switch answer {
        case .refused:
            XCTAssertNil(model.unreachable, "Offline gives way to Sign in: \(context)", file: file, line: line)
            XCTAssertEqual(model.signInError?.title, "Your saved sign-in wasn’t accepted", context, file: file, line: line)
            XCTAssertEqual(model.signInRetry, .saved, "its Try again retries the saved sign-in: \(context)", file: file, line: line)
            XCTAssertTrue(model.canRestore, context, file: file, line: line)
        case .tooOld:
            XCTAssertNil(model.unreachable, "Offline gives way to Sign in: \(context)", file: file, line: line)
            XCTAssertEqual(model.signInError, Self.tooOld, "the minimum-server words, as Continue says them: \(context)",
                           file: file, line: line)
            XCTAssertEqual(model.signInRetry, .saved, "Try again once the server is updated: \(context)", file: file, line: line)
        case .serverError:
            XCTAssertEqual(model.unreachable, .notReady, "the Offline screen says the server is not ready and keeps trying: \(context)",
                           file: file, line: line)
            XCTAssertNil(model.signInError, context, file: file, line: line)
        }
    }

    /// Before: a refusal answered to the Offline screen's retry set Sign in's note while the Offline screen stayed up
    /// ("Can’t reach PigTV", retrying every 20 s for ever); the note was never seen.
    func testEachAnswerToTheOfflineScreensRetryLeavesForTheScreenThatSaysIt() async throws {
        let keychain = KeychainStore()
        for answer in Answer.allCases {
            let dead = try deadAddress()
            let live = try server(answer)
            defer { live.stop() }
            for address in [dead, live.baseURL] { try keychain.save(token: "fixture-token", for: try ServerAddress(address)) }
            defer { for address in [dead, live.baseURL] { try? keychain.remove(for: try ServerAddress(address)) } }
            let model = AppModel()
            model.serverText = dead
            await model.restore()
            XCTAssertEqual(model.unreachable?.title, OfflineNotice.unreachableTitle, "\(answer): first, no answer: Offline")
            XCTAssertNil(model.signInError)
            // The server answers the Offline screen's next attempt (it came back on another port: the same retry).
            model.serverText = live.baseURL
            await model.restore()
            assertOutcome(model, after: answer, "\(answer) from the Offline screen")
        }
    }

    func testEachAnswerAtAColdStartGoesToTheScreenThatSaysIt() async throws {
        let keychain = KeychainStore()
        for answer in Answer.allCases {
            let live = try server(answer)
            defer { live.stop() }
            let address = try ServerAddress(live.baseURL)
            try keychain.save(token: "fixture-token", for: address)
            defer { try? keychain.remove(for: address) }
            let model = AppModel()
            model.serverText = live.baseURL
            await model.restore()
            assertOutcome(model, after: answer, "\(answer) at a cold start")
        }
    }

    func testWhereARestoreThatDidNotFinishGoes() {
        XCTAssertEqual(AppModel.restoreOutcome(URLError(.cannotConnectToHost)), .offline(.unreachable))
        XCTAssertEqual(AppModel.restoreOutcome(URLError(.timedOut)),
                       .offline(OfflineNotice(title: OfflineNotice.unreachableTitle,
                                              message: "PigTV did not answer in time. It may be asleep or busy.")))
        for status in [500, 502, 503] { XCTAssertEqual(AppModel.restoreOutcome(PigTVError.http(status)), .offline(.notReady), "\(status)") }
        for error: Error in [PigTVError.unauthorised, PigTVError.forbidden, PigTVError.http(404), PigTVError.decoding,
                             PigTVError.rateLimited(retryAfterSec: 60), PigTVError.message("too old")] {
            XCTAssertEqual(AppModel.restoreOutcome(error), .signIn, "\(error)")
        }
    }

    /// Before: the note stayed after "Try again" signed in, and showed again on the sign-in form after a later Sign out;
    /// editing the form left the last attempt's note up too.
    func testTheNoteGoesOnSuccessOnSignOutAndWhenTheFormIsEdited() async throws {
        let accepted = Locked(false)
        let live = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info": return .json(Self.info)
            case "/api/auth/me":
                return accepted.value ? .json(#"{"id":1,"username":"mark","role":"admin"}"#) : .json(#"{"error":"Invalid token"}"#, status: 401)
            default: return .json("[]")
            }
        }
        defer { live.stop() }
        let address = try ServerAddress(live.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let model = AppModel()
        model.serverText = live.baseURL
        await model.restore()
        XCTAssertNotNil(model.signInError)
        model.username = "m"
        XCTAssertNil(model.signInError, "editing the form starts a new attempt")
        XCTAssertNil(model.signInRetry)
        await model.restore()
        XCTAssertNotNil(model.signInError)
        accepted.value = true
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        XCTAssertNil(model.signInError, "Try again signed in: the note is gone")
        await model.logout()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(model.signInError, "never on a fresh sign-in form after Sign out")
    }

    // MARK: Review of 205 (M2): the note's Try again retries the attempt that failed

    func testTryAgainRetriesTheAttemptThatFailedAndOnlyWhereItCanHelp() async throws {
        XCTAssertEqual(SignInFailure.retry(after: PigTVError.unauthorised, step: .saved), .saved)
        XCTAssertEqual(SignInFailure.retry(after: PigTVError.message("too old"), step: .saved), .saved)
        XCTAssertNil(SignInFailure.retry(after: PigTVError.unauthorised, step: .password), "a wrong password: nothing to retry")
        XCTAssertNil(SignInFailure.retry(after: PigTVError.message("The pairing code expired. Request another code."), step: .pairing))
        XCTAssertNil(SignInFailure.retry(after: PigTVError.rateLimited(retryAfterSec: 60), step: .password), "wait, then sign in")
        XCTAssertNil(SignInFailure.retry(after: PigTVError.forbidden, step: .password))
        XCTAssertEqual(SignInFailure.retry(after: URLError(.timedOut), step: .server), .server)
        XCTAssertEqual(SignInFailure.retry(after: URLError(.cannotConnectToHost), step: .password), .password)
        XCTAssertEqual(SignInFailure.retry(after: PigTVError.http(503), step: .pairing), .pairing)
        XCTAssertNil(SignInFailure.retry(after: CancellationError(), step: .saved))

        // A wrong password typed while a saved sign-in exists: the note's button is not the saved sign-in.
        let live = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info": return .json(Self.info)
            case "/api/auth/me": return .json(#"{"error":"Invalid token"}"#, status: 401)
            case "/api/auth/login": return .json(#"{"error":"Invalid username or password"}"#, status: 401)
            default: return .json("[]")
            }
        }
        defer { live.stop() }
        let address = try ServerAddress(live.baseURL)
        let keychain = KeychainStore()
        try keychain.save(token: "fixture-token", for: address)
        defer { try? keychain.remove(for: address) }
        let model = AppModel()
        model.serverText = live.baseURL
        await model.restore()
        XCTAssertEqual(model.signInRetry, .saved)
        model.username = "mark"
        model.password = "wrong"
        await model.login()
        XCTAssertTrue(model.canRestore, "the saved sign-in is still there")
        XCTAssertEqual(model.signInError?.title, "That username or password wasn’t accepted")
        XCTAssertNil(model.signInRetry, "no Try again under a wrong password (it ran the saved sign-in before)")
    }
}
