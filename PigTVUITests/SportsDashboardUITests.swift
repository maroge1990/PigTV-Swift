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
#endif
