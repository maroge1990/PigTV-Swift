import XCTest
@testable import PigTV

// #351: Xcode Cloud builds on one machine and runs `test-without-building` on another that has only the build products,
// no source tree. What the tests read must be in their bundles: the server's golden answers (the PigTVTests "Golden
// answers" build phase) and the Sport fixture the Debug app's offline Home reads (a membership exception of
// PigTVTests/Fixtures). Before, both were read from the source tree through #filePath. Fails on Apple 335.
@MainActor
final class TestResourcesTests: XCTestCase {
    private static let besideSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("PigTV/test/golden")

    func testTheGoldenAnswersAreInTheTestBundleWhenTheBuildHadThem() throws {
        let bundled = Bundle(for: Self.self).url(forResource: "golden", withExtension: nil)
        let built = ProcessInfo.processInfo.environment["PIGTV_GOLDEN_DIR"].map { URL(fileURLWithPath: $0) } ?? Self.besideSource
        guard let bundled else {
            if FileManager.default.fileExists(atPath: built.appendingPathComponent("routes.json").path) {
                XCTFail("the golden answers at \(built.path) were not copied into the test bundle")
            }
            throw XCTSkip("no golden answers where this was built (no ../PigTV checkout)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.appendingPathComponent("routes.json").path))
        XCTAssertEqual(GoldenChecks.folder()?.standardizedFileURL.path.hasSuffix("golden"), true, "GoldenChecks finds a golden folder")
    }

    func testTheDebugAppCarriesTheOfflineSportFixture() throws {
        // The unit tests run inside the app (TEST_HOST): Bundle.main is the Debug app.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sport-front-0381", withExtension: "json"),
                                "the offline Home's Sport answer is not in the Debug app")
        XCTAssertNoThrow(try JSONDecoder().decode(SportFront.self, from: Data(contentsOf: url)))
    }
}
