import XCTest
@testable import PigTV

/// #278 (audit D4/S1): "Record every game" in Settings › Sport and the rules in Recordings › Scheduled have one owner,
/// `BrowseModel` and its `RecordingsStore`. Before, Settings kept its own list and sent its own requests: the two pages
/// disagreed until each read the server again, Scheduled's Undo did not cover Settings (which could switch a rule back
/// on, or DELETE it a second time), a stale read could undo a Settings change, and the two could change rules at once.
@MainActor
final class SportRuleOwnerTests: XCTestCase {
    /// A server's rules (C-M): POST adds a `team` rule, PUT switches one, DELETE removes one; requests are logged in
    /// the order they arrive, and a mutation that arrives while another's answer is still held is counted.
    private final class Rules: @unchecked Sendable {
        let rows = Locked<[(id: Int, kind: String, match: String, sport: String?, enabled: Bool)]>([])
        let nextID = Locked(3)
        let log = Locked<[String]>([])
        /// How long the next `GET recordings/rules` answers wait, one entry per request (then none).
        let getDelays = Locked<[TimeInterval]>([])
        /// How long a PUT's answer waits.
        let putDelay = Locked<TimeInterval>(0)
        let postStatus = Locked(200)
        /// Until when a mutation's answer is held; a mutation arriving before then overlaps it.
        let heldUntil = Locked(Date.distantPast)
        let overlaps = Locked(0)

        func json(_ row: (id: Int, kind: String, match: String, sport: String?, enabled: Bool)) -> String {
            #"{"id":\#(row.id),"kind":"\#(row.kind)","match":"\#(row.match)","sport":\#(row.sport.map { "\"\($0)\"" } ?? "null"),"enabled":\#(row.enabled)}"#
        }

        func requests(_ line: String) -> Int { log.value.filter { $0 == line }.count }
    }

