import XCTest
@testable import PigTV

/// A3 (build 48): a recording-rule change that fails is shown, not hidden behind the successful
/// reload that follows it, and only one change runs at a time. A local server answers the rule's
/// PUT or DELETE with an error while its GET (the sheet's reload) works. On build 47 the failure
/// went to actionError, which the rules sheet never showed, and changes could overlap.
@MainActor
final class RecordingRuleActionTests: XCTestCase {
    private static let rule = #"{"id":7,"kind":"sport","match":"Collingwood","enabled":true,"upcoming":1}"#

    private func server(put: Int = 200, delete: Int = 200, slowPut: TimeInterval = 0) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("PUT", "/api/recordings/rules/7"):
                var r = put == 200 ? LocalHTTPServer.Response.json(Self.rule) : .json(#"{"error":"Rules are read-only right now"}"#, status: put)
                r.delay = slowPut
                return r
            case ("DELETE", "/api/recordings/rules/7"):
                return delete == 200 ? .json(#"{"success":true,"cancelled":1}"#) : .json(#"{"error":"No such rule"}"#, status: delete)
            case ("GET", "/api/recordings/rules"):
                return .json("[\(Self.rule)]")
            case ("GET", "/api/recordings"), ("GET", "/api/recordings/scheduled"):
                return .json("[]")
            default:
                return .notFound
            }
        }
    }

    private func model(_ server: LocalHTTPServer) throws -> (BrowseModel, RecordingRule) {
        let client = APIClient(address: try ServerAddress(server.baseURL), token: "fixture", accountID: 1)
        let rule = try JSONDecoder().decode(RecordingRule.self, from: Data(Self.rule.utf8))
        return (BrowseModel(client: client, accountID: 1), rule)
    }

    func testAFailedTurnOffIsShownEvenThoughTheReloadWorks() async throws {
        let http = try server(put: 500)
        defer { http.stop() }
        let (model, rule) = try model(http)
        model.actionMessage = "Rule deleted." // a stale success from before
        let ok = await model.setRule(rule, enabled: false)
        let rules = try await model.loadRules() // the sheet's reload succeeds and shows it unchanged
        XCTAssertFalse(ok)
        XCTAssertEqual(rules.first?.isOn, true)
        XCTAssertNotNil(model.actions.actionError, "the failure is kept for the sheet")
        XCTAssertTrue(model.actions.actionError?.hasPrefix("Could not change the rule.") ?? false)
        XCTAssertNil(model.actions.actionMessage, "no stale success beside it")
        XCTAssertFalse(model.actions.mutationBusy)
    }

    func testAFailedDeleteIsShown() async throws {
        let http = try server(delete: 404)
        defer { http.stop() }
        let (model, rule) = try model(http)
        let ok = await model.deleteRule(rule)
        XCTAssertFalse(ok)
        XCTAssertTrue(model.actions.actionError?.hasPrefix("Could not delete the rule.") ?? false)
        XCTAssertNil(model.actions.actionMessage)
    }

    func testOneChangeAtATime() async throws {
        let http = try server(slowPut: 0.5)
        defer { http.stop() }
        let (model, rule) = try model(http)
        async let first = model.setRule(rule, enabled: false)
        for _ in 0..<100 where !model.actions.mutationBusy { await Task.yield() }
        XCTAssertTrue(model.actions.mutationBusy, "the sheet's buttons are off while it runs")
        let second = await model.deleteRule(rule)
        XCTAssertFalse(second, "a second change while one runs is refused")
        let firstResult = await first
        XCTAssertTrue(firstResult)
        XCTAssertEqual(model.actions.actionMessage, "Rule turned off.")
        XCTAssertTrue(http.requests(path: "/api/recordings/rules/7", method: "DELETE").isEmpty)
    }
}
