import XCTest

#if os(iOS)
// T3 against the Unraid staging server (fake providers, ESPN's real F1 feed): signs in, opens Sport → Formula 1 and
// attaches screenshots, then flips the household spoiler switch and back. Skipped unless the test runner is given
// the staging address and its throwaway login (TEST_RUNNER_PIGTV_STAGING_URL, …_USER, …_PASS); never a real server.
final class StagingF1UITests: XCTestCase {
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testTheF1PageOnStaging() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["PIGTV_STAGING_URL"], let user = env["PIGTV_STAGING_USER"], let pass = env["PIGTV_STAGING_PASS"] else {
            throw XCTSkip("no staging server given")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        let server = app.textFields["http://pigtv.local:3000"]
        if server.waitForExistence(timeout: 10) {
            server.tap()
            server.typeText(url)
            let name = app.textFields["Username"]
            name.tap()
            name.typeText(user)
            let password = app.secureTextFields["Password"]
            password.tap()
            password.typeText(pass)
            app.buttons["Sign in"].tap()
        }
        let sport = app.buttons["Sport"].firstMatch
        XCTAssertTrue(sport.waitForExistence(timeout: 30), "not signed in")
        sport.tap()
        let f1 = app.buttons["sport.page.f1"]
        XCTAssertTrue(f1.waitForExistence(timeout: 20), "no Formula 1 entry: is sportPages on?")
        f1.tap()
        XCTAssertTrue(app.staticTexts["f1.weekend"].waitForExistence(timeout: 30), "the F1 page did not load")
        sleep(3) // the circuit map
        attach(app, "staging-f1-ipad-landscape")
        let spoilers = app.buttons["f1.spoilers"]
        spoilers.tap()
        XCTAssertTrue(app.staticTexts["Results hidden"].waitForExistence(timeout: 10))
        attach(app, "staging-f1-ipad-spoiler-free")
        spoilers.tap()
        XCTAssertTrue(app.staticTexts["Results hidden"].waitForNonExistence(timeout: 10), "the switch did not come back")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        attach(app, "staging-f1-ipad-portrait")
    }
}
#endif
