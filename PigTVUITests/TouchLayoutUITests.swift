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

    /// D-65 (#266): on an iPhone, touch and hold opens a channel row in place (its quality chips and Record…) on the
    /// live picker as on the later one. Bug: on the live picker the hold did nothing (the row stayed closed).
    @MainActor
    func testPhoneTouchAndHoldOpensTheChannelRowLiveAndLater() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        for screen in ["sport-picker-qualities", "sport-picker-qualities-later"] {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
            app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark" // the bug showed in dark appearance
            app.launch()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.channel.'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "\(screen): no channel row")
            sleep(4) // as a person would: the page has settled (the live bug showed only then)
            let id = row.identifier
            row.press(forDuration: 0.8)
            XCTAssertTrue(app.descendants(matching: .any)["\(id).chips"].waitForExistence(timeout: 3), "\(screen): the hold did not open the row")
            XCTAssertTrue(app.buttons["\(id).record"].exists, "\(screen): no Record… in the opened row")
            app.terminate()
        }
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

    /// Apple 118 (Mark's check of 5a), remade for #358 (Mark's iPhone design): on an upright iPhone the record page is a
    /// half-height sheet: the primary full width, the second action a line under it; the Extra time row says its value
    /// on one line inside the sheet.
    @MainActor
    func testPhoneRecordSheetStacksItsActionsAndSaysItsExtraTime() throws {
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
            let second = app.buttons[screen == "record-change" ? "record.cancelRecording" : "record.close"]
            XCTAssertTrue(second.exists, "\(screen): no second action")
            XCTAssertGreaterThan(second.frame.minY, primary.frame.maxY - 1, "\(screen): the actions are not stacked")
            XCTAssertLessThan(second.frame.height, primary.frame.height * 1.5, "\(screen): the second action wraps")
            let extra = app.buttons["record.row.extra"]
            XCTAssertTrue(extra.exists, "\(screen): no Extra time row")
            XCTAssertLessThanOrEqual(extra.frame.maxX, width + 1, "\(screen): Extra time runs off the sheet: \(extra.frame)")
            if screen == "record-change" {
                XCTAssertTrue(extra.label.hasSuffix("2 min early, 15 min late"), extra.label)
            } else {
                XCTAssertTrue(extra.label.hasSuffix("Usual"), extra.label)
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "iphone-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// #358 (T3): each page of the record sheet on iPhone and iPad (Mark's designs): the main page, Channel, Extra time,
    /// Set to record, and Extra time once it records (Start early "Started"). On Extra time, + and − step one minute.
    @MainActor
    func testTouchRecordSheetPages() throws {
        XCUIDevice.shared.orientation = .portrait
        let device = UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
        let pages: [(name: String, screen: String, page: String?, flip: String?)] = [
            ("sheet", "record-sport", nil, nil), ("channel", "record-sport", "channel", nil), ("extra", "record-sport", "extra", nil),
            ("set", "record-change", nil, nil), ("extrarec", "record-change", "extra", "recording"), ("programme", "record", nil, nil),
        ]
        for item in pages {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = item.screen
            if let page = item.page { app.launchEnvironment["PIGTV_UI_TEST_RECORD_PAGE"] = page }
            if let flip = item.flip { app.launchEnvironment["PIGTV_UI_TEST_RECORD_FLIP"] = flip }
            app.launch()
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["record.page"].waitForExistence(timeout: 15), "\(item.name): no record page")
            switch item.name {
            case "channel":
                XCTAssertTrue(app.buttons["record.on.2"].waitForExistence(timeout: 5), "three channels")
                XCTAssertTrue(app.buttons["record.on.0"].isSelected)
                XCTAssertTrue(app.buttons["record.back"].exists)
            case "extra":
                let value = any["record.after.value"]
                XCTAssertTrue(value.waitForExistence(timeout: 5))
                XCTAssertEqual(value.label, "0 min", "a game ESPN follows: Finish late 0")
                XCTAssertFalse(app.buttons["record.after.less"].isEnabled, "no − under 0")
                app.buttons["record.after.more"].tap()
                app.buttons["record.after.more"].tap()
                XCTAssertTrue(waitUntil { value.label == "2 min" }, value.label)
            case "extrarec":
                XCTAssertTrue(waitUntil(12) { any["record.before.value"].label == "Started" }, "Start early once it records")
                XCTAssertFalse(app.buttons["record.before.more"].exists, "no + once it records")
                XCTAssertTrue(app.buttons["record.after.more"].exists, "Finish late still changes")
            case "set":
                XCTAssertTrue(any["record.state"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.buttons["record.schedule"].label, "Done")
            default:
                XCTAssertTrue(app.buttons["record.row.extra"].waitForExistence(timeout: 5))
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(device)-record-\(item.name)"
            shot.lifetime = .keepAlways
            add(shot)
            if item.name == "extra" {
                app.buttons["record.back"].tap()
                let row = app.buttons["record.row.extra"]
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                XCTAssertTrue(row.label.hasSuffix("1 min early, 2 min late"), row.label)
                let back = XCTAttachment(screenshot: app.screenshot())
                back.name = "\(device)-record-extra-chosen"
                back.lifetime = .keepAlways
                add(back)
            }
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
        XCTAssertFalse(app.staticTexts["in your order"].exists, "no words about the order (Mark, 14 Nov 2026)")
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
