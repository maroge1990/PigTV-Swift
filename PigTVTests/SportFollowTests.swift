import XCTest
@testable import PigTV

/// #200 (C-U, D-41): Settings › Sport's rules, ported from the web's SportFollowModel.
final class SportFollowLogicTests: XCTestCase {
    private typealias L = SportFollowLogic

    private let catalog = SportCatalog(sports: [
        .init(sport: "Football", leagues: [.init(league: "Premier League", heading: "Domestic leagues"),
                                           .init(league: "League Cup", heading: "Cups")]),
        .init(sport: "Rugby league", leagues: [.init(league: "NRL")])
    ])
    private let state = SportFollows(spoilerFree: false, sports: [
        .init(sport: "Football", leagues: ["Premier League", "Champions League"], teams: ["Arsenal", "Real Madrid"]),
        .init(sport: "Cricket", leagues: ["Cricket"], teams: [])
    ])

    func testAddingASportTakesItsFirstLeague() {
        let one = L.addSport(state, "Rugby league", catalog: catalog)
        XCTAssertEqual(one.sports.last, .init(sport: "Rugby league", leagues: ["NRL"]), "a one-league sport is added with that league")
        let many = L.addSport(SportFollows(), "Football", catalog: catalog)
        XCTAssertEqual(many.sports, [.init(sport: "Football", leagues: ["Premier League"])], "a sport needs one league: its first")
        XCTAssertEqual(L.addSport(state, "Football", catalog: catalog), state, "a sport followed already is not added twice")
        XCTAssertEqual(L.addSport(state, "Curling", catalog: catalog), state, "nor one outside the catalogue")
    }

    func testAddingALeagueOnce() {
        let next = L.addLeague(state, "Football", "League Cup")
        XCTAssertEqual(next.entry("Football")?.leagues, ["Premier League", "Champions League", "League Cup"])
        XCTAssertEqual(L.addLeague(next, "Football", "League Cup"), next)
    }

    func testRemovingALeague() {
        let last = L.removeLeague(state, "Cricket", "Cricket")
        XCTAssertEqual(last.error, "A sport needs at least one league: remove the sport instead.")
        XCTAssertEqual(last.state, state, "the last league is refused")
        let names: [String: [String]] = ["Premier League": ["Arsenal", "Chelsea"], "Champions League": ["arsenal", "Real Madrid"]]
        let removed = L.removeLeague(state, "Football", "Champions League") { names[$0] }
        XCTAssertEqual(removed.state.entry("Football")?.leagues, ["Premier League"])
        XCTAssertEqual(removed.orphans, ["Real Madrid"], "a name only that league offers goes with it; Arsenal plays on (any case)")
        let unknown = L.removeLeague(state, "Football", "Champions League") { $0 == "Champions League" ? ["Real Madrid"] : nil }
        XCTAssertEqual(unknown.orphans, [], "a league whose names are not known yet is never taken to lack a team")
        XCTAssertNil(unknown.error)
    }

    func testRemovingNamesAndMoving() {
        XCTAssertEqual(L.removeNames(state, "Football", ["ARSENAL"]).entry("Football")?.teams, ["Real Madrid"])
        XCTAssertEqual(L.move([1, 2, 3], 0, -1), [1, 2, 3], "unchanged at the top")
        XCTAssertEqual(L.move([1, 2, 3], 2, 1), [1, 2, 3], "and at the bottom")
        XCTAssertEqual(L.move([1, 2, 3], 1, -1), [2, 1, 3])
        XCTAssertEqual(L.moveSport(state, "Cricket", -1).sports.map(\.sport), ["Cricket", "Football"])
        XCTAssertEqual(L.moveLeague(state, "Football", "Champions League", -1).entry("Football")?.leagues, ["Champions League", "Premier League"])
        XCTAssertEqual(L.removeSport(state, "Football").sports.map(\.sport), ["Cricket"])
    }

