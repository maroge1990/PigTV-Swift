import XCTest

#if os(tvOS)
// D-43 (1 Nov): the Apple TV front page without sport tiles, its banner's list scrolling in place, and the sport pages,
// on PigTVTests/Fixtures/sport-front-0427.json (read from the source tree: simulator runs are on the Mac) with its times
// moved to the real clock: Football (EPL with the followed Liverpool live, Champions League), Motorsport (F1 only),
// Basketball (NBA, NBL, nothing on for the account), Tennis (nothing in 72 hours); seven follows. No server.
// Screenshots go to the test's attachments and, with TEST_RUNNER_PIGTV_SCREENSHOT_DIR, to that folder (T3).
final class SportBannerUITests: XCTestCase {
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

    /// Every time in the answer moved by the same amount, so "now" is the real clock.
    private static func shifted(_ value: Any, by delta: Double) -> Any {
        if var dict = value as? [String: Any] {
            for (key, inner) in dict {
                if ["now", "start", "end", "observedAt"].contains(key), let number = inner as? Double {
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

    private func launch() throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-front-0427.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_F1"] = "1"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["sport.front"].waitForExistence(timeout: 15), "the Sport front page")
        return app
    }

    /// Down from the tab bar to `target`, through the banner and the rails, keeping to the left edge (a rail's
    /// header sits above its first card).
    private func moveDown(_ app: XCUIApplication, to target: String, presses: Int = 24) {
        for _ in 0..<presses where focused(app).identifier != target {
            let id = focused(app).identifier
            if id.hasPrefix("sport.front.game.") || id.hasPrefix("sport.banner.item.") {
                XCUIRemote.shared.press(.left)
                if focused(app).identifier != id { continue }
            }
            XCUIRemote.shared.press(.down)
        }
    }

    @MainActor
    func testTheFrontPageHasNoTilesAndTheBannerListScrollsInPlace() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        let banner = any["sport.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the banner")
        XCTAssertEqual(any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.front.tile.'")).count, 0, "no sport tiles")
        XCTAssertFalse(any["sport.front.addSport"].exists)
        XCTAssertEqual(any["sport.banner.hero.title"].label, "Liverpool v Man City", "C-R's hero")
        XCTAssertTrue(app.buttons["sport.banner.hero.watch"].exists, "Watch: its channel airs it now")
        for sport in ["Football", "Motorsport", "Basketball"] {
            XCTAssertTrue(any["sport.rail.header.\(sport)"].exists, "\(sport)'s rail header")
        }
        XCTAssertTrue(any["sport.also.Tennis"].exists, "Tennis has nothing in 72 hours: Also in your sports")
        XCTAssertFalse(any["sport.rail.header.Tennis"].exists)
        let list = any["sport.banner.list"]
        let more = any["sport.banner.more"]
        // #279 (Apple 199): three 56 pt rows on the television (four 36 pt rows before), the count in the header line.
        let visible = 3, row: CGFloat = 56, gap: CGFloat = 8, room: CGFloat = 6
        XCTAssertTrue(more.label.hasPrefix("\(7 - visible) more"), more.label)
        // The banner's own frame takes in the list's rows out of view; its fixed list and what sits below it show its height.
        let header = any["sport.rail.header.Football"]
        let below = header.frame.minY
        XCTAssertEqual(list.frame.height, CGFloat(visible) * row + CGFloat(visible - 1) * gap + 2 * room, accuracy: 2,
                       "\(visible) rows high")
        XCTAssertEqual(below - banner.frame.minY, 250 + 20, accuracy: 30, "250 pt, then the rails")
        func onShow(_ index: Int) -> Bool {
            let item = any["sport.banner.item.\(index)"]
            return item.exists && list.frame.intersection(item.frame).height > item.frame.height / 2
        }
        XCTAssertTrue((0..<visible).allSatisfy(onShow), "\(visible) items")
        XCTAssertFalse(onShow(visible), "the next is below the window")
        attach(app, "d43-front")

        // Into the list and down past the fourth: the list scrolls inside the banner, which keeps its height.
        for _ in 0..<12 where focused(app).identifier != "sport.banner.item.0" {
            let id = focused(app).identifier
            XCUIRemote.shared.press(id.hasPrefix("sport.banner.item.") ? .up : id.hasPrefix("sport.banner.") ? .right : .down)
        }
        XCTAssertEqual(focused(app).identifier, "sport.banner.item.0")
        for _ in 0..<5 { XCUIRemote.shared.press(.down) }
        XCTAssertEqual(focused(app).identifier, "sport.banner.item.5", "focus stays in the list")
        XCTAssertTrue(waitUntil(3) { onShow(5) && !(0...(5 - visible)).contains(where: onShow) }, "the window scrolled")
        XCTAssertEqual(header.frame.minY, below, accuracy: 1, "the banner never grows")
        XCTAssertTrue(waitUntil(3) { more.label.hasPrefix("1 more") }, more.label)
        attach(app, "d43-front-list-scrolled")
    }

    /// #233 (Mark, Apple 149): scrolling the follows up from the bottom, focus jumped past the 4th item from the top and
    /// then back down: the list scrolled itself (an animated scrollTo) while tvOS scrolled it too, and focus was judged
    /// against moving rows. Each press now moves focus one item, down and back up.
    @MainActor
    func testFocusMovesOneFollowPerPressBothWays() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.banner"].waitForExistence(timeout: 5))
        for _ in 0..<12 where focused(app).identifier != "sport.banner.item.0" {
            let id = focused(app).identifier
            XCUIRemote.shared.press(id.hasPrefix("sport.banner.item.") ? .up : id.hasPrefix("sport.banner.") ? .right : .down)
        }
        XCTAssertEqual(focused(app).identifier, "sport.banner.item.0")
        // Quick presses, as a viewer scrolls (the list's own scroll animation is still running between them).
        for _ in 0..<6 { XCUIRemote.shared.press(.down); Thread.sleep(forTimeInterval: 0.12) }
        XCTAssertTrue(waitUntil(3) { focused(app).identifier == "sport.banner.item.6" }, "down to the last: \(focused(app).identifier)")
        var path: [String] = []
        for _ in 0..<6 {
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 0.12)
            path.append(focused(app).identifier)
        }
        XCTAssertEqual(path, (0...5).reversed().map { "sport.banner.item.\($0)" })
    }

    @MainActor
    func testARailHeaderOpensTheSportPageWhoseBannerListsItsLeagues() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        moveDown(app, to: "sport.rail.header.Football")
        XCTAssertEqual(focused(app).identifier, "sport.rail.header.Football")
        XCUIRemote.shared.press(.select)
        let page = any["sport.page.Football"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "Football's sport page")
        XCTAssertTrue(any["sport.banner.list"].exists, "two leagues: the list")
        XCTAssertEqual(any["sport.banner.item.0"].label.hasPrefix("EPL"), true, any["sport.banner.item.0"].label)
        XCTAssertTrue(any["sport.banner.item.1"].label.hasPrefix("Champions League"))
        XCTAssertFalse(any["sport.banner.item.2"].exists)
        XCTAssertEqual(any["sport.banner.hero.title"].label, "Liverpool v Man City", "a follow live in this sport")
        XCTAssertTrue(any["sport.page.league.EPL"].waitForExistence(timeout: 5), "opens on the hero's league")
        attach(app, "d43-sport-two-leagues")

        // The other league flips the content below.
        for _ in 0..<10 where focused(app).identifier != "sport.banner.item.1" {
            let id = focused(app).identifier
            XCUIRemote.shared.press(id.hasPrefix("sport.banner.item.") ? .down : id.hasPrefix("sport.banner.") ? .right : .up)
        }
        XCTAssertEqual(focused(app).identifier, "sport.banner.item.1")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.page.league.Champions League"].waitForExistence(timeout: 5), "the league flipped")
        XCTAssertFalse(any["sport.page.league.EPL"].exists)
        XCTAssertTrue(any["sport.front.game.espn:soccer/uefa.champions:1"].exists, "its games as cards")
        attach(app, "d43-sport-league-flipped")

        // Back to the front page, focus on the header it left from.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil(5) { !page.exists }, "back on the front page")
        XCTAssertTrue(waitUntil(5) { self.focused(app).identifier == "sport.rail.header.Football" },
                      "focus restored: \(focused(app).identifier)")
    }

