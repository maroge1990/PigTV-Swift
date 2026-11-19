import Foundation

/// The JSON fixtures in PigTVTests/Fixtures, copied into this UI test bundle as resources (the PigTVTests folder's
/// membership exception for PigTVUITests, #351). Read from the bundle, so a test runner without the source tree (Xcode
/// Cloud runs `test-without-building` on a machine that has only the build products) has them too. Before, the UI tests
/// read them through `#filePath`, which only the Mac that built them could.
enum UIFixture {
    private final class Marker {}

    /// The fixture's URL in the bundle; a missing one throws (the test fails naming it, never reads nothing).
    static func url(_ name: String) throws -> URL {
        let bundle = Bundle(for: Marker.self)
        for subdirectory in [nil, "Fixtures"] {
            if let found = bundle.url(forResource: name, withExtension: nil, subdirectory: subdirectory) { return found }
        }
        throw NSError(domain: "UIFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) is not in the UI test bundle"])
    }

    /// The folder that holds the fixtures (they are copied side by side).
    static func folder() throws -> URL { try url("sport-pages-d43.json").deletingLastPathComponent() }
}