    func testAddingANameKeepsTheLimits() {
        XCTAssertEqual(L.addName(state, "Football", "  Chelsea   FC ").state.entry("Football")?.teams, ["Arsenal", "Real Madrid", "Chelsea FC"])
        XCTAssertEqual(L.addName(state, "Football", "arsenal").error, "arsenal is followed already.")
        var full = state
        full.sports[0].teams = (1...20).map { "Team \($0)" }
        XCTAssertEqual(L.addName(full, "Football", "Chelsea").error, "At most 20 in one sport.")
        XCTAssertEqual(L.addName(state, "Football", String(repeating: "x", count: 81)).error, "A followed name is too long")
        XCTAssertNil(L.addName(state, "Football", String(repeating: "x", count: 80)).error)
    }

    func testANameMustBeOfferedOnceTheLeaguesNamesAreKnown() {
        XCTAssertEqual(L.choose("chelsea", sport: "Football", offered: ["Arsenal", "Chelsea"]).name, "Chelsea", "the list's own spelling")
        XCTAssertEqual(L.choose("Leeds", sport: "Football", offered: ["Arsenal"]).error, "Leeds is not in the leagues you follow in Football.")
        XCTAssertEqual(L.choose(" ", sport: "Football", offered: ["Arsenal"]).error, "That is not in the leagues you follow in Football.")
        XCTAssertEqual(L.choose("Leeds  United", sport: "Football", offered: []).name, "Leeds United", "before any names are known, as typed")
    }

    func testOfferedNamesAndTheSearch() {
        let names: [String: [String]] = ["Premier League": ["Chelsea", "Arsenal"], "Champions League": ["arsenal", "Barcelona"]]
        let offered = L.offered(state.sports[0]) { names[$0] }
        XCTAssertEqual(offered, ["Arsenal", "Barcelona", "Chelsea"], "each once (any case), in name order")
        XCTAssertEqual(L.matches("", offered: offered, following: ["ARSENAL"]), ["Barcelona", "Chelsea"], "followed names are not offered")
        XCTAssertEqual(L.matches("bar", offered: offered, following: []), ["Barcelona"])
        XCTAssertEqual(L.matches("", offered: (1...50).map { "Team \($0)" }, following: []).count, 30)
    }

    func testTheRuleOnAName() {
        let rules = [SportTeamRule(id: 1, kind: "sport", match: "Arsenal", sport: nil),
                     SportTeamRule(id: 2, match: "Arsenal", sport: "Cricket"),
                     SportTeamRule(id: 3, match: "arsenal", sport: "Football", enabled: false)]
        XCTAssertEqual(L.ruleFor(rules, sport: "Football", name: "Arsenal")?.id, 3, "kind team, the sport, the name in any case")
        XCTAssertNil(L.ruleFor(rules, sport: "Football", name: "Chelsea"))
    }

