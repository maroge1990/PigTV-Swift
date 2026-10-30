import XCTest

#if os(tvOS)
  final class SportsDashboardUITests: XCTestCase {
    @MainActor func testSameSportCardsHaveUniformSizeAndOmitRepeatedSportName() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "hidden"
      app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
      app.launch()
      let first = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      let missing = app.buttons["sportsDashboard.game.fixture-AFL-no channel"]
      let unavailable = app.buttons["sportsDashboard.game.fixture-AFL-unavailable"]
      XCTAssertTrue(first.waitForExistence(timeout: 10))
      XCTAssertLessThan(first.frame.height, 380, "Basic sport cards should be shorter than build 60")
      XCTAssertTrue(missing.exists)
      XCTAssertTrue(unavailable.exists)
      XCTAssertEqual(
        first.frame.height, missing.frame.height, accuracy: 1,
        "Missing-data cards keep the sport shelf's size")
      XCTAssertEqual(first.frame.height, unavailable.frame.height, accuracy: 1)
      XCTAssertEqual(first.frame.width, missing.frame.width, accuracy: 1)
      XCTAssertFalse(
        first.label.contains("AFL ·"), "The shelf already names the sport: \(first.label)")
    }

    @MainActor func testHiddenFirstRenderUsesSameNeutralAccessibleCardAndOffersLongPressDetails()
      throws
    {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "hidden"
      app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
      app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_WATCHABLE"] = "1"
      app.launch()
      let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      XCTAssertTrue(card.waitForExistence(timeout: 10))
      XCTAssertTrue(card.label.contains("Scores hidden"), card.label)
      XCTAssertFalse(card.label.contains("101"), card.label)
      XCTAssertFalse(card.label.contains("99"), card.label)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "dashboard-hidden-dark"
      shot.lifetime = .keepAlways
      add(shot)
      // Native remote focus reaches a card; preview actions never obtain a stream.
      focus(card, in: app)
      XCUIRemote.shared.press(.select, forDuration: 1.5)
      XCTAssertTrue(
        app.buttons["Record on Fixture Sports HD"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons["Watch Fixture Sports HD"].exists)
      // The primary action's refusal appears within a second or two when it runs (short Select, below), so give
      // it that long to show up before calling its absence proof.
      let refusal = app.staticTexts["Illustrative preview · playback and recording are disabled."]
      let appeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: refusal)
      XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 3), .timedOut, "A hold must not also invoke primary Watch")
    }
    @MainActor func testShortSelectStillUsesPrimaryWatchAction() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_WATCHABLE"] = "1"
      app.launch()
      let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      XCTAssertTrue(card.waitForExistence(timeout: 10))
      focus(card, in: app)
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(app.staticTexts["Illustrative preview · playback and recording are disabled."].waitForExistence(timeout: 5),
                    "Short Select must still reach the ordinary revalidated Watch action; the fixture refuses acquisition")
    }
    @MainActor func testDelayPresetsKeepRemoteFocusDuringSaving() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_SAVE_DELAY_MS"] = "3000"
      app.launch()
      XCTAssertTrue(app.buttons["sportsDashboard.settings"].waitForExistence(timeout: 10))
      focus(app.buttons["sportsDashboard.settings"], in: app)
      XCUIRemote.shared.press(.select)
      let preset = app.buttons["sportsDashboard.delay.120"]
      XCTAssertTrue(preset.waitForExistence(timeout: 5), "A delay preset should be reachable directly")
      guard preset.exists else { return }
      focus(preset, in: app)
      XCUIRemote.shared.press(.select)
      let saving = app.staticTexts["Saving settings…"]
      XCTAssertTrue(saving.waitForExistence(timeout: 3))
      XCTAssertTrue(preset.exists)
      XCTAssertEqual(focused(app).identifier, preset.identifier)
      let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saving)
      XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
      XCTAssertEqual(focused(app).identifier, preset.identifier)
      XCTAssertTrue(app.staticTexts["Score delay: 120 seconds"].exists)
    }
    /// Mark's bug (build 61): after Hold Select → "Watch <second channel>", the tuning player was on screen but
    /// Up/Down moved focus through the hidden dashboard behind it until the picture was ready.
    @MainActor func testWatchingASecondChannelFromDetailsKeepsRemoteFocusInThePlayer() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_PLAY"] = "1"
      if let latency = ProcessInfo.processInfo.environment["PIGTV_DASHBOARD_LATENCY_MS"] {
        app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_LATENCY_MS"] = latency
      }
      app.launch()
      let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      XCTAssertTrue(card.waitForExistence(timeout: 10))
      focus(card, in: app)
      XCUIRemote.shared.press(.select, forDuration: 1.5)
      let second = app.buttons["Watch Fixture Sports 2"]
      XCTAssertTrue(second.waitForExistence(timeout: 5))
      focus(second, in: app)
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(app.staticTexts["Tuning…"].waitForExistence(timeout: 8), "The player should be tuning")
      var trace: [String] = []
      defer {
        let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
        attachment.name = "Focus while tuning"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      // The old window lasted until the picture was ready; the fixture never becomes ready, so sample a few seconds.
      for press in [XCUIRemote.Button.down, .up, .down, .down] {
        XCUIRemote.shared.press(press)
        Thread.sleep(forTimeInterval: 0.5)
        let current = focused(app)
        let identifier = current.exists ? current.identifier : "<none>"
        trace.append("\(press.rawValue): \(identifier) / \(current.exists ? current.label : "")")
        XCTAssertFalse(identifier.hasPrefix("sportsDashboard."), "Focus moved behind the player: \(identifier)")
        XCTAssertTrue(current.exists && current.label == "Cancel", "Focus should be on the tuning card's Cancel")
      }
      XCTAssertTrue(app.staticTexts["Tuning…"].exists)
    }
    /// Review fix (b): Watch revalidates the airing while details are still up, and closes them only to play
    /// (the player is presented synchronously in onDismiss, like the legacy Sport presenter).
    @MainActor func testWatchFromDetailsRevalidatesBeforeClosingThem() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_PLAY"] = "1"
      app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_LATENCY_MS"] = "3000"
      app.launch()
      let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      XCTAssertTrue(card.waitForExistence(timeout: 10))
      focus(card, in: app)
      XCUIRemote.shared.press(.select, forDuration: 1.5)
      let second = app.buttons["Watch Fixture Sports 2"]
      XCTAssertTrue(second.waitForExistence(timeout: 8))
      focus(second, in: app)
      XCUIRemote.shared.press(.select)
      Thread.sleep(forTimeInterval: 1.2)
      XCTAssertTrue(second.exists, "Details closed before the 3 s revalidation finished")
      XCTAssertFalse(app.staticTexts["Tuning…"].exists)
      XCTAssertTrue(app.staticTexts["Tuning…"].waitForExistence(timeout: 10), "The revalidated channel plays")
    }
    @MainActor private func focused(_ app: XCUIApplication) -> XCUIElement {
      app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }
    @MainActor private func focus(_ element: XCUIElement, in app: XCUIApplication) {
      var trace: [String] = []
      defer {
        let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
        attachment.name = "Remote focus trace"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      for _ in 0..<12 {
        let current = focused(app)
        if (!element.identifier.isEmpty && current.identifier == element.identifier) || (!element.label.isEmpty && current.label == element.label) { return }
        let from = current.frame, to = element.frame
        trace.append("\(current.identifier) / \(current.label) \(from) => \(element.identifier) \(to)")
        if element.identifier == "sportsDashboard.settings", current.identifier == "sportsDashboard.today" {
          XCUIRemote.shared.press(.right)
        } else if from.minY < 150, to.minY > 150 {
          XCUIRemote.shared.press(.down) // Leave the tab bar without switching tabs.
        } else if from.midY > to.midY, (from.midX < to.minX || from.midX > to.maxX) {
          XCUIRemote.shared.press(from.midX < to.midX ? .right : .left)
        } else if min(from.maxY, to.maxY) > max(from.minY, to.minY) {
          XCUIRemote.shared.press(from.midX < to.midX ? .right : .left)
        } else { XCUIRemote.shared.press(from.midY < to.midY ? .down : .up) }
      }
      XCTFail("Could not focus \(element.identifier)")
    }
    @MainActor func testCompactFamilyPreviewsKeepSupportedContentInsideCards() throws {
      for (league, suffix) in [("NBA", "overtime"), ("EPL", "stoppage"), ("NFL", "overtime"), ("MLB", "extra innings"), ("Cricket", "Stumps"), ("F1", "Practice 1")] {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
        app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_LEAGUE"] = league
        app.launch()
        let card = app.buttons["sportsDashboard.game.fixture-\(league)-\(suffix)"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertLessThan(card.frame.height, 380)
        let texts = card.descendants(matching: .staticText).allElementsBoundByIndex
        for text in texts where !text.frame.isEmpty {
          XCTAssertLessThanOrEqual(text.frame.maxY, card.frame.maxY + 1, "\(league) clips \(text.label)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "compact-\(league)"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
      }
    }
    @MainActor func testRevealedLightPreviewHasBasicPointsAndExplicitAvailability() throws {
      let app = XCUIApplication()
      app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
      app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "light"
      app.launch()
      let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
      XCTAssertTrue(card.waitForExistence(timeout: 10))
      XCTAssertTrue(card.label.contains("101"), card.label)
      XCTAssertFalse(card.label.contains("Total points"), card.label)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "dashboard-revealed-light"
      shot.lifetime = .keepAlways
      add(shot)
    }
  }
#else
final class SportsDashboardUITests: XCTestCase {
  @MainActor func testTouchCardsUseAvailableWidthAndVisibleOptionsOpenSafeDetails() throws {
    let app = XCUIApplication()
    app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
    app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "hidden"
    app.launch()
    let card = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
    XCTAssertTrue(card.waitForExistence(timeout: 15))
    XCTAssertGreaterThanOrEqual(card.frame.width, 300, "Use phone/tablet space instead of the fixed 264pt card")
    XCTAssertLessThanOrEqual(card.frame.width, app.frame.width - 20)
    XCTAssertFalse(card.label.contains("101"))
    let options = app.buttons["sportsDashboard.options.fixture-AFL-basic points"]
    XCTAssertTrue(options.exists)
    options.tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["101"].exists)
    app.buttons["Done"].tap()
    XCTAssertTrue(card.waitForExistence(timeout: 5))
  }
  @MainActor func testLargeTextKeepsSameSportCardsEqualAndNamesAccessible() throws {
    let app = XCUIApplication()
    app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport-dashboard"
    app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "hidden"
    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    let first = app.buttons["sportsDashboard.game.fixture-AFL-basic points"]
    let missing = app.buttons["sportsDashboard.game.fixture-AFL-no channel"]
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertTrue(missing.exists)
    XCTAssertGreaterThan(first.frame.height, 280)
    XCTAssertEqual(first.frame.height, missing.frame.height, accuracy: 1)
    XCTAssertEqual(first.frame.width, missing.frame.width, accuracy: 1)
    XCTAssertTrue(first.label.contains("Scores hidden"))
    XCTAssertFalse(first.label.contains("101"))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "mobile-dashboard-large-text"
    shot.lifetime = .keepAlways
    add(shot)
  }

}
#endif
