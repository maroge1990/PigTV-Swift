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
        XCTAssertNotNil(model.error)
        accepted.value = true
        await model.restore()
        XCTAssertTrue(model.loggedIn, "the retry signs in with the same saved sign-in")
    }
}