    private func server(_ rules: Rules) throws -> LocalHTTPServer {
        try LocalHTTPServer { request in
            rules.log.value.append("\(request.method) \(request.path)")
            let mutation = request.method != "GET"
            if mutation, Date() < rules.heldUntil.value { rules.overlaps.value += 1 }
            let id = Int(request.path.split(separator: "/").last ?? "")
            switch (request.method, request.path) {
            case ("GET", "/api/recordings/rules"):
                var r = LocalHTTPServer.Response.json("[" + rules.rows.value.map(rules.json).joined(separator: ",") + "]")
                var delays = rules.getDelays.value
                if !delays.isEmpty { r.delay = delays.removeFirst(); rules.getDelays.value = delays }
                return r
            case ("GET", "/api/recordings"), ("GET", "/api/recordings/scheduled"):
                return .json("[]")
            case ("POST", "/api/recordings/rules"):
                guard rules.postStatus.value == 200 else { return .json(#"{"error":"x"}"#, status: rules.postStatus.value) }
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String] ?? [:]
                let row = (id: rules.nextID.value, kind: body["kind"] ?? "", match: body["match"] ?? "", sport: body["sport"], enabled: true)
                rules.nextID.value += 1
                rules.rows.value.append(row)
                return .json(rules.json(row))
            case ("PUT", _):
                guard let id, let i = rules.rows.value.firstIndex(where: { $0.id == id }) else { return .notFound }
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Bool] ?? [:]
                rules.rows.value[i].enabled = body["enabled"] ?? true
                var r = LocalHTTPServer.Response.json(rules.json(rules.rows.value[i]))
                r.delay = rules.putDelay.value
                rules.heldUntil.value = Date().addingTimeInterval(r.delay)
                return r
            case ("DELETE", _):
                guard let id, rules.rows.value.contains(where: { $0.id == id }) else { return .notFound }
                rules.rows.value.removeAll { $0.id == id }
                return .json(#"{"success":true,"cancelled":0}"#)
            default:
                return .notFound
            }
        }
    }

    private lazy var defaults = UserDefaults(suiteName: "pigtv.sportRuleOwner.\(UUID().uuidString)")!

    /// The rules' owner, and Settings › Sport's model wired to it as `BrowseModel.sportFollows` wires it.
    private func models(_ http: LocalHTTPServer) throws -> (BrowseModel, SportFollowSettingsModel) {
        let client = APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1)
        let browse = BrowseModel(client: client, accountID: 1)
        browse.removalLog = PendingRemovalLog(defaults: defaults)
        let settings = SportFollowSettingsModel(client: client, defaults: defaults)
        settings.ruleOwner = browse
        return (browse, settings)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func team(_ browse: BrowseModel) -> RecordingRule? {
        ScheduledRows.rules(browse.recordingStore.rules, hidden: browse.recordingStore.pendingRemovals)
            .first { $0.kind == "team" && $0.match == "Arsenal" && $0.sport == "Football" }
    }

    /// A presenter whose 10 s Undo never runs out by itself (the test commits it).
    private func presenter() -> AppPresenter {
        let presenter = AppPresenter()
        presenter.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        return presenter
    }

    func testARuleChangedInSettingsIsInScheduledsStoreWhenTheCallReturns() async throws {
        let rules = Rules()
        let http = try server(rules)
        defer { http.stop() }
        let client = APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1)
        let browse = BrowseModel(client: client, accountID: 1)
        let settings = browse.sportFollows
        XCTAssertTrue(settings.ruleOwner === browse, "BrowseModel hands Settings › Sport itself as the rules' owner")
        await browse.reloadRules()
        await settings.setRecording("Football", "Arsenal", on: true) { _ in XCTFail("on never asks"); return false }
        XCTAssertEqual(rules.requests("POST /api/recordings/rules"), 1)
        XCTAssertEqual(team(browse)?.isOn, true, "Scheduled lists the new rule at once")
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.isOn, true)
        await settings.setRecording("Football", "Arsenal", on: false) { _ in true }
        XCTAssertEqual(rules.requests("DELETE /api/recordings/rules/3"), 1)
        XCTAssertNil(team(browse), "and drops it at once when it is stopped")
        XCTAssertNil(settings.rule("Football", "Arsenal"))
        XCTAssertNil(browse.actions.actionMessage, "Settings › Sport shows no Recordings banner")
    }

    func testARuleChangedInScheduledShowsInSettingsWithoutItsOwnRead() async throws {
        let rules = Rules()
        rules.rows.value = [(id: 3, kind: "team", match: "Arsenal", sport: "Football", enabled: true)]
        let http = try server(rules)
        defer { http.stop() }
        let (browse, settings) = try models(http)
        await browse.reloadRules() // Scheduled has read the rules
        await settings.loadRules() // and so has Settings › Sport
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.isOn, true)
        let shown = try XCTUnwrap(team(browse))
        let ok = await browse.setRule(shown, enabled: false)
        XCTAssertTrue(ok)
        let sent = rules.log.value.count
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.isOn, false, "switched off in Scheduled: off in Settings")
        let off = try XCTUnwrap(team(browse))
        let deleted = await browse.deleteRule(off)
        XCTAssertTrue(deleted)
        XCTAssertNil(settings.rule("Football", "Arsenal"), "deleted in Scheduled: gone from Settings")
        XCTAssertEqual(rules.log.value.count, sent + 4, "only Scheduled's DELETE and its reloads were sent: \(rules.log.value)")
    }

    /// The safe answer to "Record every game" on a team whose rule's removal is pending: wait for the removal. A POST
    /// meanwhile would get the server's existing rule back (C-M: 200 with the same rule), which the pending DELETE then
    /// removes; a PUT would switch on a rule about to be deleted. So the row is busy until the removal is settled, and
    /// then "on" makes a new rule.
    func testARuleRemovedWithUndoIsGoneFromSettingsAndNeverDeletedTwice() async throws {
        let rules = Rules()
        rules.rows.value = [(id: 3, kind: "team", match: "Arsenal", sport: "Football", enabled: true)]
        rules.nextID.value = 4
        let http = try server(rules)
        defer { http.stop() }
        let (browse, settings) = try models(http)
        await browse.reloadRules() // Scheduled has read the rules
        await settings.loadRules() // and so has Settings › Sport
        let shown = try XCTUnwrap(team(browse))
        let presenter = presenter()
        browse.removeRuleWithUndo(shown, presenter: presenter)
        XCTAssertNil(settings.rule("Football", "Arsenal"), "removed in Scheduled (Undo open): absent in Settings")
        XCTAssertTrue(settings.ruleIsBusy("Football", "Arsenal"), "its switch waits for the removal")
        await settings.setRecording("Football", "Arsenal", on: true) { _ in false }
        await settings.setRecording("Football", "Arsenal", on: false) { _ in true }
        let left = await settings.forgetRules("Football", ["Arsenal"]) { _ in XCTFail("nothing to ask about"); return false }
        XCTAssertTrue(left.failed.isEmpty)
        XCTAssertEqual(rules.requests("POST /api/recordings/rules") + rules.requests("PUT /api/recordings/rules/3")
                       + rules.requests("DELETE /api/recordings/rules/3"), 0, "nothing brings it back or deletes it: \(rules.log.value)")
        presenter.commitPendingUndo()
        await waitUntil { browse.recordingStore.pendingRemovals.isEmpty && !browse.mutationBusy }
        XCTAssertEqual(rules.requests("DELETE /api/recordings/rules/3"), 1, "Undo's DELETE, once")
        XCTAssertFalse(settings.ruleIsBusy("Football", "Arsenal"))
        await settings.setRecording("Football", "Arsenal", on: true) { _ in false }
        XCTAssertEqual(rules.requests("POST /api/recordings/rules"), 1, "settled: a new rule")
        XCTAssertEqual(team(browse)?.id, 4)
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.id, 4)
        XCTAssertEqual(rules.requests("DELETE /api/recordings/rules/3"), 1, "never a second DELETE: \(rules.log.value)")
    }

    func testAStaleReadAnsweredAfterASettingsChangeDoesNotUndoIt() async throws {
        let rules = Rules()
        let http = try server(rules)
        defer { http.stop() }
        let (browse, settings) = try models(http)
        await browse.reloadRules() // Scheduled has read the rules
        await settings.loadRules() // and so has Settings › Sport
        rules.getDelays.value = [1.5]
        let reads = rules.requests("GET /api/recordings/rules")
        async let stale: Void = settings.loadRules() // read before the change, answered after it
        await waitUntil { rules.requests("GET /api/recordings/rules") > reads }
        await settings.setRecording("Football", "Arsenal", on: true) { _ in false }
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.isOn, true)
        await stale
        XCTAssertEqual(settings.rule("Football", "Arsenal")?.isOn, true, "the older answer, without the rule, is dropped")
        XCTAssertEqual(team(browse)?.isOn, true)
    }

    /// Decision: a Settings change made while another recordings change is on its way waits for it (as a committed
    /// Undo does) rather than being dropped, its row busy meanwhile, and is decided from the rules as they are then.
    func testASettingsChangeWaitsForARecordingsChangeInFlight() async throws {
        let rules = Rules()
        rules.rows.value = [(id: 5, kind: "series", match: "Gruen", sport: nil, enabled: true)]
        rules.putDelay.value = 1.2
        let http = try server(rules)
        defer { http.stop() }
        let (browse, settings) = try models(http)
        await browse.reloadRules() // Scheduled has read the rules
        await settings.loadRules() // and so has Settings › Sport
        let series = try XCTUnwrap(browse.recordingStore.rules.first)
        async let first = browse.setRule(series, enabled: false)
        await waitUntil { browse.mutationBusy }
        async let second: Void = settings.setRecording("Football", "Arsenal", on: true) { _ in false }
        await waitUntil { settings.ruleIsBusy("Football", "Arsenal") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rules.requests("POST /api/recordings/rules"), 0, "nothing is sent while the other change runs")
        XCTAssertTrue(settings.ruleIsBusy("Football", "Arsenal"), "the row shows it is waiting")
        let firstResult = await first
        await second
        XCTAssertTrue(firstResult)
        XCTAssertEqual(rules.requests("POST /api/recordings/rules"), 1, "sent once it is free: \(rules.log.value)")
        XCTAssertEqual(rules.overlaps.value, 0, "never two rule changes on the wire at once")
        let order = rules.log.value.filter { !$0.hasPrefix("GET") }
        XCTAssertEqual(order, ["PUT /api/recordings/rules/5", "POST /api/recordings/rules"])
        XCTAssertEqual(team(browse)?.isOn, true)
        XCTAssertEqual(browse.actions.actionMessage, "Rule turned off.", "Scheduled's own line is left as it was")
    }

    /// Guard (decision 3): a refused change is said on the Settings page, as before, and nowhere in Recordings.
    func testARefusedSettingsChangeIsSaidOnItsPageOnly() async throws {
        let rules = Rules()
        rules.postStatus.value = 500
        let http = try server(rules)
        defer { http.stop() }
        let (browse, settings) = try models(http)
        await browse.reloadRules() // Scheduled has read the rules
        await settings.loadRules() // and so has Settings › Sport
        await settings.setRecording("Football", "Arsenal", on: true) { _ in false }
        XCTAssertTrue(settings.message.hasPrefix("Not saved: "), settings.message)
        XCTAssertNil(browse.actions.actionError)
        XCTAssertNil(browse.actions.actionMessage)
        XCTAssertFalse(browse.mutationBusy)
        XCTAssertFalse(settings.ruleIsBusy("Football", "Arsenal"))
    }
}
