import XCTest

/// Finds a JSON fixture in the test bundle. A missing fixture is a failure, never a skip and never an empty body: a suite
/// that cannot read its fixture would otherwise pass (or skip) having checked nothing.
enum Fixture {
    nonisolated static func url(_ name: String) -> URL? {
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let found = bundle.urls(forResourcesWithExtension: nil, subdirectory: nil)?.first(where: { $0.lastPathComponent == name }) { return found }
        }
        for bundle in Bundle.allBundles {
            let enumerator = FileManager.default.enumerator(at: bundle.bundleURL, includingPropertiesForKeys: nil)
            while let found = enumerator?.nextObject() as? URL { if found.lastPathComponent == name { return found } }
        }
        return nil
    }

    /// The fixture's bytes. When it is missing or unreadable this records an `XCTFail` naming the file and throws.
    /// `try?` at a call site that cannot throw (a `URLProtocol` stub) still leaves the failure recorded.
    nonisolated static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard let url = url(name) else {
            XCTFail("\(name) is not in the test bundle", file: file, line: line)
            throw FixtureError.missing(name)
        }
        do { return try Data(contentsOf: url) } catch {
            XCTFail("\(name) cannot be read: \(error)", file: file, line: line)
            throw error
        }
    }
}

enum FixtureError: Error { case missing(String) }
