import XCTest
@testable import PigTV

/// D-44 batch 6 (Apple 131): Sign in is the server first, then the two tiles.
final class SignInStepTests: XCTestCase {
    func testSignInOpensOnTheTilesWhenAServerIsKnownUnlessADifferentOneWasAskedFor() {
        XCTAssertEqual(SignInStep.opening(server: "", askServer: false), .server)
        XCTAssertEqual(SignInStep.opening(server: "  ", askServer: false), .server)
        XCTAssertEqual(SignInStep.opening(server: "http://pigtv.local:3000", askServer: false), .method)
        XCTAssertEqual(SignInStep.opening(server: "http://pigtv.local:3000", askServer: true), .server, "Use a different server")
    }

    func testTheServerChipShowsTheAddressWithoutItsScheme() {
        XCTAssertEqual(SignInStep.shortAddress("http://pigtv.local:3000/"), "pigtv.local:3000")
        XCTAssertEqual(SignInStep.shortAddress("HTTPS://tv.example"), "tv.example")
        XCTAssertEqual(SignInStep.shortAddress("pigtv.local"), "pigtv.local")
    }
}
