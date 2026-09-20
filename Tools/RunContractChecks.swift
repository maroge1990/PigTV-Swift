import Foundation

@main
struct RunContractChecks {
    static func main() async throws {
        let count = try await ContractChecks.run()
        print("Passed \(count) API/model contract checks using synthetic data; no server or provider contacted.")
    }
}
