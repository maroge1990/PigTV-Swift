import XCTest
@testable import PigTV

@MainActor
final class PigTVTests: XCTestCase {
    func testServerContracts() async throws {
        let checks = try await ContractChecks.run()
        XCTAssertGreaterThanOrEqual(checks, 30)
    }
}
