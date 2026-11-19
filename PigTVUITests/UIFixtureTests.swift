import XCTest

// #351: the UI tests' fixtures are in the UI test bundle, so they run on a test runner without the source tree (Xcode
// Cloud). Before, the tests read PigTVTests/Fixtures through #filePath (no UIFixture: fails to compile on Apple 335).
final class UIFixtureTests: XCTestCase {
    func testEveryFixtureTheUITestsReadIsInTheBundle() throws {
        for name in ["cricket-page-0387-live.json", "cricket-page-0387-stumps.json", "f1-page-0346.json", "nfl-page-0379.json",
                     "sport-front-0381.json", "sport-front-0427.json", "sport-pages-d43.json"] {
            let url = try UIFixture.url(name)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: url)), name)
            XCTAssertFalse(url.path.contains("/PigTVTests/Fixtures/"), "\(name) is read from the bundle, not the source tree")
        }
    }
}
