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
}
