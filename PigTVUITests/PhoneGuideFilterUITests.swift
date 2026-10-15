import XCTest

#if os(iOS)
// Bug (16 Oct): on iPhone the On now list ignored a category change until another tab was visited
// and the Guide reappeared. The category observer was attached to the iPad/tvOS grid only.
// Run on an iPhone simulator (the tvOS tiers skip it): the offline guide fixture, no server.
final class PhoneGuideFilterUITests: XCTestCase {
    @MainActor
    func testChoosingACategoryRefreshesTheOnNowListAtOnce() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        let list = app.collectionViews["guide.onNow"]
        XCTAssertTrue(list.waitForExistence(timeout: 15), "On now list not shown")
        XCTAssertTrue(list.staticTexts["HBO"].waitForExistence(timeout: 5), "fixture rows not shown")

        app.buttons["All channels"].firstMatch.tap()
        app.buttons["News"].firstMatch.tap()

        XCTAssertTrue(list.staticTexts["BBC News"].waitForExistence(timeout: 5), "News row missing")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: list.staticTexts["HBO"])
        wait(for: [gone], timeout: 5)
    }
}
#endif
