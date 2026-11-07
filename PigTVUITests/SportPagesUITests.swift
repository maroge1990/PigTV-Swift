import XCTest

#if os(tvOS)
// D-43 (Apple 99): every sport page's content under the banner, on PigTVTests/Fixtures/sport-pages-d43.json (the server's
// golden answers trimmed and extended; read from the source tree, its times moved to the real clock): Motorsport (F1,
// NASCAR), Australian football (AFL, a C-T league), Cricket (two leagues), Combat (UFC), Tennis (WTA Tour) and Golf (PGA
// Tour), with followed names in each. No server. Screenshots go to the attachments and, with
// TEST_RUNNER_PIGTV_SCREENSHOT_DIR, to that folder (T3).
final class SportPagesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let dir = ProcessInfo.processInfo.environment["PIGTV_SCREENSHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Every time in the fixture moved by the same amount, so its "now" is the real clock.
    private static func shifted(_ value: Any, by delta: Double) -> Any {
        if var dict = value as? [String: Any] {
            for (key, inner) in dict {
                if let number = inner as? Double, number > 1e12, !(inner is Bool) {
                    dict[key] = number + delta
                } else {
                    dict[key] = shifted(inner, by: delta)
                }
            }
            return dict
        }
        if let list = value as? [Any] { return list.map { shifted($0, by: delta) } }
        return value
    }

    /// Nobody followed in the C-V events (the "none" mock-ups).
    private static func unfollowed(_ json: inout [String: Any]) {
        guard var events = json["events"] as? [String: Any] else { return }
        for (league, value) in events {
            guard var page = value as? [String: Any] else { continue }
            page["events"] = (page["events"] as? [[String: Any]] ?? []).map { var e = $0; e["followed"] = [String](); return e }
            events[league] = page
        }
        json["events"] = events
    }

    private func launch(sport: String, spoilers: Bool = false, f1: Bool = false, nobodyFollowed: Bool = false,
                        f1Live: Bool = false, nfl: Bool = false, nflFollow: String? = nil) throws -> XCUIApplication {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("sport-pages-d43.json")))
            as? [String: Any])
        if nobodyFollowed { Self.unfollowed(&json) }
        if nfl, var front = json["front"] as? [String: Any], var sports = front["sports"] as? [[String: Any]] {
            // The NFL as the server lists it (sportCatalog: American football › NFL), with nothing in the next 72 hours.
            sports.append(["league": "NFL", "sport": "American football", "live": 0, "line": "next"])
            front["sports"] = sports
            json["front"] = front
        }
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_OPEN_SPORT"] = sport
        if spoilers { app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "1" }
        if f1 || f1Live { app.launchEnvironment["PIGTV_UI_TEST_FRONT_F1"] = f1Live ? "live" : "1" }
        if nfl {
            app.launchEnvironment["PIGTV_UI_TEST_NFL_JSON"] = try Data(contentsOf: fixtures.appendingPathComponent("nfl-page-0379.json"))
                .base64EncodedString()
        }
        if let nflFollow { app.launchEnvironment["PIGTV_UI_TEST_NFL_FOLLOW"] = nflFollow }
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["sport.page.\(sport)"].waitForExistence(timeout: 15), "\(sport)'s page")
        return app
    }

    /// Focus onto banner item `index`, then select it.
    private func selectLeague(_ app: XCUIApplication, _ index: Int) {
        let target = "sport.banner.item.\(index)"
        let banner = app.descendants(matching: .any)["sport.banner"]
        for _ in 0..<14 where focused(app).identifier != target {
            let id = focused(app).identifier
            if id.hasPrefix("sport.banner.item."), let current = Int(id.dropFirst("sport.banner.item.".count)) {
                XCUIRemote.shared.press(current < index ? .down : .up)
            } else if id.hasPrefix("sport.banner.") {
                XCUIRemote.shared.press(.right)
            } else {
                // Above the banner (the tab bar): down into it; below it: up.
                XCUIRemote.shared.press(focused(app).frame.maxY < banner.frame.minY ? .down : .up)
            }
        }
        XCTAssertEqual(focused(app).identifier, target)
        XCUIRemote.shared.press(.select)
    }

    /// Down from the banner until `identifier` has focus (or `presses` run out).
    private func moveDown(_ app: XCUIApplication, to identifier: String, presses: Int = 10) {
        for _ in 0..<presses where !focused(app).identifier.hasPrefix(identifier) { XCUIRemote.shared.press(.down) }
    }

    @MainActor
    func testMotorsportShowsF1sWeekendAndNASCARsRace() throws {
        let app = try launch(sport: "Motorsport", f1: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.page.league.F1"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.banner.item.0"].label.hasPrefix("Formula 1"), "the catalogue's label: \(any["sport.banner.item.0"].label)")
        XCTAssertTrue(any["f1.session.race"].waitForExistence(timeout: 5), "the session tiles")
        XCTAssertEqual(any.matching(NSPredicate(format: "identifier BEGINSWITH 'f1.session.'")).count, 5)
        XCTAssertTrue(any["f1.circuit"].exists)
        XCTAssertTrue(any["f1.results"].exists && any["f1.standings.drivers"].exists && any["f1.standings.constructors"].exists,
                      "the grid and both standings side by side")
        attach(app, "d43-motorsport-f1")
        selectLeague(app, 1)
        XCTAssertTrue(any["sport.page.league.NASCAR"].waitForExistence(timeout: 5), "NASCAR")
        XCTAssertTrue(any["sport.race.entries"].waitForExistence(timeout: 5), "the entry list")
        XCTAssertTrue(any["sport.race.last"].exists && any["sport.race.next"].exists)
        XCTAssertFalse(any["f1.session.race"].exists)
        attach(app, "d43-motorsport-nascar")
    }

    /// #243 (Apple 168): F1's weekend on the D-43 page, as the retired F1PageView's tests had it: spoiler-free hides the
    /// grid and both standings, and a race on now shows LIVE on its session tile (selecting it plays).
    @MainActor
    func testF1SpoilerFreeAndALiveRace() throws {
        var app = try launch(sport: "Motorsport", spoilers: true, f1: true)
        var any = app.descendants(matching: .any)
        XCTAssertTrue(any["f1.session.race"].waitForExistence(timeout: 5), "the session tiles")
        XCTAssertTrue(app.staticTexts["Results hidden"].exists, "spoiler-free hides the results")
        XCTAssertFalse(app.staticTexts["Kimi Antonelli"].exists, "no driver's name is left on screen")
        attach(app, "d43-f1-spoiler-free")
        app.terminate()
        app = try launch(sport: "Motorsport", f1Live: true)
        any = app.descendants(matching: .any)
        XCTAssertTrue(any["f1.session.race"].waitForExistence(timeout: 5))
        // a button's texts make its label on tvOS
        let live = any.matching(NSPredicate(format: "identifier BEGINSWITH 'f1.session.' AND label CONTAINS 'LIVE'"))
        XCTAssertEqual(live.count, 1, "the session on now is marked LIVE")
        XCTAssertTrue(app.staticTexts["Kimi Antonelli"].exists, "results and standings shown")
        attach(app, "d43-f1-live")
    }

    /// #243 (Apple 168): the NFL on the D-43 fixture page, as the retired NFLPageView's tests had it: the current week
    /// with the one before to switch to, the standings; following the Packers puts their conference first; spoiler-free
    /// hides scores and standings.
    @MainActor
    func testTheNFLWeeksStandingsFollowedTeamAndSpoilerFree() throws {
        var app = try launch(sport: "American football", nfl: true)
        var any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fixture.grid.8"].waitForExistence(timeout: 8), "opens on week 8")
        let unfollowed = any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.fixture.group.'")).allElementsBoundByIndex
        XCTAssertEqual(unfollowed.min { $0.frame.minY < $1.frame.minY }?.identifier, "sport.fixture.group.AFC", "AFC first unfollowed")
        XCTAssertTrue(app.staticTexts["27"].exists, "Thursday's final score")
        XCTAssertTrue(any["sport.fixture.round.7"].exists, "week 7 to switch to")
        attach(app, "d43-nfl-week-8")
        moveDown(app, to: "sport.fixture.round.")
        for _ in 0..<3 where focused(app).identifier != "sport.fixture.round.7" { XCUIRemote.shared.press(.left) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.fixture.grid.7"].waitForExistence(timeout: 5), "week 7")
        XCTAssertTrue(waitUntil(5) { app.staticTexts["24"].exists }, "week 7's finals")
        app.terminate()

        app = try launch(sport: "American football", nfl: true, nflFollow: "GB")
        any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fixture.grid.8"].waitForExistence(timeout: 8))
        let groups = any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.fixture.group.'")).allElementsBoundByIndex
        let first = groups.min { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(first?.identifier, "sport.fixture.group.NFC", "the Packers' conference first (AFC is first otherwise)")
        attach(app, "d43-nfl-following")
        app.terminate()

        app = try launch(sport: "American football", spoilers: true, nfl: true)
        any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fixture.standings.hidden"].waitForExistence(timeout: 8), "standings hidden")
        XCTAssertFalse(app.staticTexts["27"].exists, "no score with spoiler-free on")
        attach(app, "d43-nfl-spoiler-free")
    }

    @MainActor
    func testAFixtureLeagueShowsItsRoundAndStandings() throws {
        let app = try launch(sport: "Australian football")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fixture.grid.1:21"].waitForExistence(timeout: 8), "opens on the current round")
        attach(app, "d43-fixture-afl")
        XCTAssertTrue(any["sport.fixture.game.1134005"].exists, "Collingwood's live game")
        XCTAssertTrue(any["sport.fixture.table.all"].exists, "one table")
        moveDown(app, to: "sport.fixture.round.")
        XCTAssertTrue(focused(app).identifier.hasPrefix("sport.fixture.round."), focused(app).identifier)
        for _ in 0..<3 where focused(app).identifier != "sport.fixture.round.1:20" { XCUIRemote.shared.press(.left) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.fixture.grid.1:20"].waitForExistence(timeout: 5), "the last round")
        XCTAssertFalse(any["sport.fixture.grid.1:21"].exists)
        attach(app, "d43-fixture-afl-last-round")
    }

    @MainActor
    func testCricketsTwoLeaguesShowTheirOwnMatches() throws {
        let app = try launch(sport: "Cricket")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.page.league.Cricket"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.banner.item.0"].label.hasPrefix("International (men)"), any["sport.banner.item.0"].label)
        XCTAssertTrue(any["cricket.lead.1525661"].waitForExistence(timeout: 5), "the Test leads the internationals")
        attach(app, "d43-cricket-international")
        selectLeague(app, 1)
        XCTAssertTrue(any["sport.page.league.WBBL"].waitForExistence(timeout: 5), "WBBL")
        XCTAssertFalse(any["cricket.lead.1525661"].exists, "the Test is not the WBBL's lead")
        XCTAssertTrue(any["cricket.other.1543947"].waitForExistence(timeout: 5), "the WBBL's matches")
        attach(app, "d43-cricket-wbbl")
    }

    @MainActor
    func testUFCShowsTheMainCardAndThePrelims() throws {
        let app = try launch(sport: "Combat")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fight.main"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.fight.prelims"].exists)
        XCTAssertEqual(any["sport.bout.401914101.line"].label, "Szabová · R3 3:20")
        XCTAssertTrue(any["sport.banner.hero.kicker"].label.hasSuffix("YOUR FIGHTER"), any["sport.banner.hero.kicker"].label)
        attach(app, "d43-ufc")
    }

    @MainActor
    func testUFCHidesResultsWhenSpoilerFree() throws {
        let app = try launch(sport: "Combat", spoilers: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.fight.main"].waitForExistence(timeout: 5))
        XCTAssertEqual(any["sport.bout.401914101.line"].label, "Finished")
        attach(app, "d43-ufc-spoiler-free")
    }

    @MainActor
    func testTennisRailsWithAndWithoutAFollowedPlayer() throws {
        var app = try launch(sport: "Tennis")
        var any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.tennis.rail.live"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.tennis.rail.yours"].exists, "Claire Liu plays this week")
        XCTAssertTrue(any["sport.tennis.rail.results"].exists)
        attach(app, "d43-tennis-followed")
        app.terminate()
        app = try launch(sport: "Tennis", nobodyFollowed: true)
        any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.tennis.rail.live"].waitForExistence(timeout: 5))
        XCTAssertFalse(any["sport.tennis.rail.yours"].exists, "nobody followed this week: no Your players")
        attach(app, "d43-tennis-none")
    }

    @MainActor
    func testGolfWithAndWithoutAFollowedPlayer() throws {
        var app = try launch(sport: "Golf")
        var any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.golf.leaderboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.golf.yours"].exists)
        XCTAssertTrue(any["sport.golf.player.Min Woo Lee"].exists)
        XCTAssertTrue(any["sport.alsoThisWeek"].exists)
        attach(app, "d43-golf-followed")
        app.terminate()
        app = try launch(sport: "Golf", nobodyFollowed: true)
        any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.golf.leaderboard"].waitForExistence(timeout: 5))
        XCTAssertFalse(any["sport.golf.yours"].exists, "Also this week only")
        XCTAssertTrue(any["sport.alsoThisWeek"].exists)
        attach(app, "d43-golf-none")
    }
}
#endif