    @MainActor
    func testAOneLeagueSportHasAFullWidthBanner() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        moveDown(app, to: "sport.rail.header.Motorsport")
        XCTAssertEqual(focused(app).identifier, "sport.rail.header.Motorsport")
        let width = any["sport.banner"].frame.width
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.page.Motorsport"].waitForExistence(timeout: 10), "Motorsport's sport page")
        let banner = any["sport.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertFalse(any["sport.banner.list"].exists, "no list and no line")
        XCTAssertEqual(banner.frame.width, width, accuracy: 4, "the front page's banner width")
        let title = any["sport.banner.hero.title"]
        XCTAssertGreaterThan(banner.frame.maxX - title.frame.maxX, 0)
        XCTAssertTrue(app.buttons["sport.banner.back"].exists, "back")
        XCTAssertEqual(any["sport.banner.hero.title"].label, "Mexico City Grand Prix", "Piastri's next race")
        XCTAssertTrue(any["sport.page.league.F1"].exists, "the F1 page under the banner")
        XCTAssertTrue(any["f1.standings.drivers"].waitForExistence(timeout: 5), "the F1 page's standings (D-43: drivers and constructors apart)")
        XCTAssertFalse(any["f1.following"].exists, "without its own header")
        XCTAssertFalse(any["f1.weekend"].exists, "and without its own hero")
        attach(app, "d43-sport-one-league")
    }

    @MainActor
    func testAQuietSportShowsTheLeaguesNextGameAndANothingSportItsWords() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        moveDown(app, to: "sport.rail.header.Basketball")
        XCTAssertEqual(focused(app).identifier, "sport.rail.header.Basketball")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.page.Basketball"].waitForExistence(timeout: 10))
        XCTAssertEqual(any["sport.banner.hero.title"].label, "Warriors v Suns", "the league's next game")
        XCTAssertTrue(any["sport.banner.hero.kicker"].label.hasPrefix("NEXT"), any["sport.banner.hero.kicker"].label)
        XCTAssertTrue(app.buttons["sport.banner.hero.remind"].exists, "Remind me")
        attach(app, "d43-sport-quiet")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil(5) { !any["sport.page.Basketball"].exists })

        moveDown(app, to: "sport.also.Tennis", presses: 30)
        XCTAssertEqual(focused(app).identifier, "sport.also.Tennis")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(any["sport.page.Tennis"].waitForExistence(timeout: 10), "Also in your sports opens the page")
        XCTAssertEqual(any["sport.banner.hero.line"].label, "Nothing in the next three days", "never an empty banner")
        attach(app, "d43-sport-nothing")
    }
}
#endif
