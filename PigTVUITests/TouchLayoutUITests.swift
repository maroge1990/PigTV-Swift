import XCTest

#if os(iOS)
// 18 Oct (app test team), iPhone and iPad. Run on an iOS simulator (the tvOS tiers skip it): offline fixtures, no server.
final class TouchLayoutUITests: XCTestCase {
    private static let media = "/private/tmp/pig-deep-media/review.mp4"

    /// Bug: on an upright iPhone the Guide fitted its regular header, so Search kept its text and wrapped onto a second
    /// line. It is an icon now: about as wide as it is tall.
    @MainActor
    func testPhoneGuideSearchIsIconOnly() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Guide Search button not shown")
        let frame = search.frame
        XCTAssertLessThan(frame.width, frame.height * 1.6, "Search is \(frame.width) x \(frame.height): it still carries its text")
    }

    /// Bug: the touch player's TV Guide pill did nothing Close doesn't (it closed the player onto the Guide tab).
    @MainActor
    func testTouchPlayerHasNoTVGuideButton() throws {
        guard FileManager.default.fileExists(atPath: Self.media) else {
            throw XCTSkip("Generate local review media with Tools/generate-brand-review-media.sh first.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "player"
        app.launchEnvironment["PIGTV_UI_TEST_MEDIA"] = Self.media
        app.launch()
        XCTAssertTrue(app.buttons["player.channels"].waitForExistence(timeout: 20), "player controls not shown")
        XCTAssertFalse(app.buttons["player.guide"].exists, "the player still has a TV Guide button")
    }

    /// Apple 118 (Mark's check of 5a): on an upright iPhone Change recording's actions wrapped (Save changes clipped,
    /// "Cancel recording" on two lines), its eyebrow was cut and the chosen Finish late sat off screen. The actions are
    /// stacked full width, and the chosen chip is in view.
    @MainActor
    func testPhoneRecordPageStacksItsActionsAndShowsTheChosenChip() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        for screen in ["record-change", "record"] {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
            app.launch()
            let primary = app.buttons["record.schedule"]
            XCTAssertTrue(primary.waitForExistence(timeout: 15), "\(screen): no record page")
            let width = app.windows.firstMatch.frame.width
            XCTAssertGreaterThan(primary.frame.width, width * 0.7, "\(screen): the primary is \(primary.frame.width) wide of \(width)")
            let close = app.buttons["record.close"]
            XCTAssertGreaterThan(close.frame.minY, primary.frame.maxY - 1, "\(screen): the actions are not stacked")
            if screen == "record-change" {
                let cancel = app.buttons["record.cancelRecording"]
                XCTAssertGreaterThan(cancel.frame.width, width * 0.7, "Cancel recording is not full width")
                XCTAssertLessThan(cancel.frame.height, primary.frame.height * 1.5, "Cancel recording wraps")
                let chosen = app.buttons["record.after"]
                XCTAssertTrue(chosen.exists)
                XCTAssertTrue(chosen.label.contains("15 min"), "the chosen Finish late is shown: \(chosen.label)")
            }
            // #253: Start early / Finish late are one line each, a menu on the right inside the card (chips ran past its edge).
            for id in ["record.before", "record.after"] {
                let menu = app.buttons[id]
                XCTAssertTrue(menu.exists, "\(screen): no \(id) menu")
                XCTAssertLessThanOrEqual(menu.frame.maxX, width - 8, "\(screen): \(id) runs off the card: \(menu.frame)")
            }
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'record.after.'")).count, 0, "\(screen): no chips")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "iphone-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// #255: in iPhone landscape a programme's or channel's menu ran off the bottom of the screen (its last rows could not
    /// be reached). It is capped at the screen and its rows scroll.
    @MainActor
    func testPhoneLandscapeGuideMenuReachesItsLastRow() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.collectionViews.firstMatch.cells.firstMatch.waitForExistence(timeout: 15), "no guide")
        sleep(1)
        // A programme in the grid (its menu has the Record section, the longest).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).press(forDuration: 1.2)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'menu.'"))
        XCTAssertTrue(app.buttons["menu.recordThis"].waitForExistence(timeout: 5), "no programme menu")
        let screen = app.windows.firstMatch.frame
        func lastRowIsOnScreen(_ which: String) throws {
            let last = try XCTUnwrap(rows.allElementsBoundByIndex.max { $0.frame.maxY < $1.frame.maxY })
            let scroll = app.scrollViews["menu.scroll"]
            if scroll.exists { scroll.swipeUp(); sleep(1) }
            XCTAssertLessThanOrEqual(last.frame.maxY, screen.maxY, "\(which): \(last.identifier) runs off the screen: \(last.frame)")
        }
        try lastRowIsOnScreen("the programme's menu")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iphone-landscape-menu"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// #258: on iPad, Settings' header and pig sat level with every tab's on first opening, then 64 pt higher (at the top
    /// of the screen) every later time: the system split view dropped the tab bar's inset.
    @MainActor
    func testPadSettingsHeaderStaysPutOnASecondVisit() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(identifier: "page.header.title").matching(NSPredicate(format: "label == 'Settings'")).firstMatch
        settings.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        sleep(1)
        let first = title.frame
        app.buttons["TV Guide"].firstMatch.tap()
        sleep(1)
        settings.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(title.frame.minY, first.minY, accuracy: 1, "the header moved: \(first) then \(title.frame)")
    }

    /// #317 (Mark, 14 Nov 2026): Settings › Sport's sports and a sport's leagues always show their reorder handles and are
    /// dragged by them: no Edit order, no Move up / Move down, no words; a tap on a sport still opens its page.
    @MainActor
    func testPhoneSportsAndLeaguesAreReorderedByDraggingWithoutEditOrder() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "settings-sport"
        app.launchEnvironment["PIGTV_UI_TEST_SETTINGS_PAGE"] = "sport"
        app.launch()
        sleep(4) // the offline fixture signs in and applies its follows after the page appears
        let menu = app.buttons["settings.menu.sport"]
        if menu.exists { menu.tap() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.sport.row.'"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 15), "two followed sports")
        sleep(2) // the follows can be changed once loaded (dragging is off before)
        XCTAssertFalse(app.buttons["settings.sport.order"].exists, "no Edit order")
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertEqual(handles.count, rows.count, "every sport shows its reorder handle: \(app.buttons.allElementsBoundByIndex.map(\.label))")
        let before = rows.allElementsBoundByIndex.map(\.identifier)
        handles.element(boundBy: 1).press(forDuration: 0.8, thenDragTo: handles.element(boundBy: 0), withVelocity: .slow,
                                             thenHoldForDuration: 0.5)
        XCTAssertTrue(waitUntil(5) { rows.allElementsBoundByIndex.map(\.identifier) == [before[1], before[0]] + before.dropFirst(2) },
                      "not reordered: \(rows.allElementsBoundByIndex.map(\.identifier))")
        attach(app, "iphone-sport-drag")

        app.buttons["settings.sport.row.Football"].tap()
        XCTAssertTrue(app.buttons["settings.sport.stop"].waitForExistence(timeout: 5), "a tap opens the sport's page")
        XCTAssertFalse(app.buttons["settings.sport.moveUp"].exists, "no Move up / Move down")
        XCTAssertFalse(app.buttons["settings.sport.league.Champions League.up"].exists, "nor on a league")
        let first = app.staticTexts["Premier League"], second = app.staticTexts["Champions League"]
        XCTAssertTrue(first.waitForExistence(timeout: 5) && second.exists, "Football's two leagues")
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        let leagueHandles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertEqual(leagueHandles.count, 2, "each league shows its reorder handle: \(app.buttons.allElementsBoundByIndex.map(\.label))")
        leagueHandles.element(boundBy: 1).press(forDuration: 0.8, thenDragTo: leagueHandles.element(boundBy: 0), withVelocity: .slow,
                                                   thenHoldForDuration: 0.5)
        XCTAssertTrue(waitUntil(5) { second.frame.minY < first.frame.minY },
                      "league not reordered: \(first.frame) \(second.frame)")
        attach(app, "iphone-sport-league-drag")

        // In edit mode a NavigationLink does not open: every row that pushes a page still does.
        let follow = app.buttons["settings.sport.follow"]
        for _ in 0..<6 where !(follow.exists && follow.isHittable) { app.swipeUp() }
        XCTAssertTrue(follow.isHittable, "Follow a team… not found")
        follow.tap()
        XCTAssertTrue(waitUntil(5) { !follow.exists || !follow.isHittable }, "Follow a team… did not open")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(follow.waitForExistence(timeout: 5), "back on Football")
        app.navigationBars.buttons.firstMatch.tap()
        let add = app.buttons["settings.sport.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "back on Settings › Sport")
        add.tap()
        XCTAssertTrue(app.navigationBars["Add a sport"].waitForExistence(timeout: 5), "Add a sport did not open")
        app.navigationBars.buttons.firstMatch.tap()
        let delay = app.buttons["settings.sport.delay"]
        XCTAssertTrue(delay.waitForExistence(timeout: 5), "back on Settings › Sport")
        delay.tap()
        XCTAssertTrue(app.navigationBars["Score delay"].waitForExistence(timeout: 5), "Score delay did not open")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// #257 (Mark, 8 Nov): a live event carried by several channels: the long-press menu offers "Watch on… (N channels)",
    /// and the channel is chosen before the player opens.
    @MainActor
    func testPhoneGuideMenuOffersWatchOnForALiveEventOnSeveralChannels() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launchEnvironment["PIGTV_UI_TEST_WATCH_ON"] = "1"
        app.launch()
        let list = app.collectionViews["guide.onNow"]
        XCTAssertTrue(list.waitForExistence(timeout: 15), "On now list not shown")
        sleep(1)
        list.cells.element(boundBy: 0).press(forDuration: 1.2)
        let watchOn = app.buttons["Watch on… (3 channels)"].firstMatch
        XCTAssertTrue(watchOn.waitForExistence(timeout: 5), "no Watch on…: \(app.buttons.allElementsBoundByIndex.map(\.label))")
        watchOn.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'watchOn.'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5), "no channel list")
        XCTAssertEqual(Set(choices.allElementsBoundByIndex.map(\.identifier)).count, 3, "one choice per channel")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iphone-watch-on"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