    func testTheMessagesAndQuestions() {
        XCTAssertEqual(L.after("Unfollowed Arsenal.", .init()), "Unfollowed Arsenal.")
        XCTAssertEqual(L.after("Unfollowed Arsenal.", .init(failed: ["Arsenal"])),
                       "Unfollowed Arsenal. But every Arsenal game is still being recorded: stop it in Recordings › Recording rules.")
        XCTAssertEqual(L.after("Stopped following Football.", .init(unknown: true)),
                       "Stopped following Football. The recording rules could not be read, so any \"Record every game\" on it is still on: check Recordings › Recording rules.")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let s = SportSuggestions.Suggestion(sport: "Football", team: "Arsenal", league: "League Cup", label: "League Cup", start: 1_793_750_400_000)
        XCTAssertEqual(L.suggestionText(s, calendar: utc), "League Cup has Arsenal games too (the first Wed 4 Nov).")
        XCTAssertEqual(L.stopFollowingQuestion(state.sports[0]).title, "Stop following Football and Arsenal, Real Madrid?")
        XCTAssertEqual(L.stopFollowingQuestion(state.sports[1]).title, "Stop following Cricket?")
        XCTAssertEqual(L.removeLeagueQuestion(orphans: ["Real Madrid"], sport: "Football", label: "Champions League").message,
                       "Real Madrid plays in no other league you follow in Football, so it will be unfollowed too.")
        XCTAssertEqual(L.removeLeagueQuestion(orphans: ["A", "B"], sport: "Football", label: "X").message,
                       "A, B play in no other league you follow in Football, so they will be unfollowed too.")
        let keep = L.keepRecordingQuestion("Arsenal")
        XCTAssertEqual(keep.title, "Keep recording every Arsenal game?")
        XCTAssertTrue(keep.dismissAnswer, "Menu keeps the rule")
        XCTAssertEqual(L.stopRecordingQuestion("Arsenal").title, "Stop recording every Arsenal game?")
        XCTAssertFalse(L.stopRecordingQuestion("Arsenal").dismissAnswer)
    }

    func testHeadingsAndPeople() {
        XCTAssertEqual(L.namesHeading("Football", people: false), "Teams")
        XCTAssertEqual(L.namesHeading("Tennis", people: true), "Players")
        XCTAssertEqual(L.namesHeading("Golf", people: true), "Players")
        XCTAssertEqual(L.namesHeading("Combat", people: true), "Fighters")
        XCTAssertEqual(L.namesHeading("Motorsport", people: true), "Drivers")
        XCTAssertEqual(L.followTitle("Motorsport", people: true), "Follow a driver…")
        XCTAssertEqual(L.followTitle("Football", people: false), "Follow a team…")
        let tennis = SportFollows.Entry(sport: "Tennis", leagues: ["ATP Tour"])
        XCTAssertTrue(L.followsPeople(tennis, kinds: [:]), "before the names answer, the server's fixed list")
        XCTAssertFalse(L.followsPeople(tennis, kinds: ["ATP Tour": "team"]), "the names answer says")
        XCTAssertEqual(L.summary(state.sports[0], catalog: SportCatalog(sports: [.init(sport: "Football", leagues: [.init(league: "Premier League", label: "EPL")])])),
                       "EPL, Champions League · Arsenal, Real Madrid")
    }
}

