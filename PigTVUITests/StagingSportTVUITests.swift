import XCTest

#if os(tvOS)
// T3 against the Unraid staging server (fake providers, ESPN's free feeds): signs in with the remote, then attaches
// screenshots of the Sport front page (its banner, then its follows list scrolled), each sport page opened from its
// rail header (or its "Also in your sports" button), the second league where a sport has two, and Settings › Sport.
// Read-only: no follow, switch or recording is changed. Skipped unless the test runner is given the staging address and
// its throwaway login (TEST_RUNNER_PIGTV_STAGING_URL, …_USER, …_PASS); never a real server.
final class StagingSportTVUITests: XCTestCase {
    private var shot = 0

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        shot += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%02d-%@", shot, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: 0.35)
    }

    /// Moves focus onto `target` with the remote, steering by the frames; true when it got there.
    @discardableResult
    private func focus(_ app: XCUIApplication, on target: XCUIElement, presses: Int = 40) -> Bool {
        for _ in 0..<presses {
            if target.hasFocus { return true }
            let current = focused(app)
            guard current.exists else { press(.down); continue }
            let to = target.frame, from = current.frame
            if from.midY < to.minY - 1 {
                press(.down)
            } else if from.minY > to.maxY + 1 {
                // A card in the rail under the target header: left to the rail's start first, then up.
                if from.minY - to.maxY < 420 && from.minX > to.maxX + 40 { press(.left) } else { press(.up) }
            } else if from.midX > to.midX {
                press(.left)
            } else {
                press(.right)
            }
        }
        return target.hasFocus
    }

    /// Waits for any element whose identifier starts with one of `prefixes`; the first found, else nil.
    private func waitForAny(_ app: XCUIApplication, _ prefixes: [String], timeout: TimeInterval = 25) -> String? {
        let any = app.descendants(matching: .any)
        var found: String?
        _ = waitUntil(timeout) {
            for prefix in prefixes {
                let match = any.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
                if match.exists { found = match.identifier; return true }
            }
            return false
        }
        return found
    }

    private func identifiers(_ app: XCUIApplication, _ prefix: String) -> [String] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex.map(\.identifier)
    }

    /// Selects a text field with the remote, types into the keyboard and leaves it.
    private func type(_ app: XCUIApplication, into field: XCUIElement, _ text: String) {
        XCTAssertTrue(focus(app, on: field, presses: 12), "could not reach a sign-in field: \(focused(app).identifier)")
        // The simulator may remember an earlier address: clear whatever the field holds first.
        let held = (field.value as? String).map { $0 == field.placeholderValue ? 0 : $0.count } ?? 0
        press(.select)
        Thread.sleep(forTimeInterval: 1)
        if held > 0 { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: held + 4)) }
        app.typeText(text)
        Thread.sleep(forTimeInterval: 0.5)
        press(.menu) // back from the keyboard to the form
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func signIn(_ app: XCUIApplication, url: String, user: String, pass: String) {
        let server = app.textFields["http://pigtv.local:3000"]
        guard server.waitForExistence(timeout: 15) else { return } // already signed in
        type(app, into: server, url)
        note("server-field", "typed \(url.count) chars, field holds \"\(server.value as? String ?? "?")\"")
        attach(app, "signin-after-server")
        type(app, into: app.textFields["Username"], user)
        type(app, into: app.secureTextFields["Password"], pass)
        let signIn = app.buttons["Sign in"]
        XCTAssertTrue(focus(app, on: signIn, presses: 12), "could not reach Sign in: \(focused(app).identifier)")
        press(.select)
    }

    /// Focus onto the banner row whose label starts with `title` and select it; false when there is none.
    private func selectLeague(_ app: XCUIApplication, _ title: String) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sport.banner.item.' AND label BEGINSWITH %@", title)).firstMatch
        guard row.waitForExistence(timeout: 10) else { return false }
        guard focus(app, on: row, presses: 20) else { return false }
        press(.select)
        return true
    }

    /// From the front page, opens `sport` by its rail header (else its "Also in your sports" button); its page, or nil.
    private func open(_ app: XCUIApplication, sport: String) -> Bool {
        let header = app.buttons["sport.rail.header.\(sport)"]
        let also = app.buttons["sport.also.\(sport)"]
        let target = header.exists ? header : also
        guard target.exists, focus(app, on: target) else { return false }
        press(.select)
        return app.descendants(matching: .any)["sport.page.\(sport)"].waitForExistence(timeout: 15)
    }

    private func back(_ app: XCUIApplication, from sport: String) {
        press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["sport.page.\(sport)"].waitForNonExistence(timeout: 10),
                      "Menu did not leave \(sport)'s page")
        XCTAssertTrue(app.descendants(matching: .any)["sport.front"].waitForExistence(timeout: 10))
    }

    /// The content markers each league's page shows once loaded.
    private static let markers = ["f1.session.", "f1.weekend", "sport.race.", "sport.fixture.grid.", "sport.fixture.game.",
                                  "nfl.week.", "cricket.lead.", "cricket.other.", "sport.tennis.rail.", "sport.golf.leaderboard",
                                  "sport.fight.main", "sport.front.game."]

    /// Waits for the page's content and its images, then attaches it; notes what it found.
    private func capture(_ app: XCUIApplication, _ name: String, log: inout [String]) {
        let league = waitForAny(app, ["sport.page.league."], timeout: 15) ?? "no league"
        let marker = waitForAny(app, Self.markers, timeout: 25) ?? "NO CONTENT MARKER"
        Thread.sleep(forTimeInterval: 3) // badges and the circuit map load after the answer
        let hero = app.descendants(matching: .any)["sport.banner.hero.title"]
        log.append("\(name): \(league), first marker \(marker), hero \"\(hero.exists ? hero.label : "none")\", "
                   + "leagues \(identifiers(app, "sport.banner.item.").count)")
        attach(app, name)
    }

    @MainActor
    func testTheSportPagesOnStaging() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["PIGTV_STAGING_URL"], let user = env["PIGTV_STAGING_USER"], let pass = env["PIGTV_STAGING_PASS"],
              !url.isEmpty, !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("no staging server given")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        signIn(app, url: url, user: user, pass: pass)
        var log: [String] = []

        // 1. The front page with its banner.
        let sportTab = app.tabBars.buttons["Sport"]
        XCTAssertTrue(sportTab.waitForExistence(timeout: 40), "not signed in")
        let any = app.descendants(matching: .any)
        if !any["sport.front"].waitForExistence(timeout: 5) {
            XCTAssertTrue(focus(app, on: sportTab, presses: 10)); press(.select)
        }
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 30), "the front page did not open")
        let hero = any["sport.banner.hero.title"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "no banner: \(any["sport.front.empty"].exists ? "empty state" : "unavailable")")
        _ = waitForAny(app, ["sport.front.rail."], timeout: 20)
        Thread.sleep(forTimeInterval: 3)
        let headers = identifiers(app, "sport.rail.header.").map { String($0.dropFirst("sport.rail.header.".count)) }
        let also = identifiers(app, "sport.also.").map { String($0.dropFirst("sport.also.".count)) }
        let follows = identifiers(app, "sport.banner.item.").count
        log.append("front: hero \"\(hero.label)\", \(follows) follows, rails \(identifiers(app, "sport.front.rail."))"
                   + ", headers \(headers), also \(also), stale \(any["sport.front.stale"].exists)"
                   + ", scoresUnavailable \(any["sport.front.scoresUnavailable"].exists)")
        attach(app, "front")

        // 2. The banner's list scrolled: focus down through every follow.
        let first = any["sport.banner.item.0"]
        // The hero's buttons sit under the list's first rows: right across to the list, then up to its first row.
        for _ in 0..<6 where !focused(app).identifier.hasPrefix("sport.banner.item.") {
            press(focused(app).identifier.hasPrefix("sport.banner.") ? .right : .down)
        }
        if follows > 0, focus(app, on: first, presses: 15) {
            for _ in 1..<max(follows, 2) { press(.down) }
            Thread.sleep(forTimeInterval: 1)
            log.append("banner list scrolled to \(focused(app).identifier), more line \"\(any["sport.banner.more"].label)\"")
            attach(app, "front-banner-list-scrolled")
        } else {
            log.append("banner list: could not focus it (\(focused(app).identifier))")
        }

        // 3. Each sport page from its rail header.
        let pages: [(sport: String, name: String, then: [(title: String, name: String)])] = [
            ("Motorsport", "motorsport", [("NASCAR", "motorsport-nascar")]),
            ("American football", "american-football-nfl", []),
            ("Australian football", "australian-football-afl", []),
            ("Cricket", "cricket", [("International", "cricket-international"), ("WBBL", "cricket-wbbl")]),
            ("Tennis", "tennis", []),
            ("Golf", "golf", []),
            ("Combat", "combat-ufc", []),
        ]
        for page in pages {
            guard open(app, sport: page.sport) else {
                XCTFail("could not open \(page.sport) (focus \(focused(app).identifier))")
                log.append("\(page.sport): NOT OPENED")
                continue
            }
            capture(app, page.name, log: &log)
            for league in page.then {
                if selectLeague(app, league.title) {
                    capture(app, league.name, log: &log)
                } else {
                    XCTFail("\(page.sport): no banner row \(league.title)")
                    log.append("\(league.name): NO ROW (rows \(identifiers(app, "sport.banner.item.").map { any[$0].label }))")
                }
            }
            back(app, from: page.sport)
        }

        // 4. Settings › Sport.
        for _ in 0..<40 where !app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            press(.up)
        }
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(focus(app, on: settings, presses: 8), "no Settings tab: \(focused(app).identifier)")
        press(.select)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.sport.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no Sport section in Settings")
        XCTAssertTrue(focus(app, on: rows.firstMatch, presses: 30), "could not reach the Sport section: \(focused(app).identifier)")
        Thread.sleep(forTimeInterval: 1)
        log.append("settings: rows \(rows.allElementsBoundByIndex.map(\.identifier)), spoilerFree "
                   + "\(app.buttons["settings.sport.spoilerFree"].value ?? "?"), failed \(any["settings.sport.failed"].exists)")
        attach(app, "settings-sport")
        press(.select)
        if app.buttons["settings.sport.stop"].waitForExistence(timeout: 10) {
            Thread.sleep(forTimeInterval: 1)
            attach(app, "settings-sport-first-sport")
            press(.menu)
        }
        note("staging-sport-log", log.joined(separator: "\n"))
    }
}
#endif
