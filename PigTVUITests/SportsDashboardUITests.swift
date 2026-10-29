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
      for _ in 0..<8 {
        let focused = app.descendants(matching: .any).element(
          matching: NSPredicate(format: "hasFocus == true"))
        if focused.identifier == card.identifier { break }
        XCUIRemote.shared.press(.down)
      }
      XCUIRemote.shared.press(.select, forDuration: 1.5)
      XCTAssertTrue(
        app.descendants(matching: .any)["Event details, channels & recording"].waitForExistence(
          timeout: 5))
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