/// #200: the settings model against a fake account on a local server.
@MainActor
final class SportFollowSettingsModelTests: XCTestCase {
    /// One account's follows: PUT replaces them (or is refused), GET answers them; rules as C-M.
    private final class Account: @unchecked Sendable {
        let follows = Locked(#"{"spoilerFree":false,"sports":[{"sport":"Football","leagues":["Premier League"],"teams":["Arsenal"]}]}"#)
        let followsStatus = Locked(200)
        let putStatus = Locked(200)
        /// The answer to the first PUT waits this long.
        let firstPutDelay = Locked<TimeInterval>(0)
        let puts = Locked<[Data]>([])
        let rules = Locked(#"[{"id":3,"kind":"team","match":"Arsenal","sport":"Football","enabled":true,"createdByName":"tester"}]"#)
        let rulesStatus = Locked(200)
        /// A PUT is kept but answers 500, and the follows can no longer be read (its answer was lost).
        let commitThenFail = Locked(false)
        /// The catalogue's answer waits this long.
        let catalogDelay = Locked<TimeInterval>(0)
    }

    private static let catalogJSON = #"{"sports":[{"sport":"Football","leagues":[{"league":"Premier League","label":"Premier League","heading":null},{"league":"League Cup","label":"League Cup","heading":"Cups"},{"league":"Europa League","label":"Europa League","heading":"Europe"}]}]}"#

    private func server(_ account: Account) throws -> LocalHTTPServer {
        let catalog = Self.catalogJSON
        return try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/sports/catalog"):
                var r = LocalHTTPServer.Response.json(catalog)
                r.delay = account.catalogDelay.value
                return r
            case ("GET", "/api/sports/follows"):
                return account.followsStatus.value == 200 ? .json(account.follows.value) : .json(#"{"error":"x"}"#, status: account.followsStatus.value)
            case ("PUT", "/api/sports/follows"):
                account.puts.value.append(request.body)
                if account.commitThenFail.value {
                    account.follows.value = String(decoding: request.body, as: UTF8.self)
                    account.followsStatus.value = 500
                    var r = LocalHTTPServer.Response.json(#"{"error":"lost"}"#, status: 500)
                    r.delay = account.firstPutDelay.value
                    return r
                }
                guard account.putStatus.value == 200 else { return .json(#"{"error":"bad"}"#, status: account.putStatus.value) }
                account.follows.value = String(decoding: request.body, as: UTF8.self)
                var r = LocalHTTPServer.Response.json(account.follows.value)
                if account.puts.value.count == 1 { r.delay = account.firstPutDelay.value }
                return r
            case ("GET", "/api/sports/names"):
                return .json(#"{"league":"Premier League","kind":"team","names":["Arsenal","Chelsea"]}"#)
            case ("GET", "/api/sports/suggestions"):
                return .json(#"{"suggestions":[]}"#)
            case ("GET", "/api/recordings/rules"):
                return account.rulesStatus.value == 200 ? .json(account.rules.value) : .json(#"{"error":"x"}"#, status: 500)
            case ("DELETE", "/api/recordings/rules/3"):
                return .json(#"{"success":true,"cancelled":0}"#)
            case ("POST", "/api/recordings/rules"), ("PUT", "/api/recordings/rules/3"):
                return .json(#"{"id":3,"kind":"team","match":"Arsenal","sport":"Football","enabled":true}"#)
            default:
                return .notFound
            }
        }
    }

    private func model(_ http: LocalHTTPServer, defaults: UserDefaults? = nil) throws -> SportFollowSettingsModel {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9","apiVersion":1,"features":{"library":true,"playbackResolve":true,"sportFollows":true,"recordingRules":true}}"#.utf8))
        return SportFollowSettingsModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", info: info, accountID: 1),
                                        defaults: defaults ?? UserDefaults(suiteName: "SportFollowSettingsModelTests.\(UUID().uuidString)")!)
    }

    private func leagues(_ body: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return ((json?["sports"] as? [[String: Any]])?.first?["leagues"] as? [String]) ?? []
    }

    func testTwoQuickChangesAreSentInOrderAndTheSecondBuildsOnTheFirst() async throws {
        let account = Account()
        account.firstPutDelay.value = 0.6
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        XCTAssertEqual(model.follows?.entry("Football")?.leagues, ["Premier League"])
        async let first: Void = model.addLeague("Football", "League Cup")
        try await Task.sleep(for: .milliseconds(150))
        await model.addLeague("Football", "Europa League")
        await first
        XCTAssertEqual(account.puts.value.count, 2)
        XCTAssertEqual(leagues(account.puts.value[1]), ["Premier League", "League Cup", "Europa League"],
                       "the second change was built from the first one's answer, not the list both started from")
        XCTAssertEqual(model.follows?.entry("Football")?.leagues, ["Premier League", "League Cup", "Europa League"])
        XCTAssertEqual(model.message, "Added Europa League.")
    }

    /// #250: "Removed <league>." stayed until the next save or a relaunch (the model lives as long as the app).
    func testWhatAChangeDidClearsAfterAWhileButNotSavedStays() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        model.doneLingers = .milliseconds(200)
        await model.load()
        await model.addLeague("Football", "League Cup")
        XCTAssertEqual(model.message, "Added League Cup.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.message, "", "the line goes on its own")
        account.putStatus.value = 400
        await model.addLeague("Football", "Europa League")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(model.message.hasPrefix("Not saved: "), "a refusal stays until the next change: \(model.message)")
    }

    func testARefusedSaveSaysSoAndReadsTheFollowsAgain() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        account.putStatus.value = 400
        let reads = http.requests(path: "/api/sports/follows", method: "GET").count
        await model.addLeague("Football", "League Cup")
        XCTAssertTrue(model.message.hasPrefix("Not saved: "), model.message)
        XCTAssertEqual(http.requests(path: "/api/sports/follows", method: "GET").count, reads + 1, "what the server has is read again")
        XCTAssertEqual(model.follows?.entry("Football")?.leagues, ["Premier League"])
    }

    /// Apple 92 Codex round 1 (high): a change the server kept but whose answer was lost, with the re-read failing too,
    /// never lets a queued change replace the list from the old copy.
    func testALostAnswerThatCannotBeReadAgainStopsQueuedChanges() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        var asked = 0
        model.onSpoilerFreeChange = { asked += 1 }
        await model.load()
        account.commitThenFail.value = true
        account.firstPutDelay.value = 0.6
        async let first: Void = model.addLeague("Football", "League Cup")
        try await Task.sleep(for: .milliseconds(150))
        await model.addLeague("Football", "Europa League")
        await first
        XCTAssertEqual(account.puts.value.count, 1, "the queued change was not sent from the old list")
        XCTAssertEqual(leagues(Data(account.follows.value.utf8)), ["Premier League", "League Cup"], "the kept change stands")
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(asked, 1, "the sport pages ask for Hide scores again")
        account.commitThenFail.value = false
        account.followsStatus.value = 200
        await model.load()
        XCTAssertTrue(model.canEdit, "a load that reads the server again allows changes")
        XCTAssertEqual(model.follows?.entry("Football")?.leagues, ["Premier League", "League Cup"])
    }

    /// Apple 93 Codex round 2 (high): a load that overlapped such a save (its catalogue still on the way) does not reopen
    /// changes with the follows it read before the save.
    func testALoadOverlappingALostAnswerDoesNotReopenChanges() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        account.catalogDelay.value = 1.0
        async let reopened: Void = model.load()
        try await Task.sleep(for: .milliseconds(300)) // its follows are read; its catalogue is not
        account.commitThenFail.value = true
        await model.addLeague("Football", "League Cup")
        await reopened
        XCTAssertFalse(model.canEdit, "the overlapping load kept the save's read-only state")
        await model.addLeague("Football", "Europa League")
        XCTAssertEqual(account.puts.value.count, 1, "no change was sent from the old list")
        XCTAssertEqual(leagues(Data(account.follows.value.utf8)), ["Premier League", "League Cup"])
    }

    func testOfflineShowsTheLastCopyAndCannotBeChanged() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let store = UserDefaults(suiteName: "SportFollowSettingsModelTests.\(UUID().uuidString)")!
        let online = try model(http, defaults: store)
        await online.load()
        XCTAssertFalse(online.offline)
        account.followsStatus.value = 503
        let later = try model(http, defaults: store)
        await later.load()
        XCTAssertTrue(later.offline, "the follows could not be read")
        XCTAssertEqual(later.follows?.entry("Football")?.teams, ["Arsenal"], "this account's last copy is shown")
        XCTAssertFalse(later.canEdit)
        await later.addLeague("Football", "League Cup")
        XCTAssertTrue(account.puts.value.isEmpty, "nothing is sent from the copy")
        let fresh = try model(http)
        await fresh.load()
        XCTAssertTrue(fresh.loadFailed, "no copy on this device: the failure is said")
        XCTAssertNil(fresh.follows)
        XCTAssertNotEqual(later.cacheKey, try model(try LocalHTTPServer { _ in .notFound }).cacheKey, "the copy is per server")
    }

    func testUnfollowingKeepsTheRuleUnlessStopIsChosen() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        XCTAssertTrue(model.rulesKnown)
        var asked: [String] = []
        await model.unfollow("Football", "Arsenal") { asked.append($0.title); return true }
        XCTAssertEqual(asked, ["Keep recording every Arsenal game?"])
        XCTAssertTrue(http.requests(path: "/api/recordings/rules/3", method: "DELETE").isEmpty, "kept: not deleted")
        XCTAssertEqual(model.follows?.entry("Football")?.teams, [])
        XCTAssertEqual(model.message, "Unfollowed Arsenal.")

        account.follows.value = #"{"spoilerFree":false,"sports":[{"sport":"Football","leagues":["Premier League"],"teams":["Arsenal"]}]}"#
        await model.load()
        await model.unfollow("Football", "Arsenal") { _ in false }
        XCTAssertEqual(http.requests(path: "/api/recordings/rules/3", method: "DELETE").count, 1, "Stop recording deletes it")

        account.follows.value = #"{"spoilerFree":false,"sports":[{"sport":"Football","leagues":["Premier League"],"teams":["Arsenal"]}]}"#
        await model.load()
        account.rulesStatus.value = 500
        await model.unfollow("Football", "Arsenal") { _ in XCTFail("nothing to ask about"); return false }
        XCTAssertTrue(model.message.contains("The recording rules could not be read"), model.message)
    }

    func testRecordEveryGame() async throws {
        let account = Account()
        account.rules.value = #"[{"id":3,"kind":"team","match":"Arsenal","sport":"Football","enabled":false}]"#
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        await model.setRecording("Football", "Arsenal", on: true) { _ in XCTFail("on never asks"); return false }
        XCTAssertEqual(http.requests(path: "/api/recordings/rules/3", method: "PUT").count, 1, "a switched-off rule is switched back on")
        XCTAssertTrue(http.requests(path: "/api/recordings/rules", method: "POST").isEmpty)
        account.rules.value = "[]"
        await model.loadRules()
        await model.setRecording("Football", "Arsenal", on: true) { _ in false }
        let post = try XCTUnwrap(http.requests(path: "/api/recordings/rules", method: "POST").first)
        let body = try JSONSerialization.jsonObject(with: post.body) as? [String: String]
        XCTAssertEqual(body, ["kind": "team", "match": "Arsenal", "sport": "Football"])
        XCTAssertEqual(model.message, "Recording every Arsenal game.")
        account.rules.value = #"[{"id":3,"kind":"team","match":"Arsenal","sport":"Football","enabled":true}]"#
        await model.loadRules()
        await model.setRecording("Football", "Arsenal", on: false) { _ in false }
        XCTAssertTrue(http.requests(path: "/api/recordings/rules/3", method: "DELETE").isEmpty, "Cancel keeps it")
        await model.setRecording("Football", "Arsenal", on: false) { $0.title == "Stop recording every Arsenal game?" }
        XCTAssertEqual(http.requests(path: "/api/recordings/rules/3", method: "DELETE").count, 1)
    }

    func testASpoilerFreeChangeMakesTheSportPagesAskAgain() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        var told = 0
        model.onSpoilerFreeChange = { told += 1 }
        await model.load()
        await model.moveSport("Football", by: 1)
        XCTAssertEqual(told, 0)
        await model.setSpoilerFree(true)
        XCTAssertEqual(told, 1)
        XCTAssertEqual(model.follows?.spoilerFree, true)
        XCTAssertEqual(model.message, "Scores are hidden.")
    }

    func testRemovingTheLastLeagueIsRefusedWithoutAsking() async throws {
        let account = Account()
        let http = try server(account)
        defer { http.stop() }
        let model = try model(http)
        await model.load()
        await model.removeLeague("Football", "Premier League") { _ in XCTFail("no question"); return true }
        XCTAssertEqual(model.message, "A sport needs at least one league: remove the sport instead.")
        XCTAssertTrue(account.puts.value.isEmpty)
    }
}
