import XCTest
@testable import PigTV

/// D-53: the app needs a current server. A server whose build is below `ServerInfo.minimumBuild` is refused where the
/// app already refuses an unsuitable one (`validate()`, at restore, sign-in, pairing and Continue); a build that does
/// not parse is accepted.
@MainActor
final class MinimumServerTests: XCTestCase {
    private func info(build: String?) throws -> ServerInfo {
        let field = build.map { #","build":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ServerInfo.self, from: Data(
            #"{"name":"PigTV","version":"3.9.0"\#(field),"apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#.utf8))
    }

    func testABuildBelowTheMinimumIsRefusedWithItsOwnText() throws {
        for build in ["0475", "0146", "475", "1"] {
            XCTAssertThrowsError(try info(build: build).validate(), build) { error in
                XCTAssertEqual(error as? PigTVError,
                               .message("This PigTV server is too old for this app. Update the server, then try again."), build)
            }
        }
    }

    func testTheMinimumAndNewerAreAccepted() throws {
        for build in ["0476", "476", "0503", "1200"] { XCTAssertNoThrow(try info(build: build).validate(), build) }
    }

    func testABuildThatDoesNotParseIsAccepted() throws {
        for build in [nil, "", "dev", "0476-dirty"] { XCTAssertNoThrow(try info(build: build).validate(), build ?? "nil") }
    }

    /// Shown on Sign in's Continue, as the other refusals are.
    func testContinueShowsTheRefusal() async throws {
        let server = try LocalHTTPServer { request in
            request.path == "/api/info"
                ? .json(#"{"name":"PigTV","version":"3.9.0","build":"0475","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
                : .json("[]")
        }
        defer { server.stop() }
        let model = AppModel()
        model.serverText = server.baseURL
        let accepted = await model.checkServer()
        XCTAssertFalse(accepted)
        // #280: on the form, not an alert.
        XCTAssertNil(model.error)
        XCTAssertEqual(model.signInError, SignInFailure(title: "PigTV can’t use this server",
                                                        check: "This PigTV server is too old for this app. Update the server, then try again."))
    }
}
