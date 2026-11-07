import XCTest

#if os(iOS)
// T3 against the Unraid staging server (fake providers, ESPN's real F1 feed): signs in, opens Sport → Motorsport (the
// F1 weekend) and attaches screenshots in landscape and portrait. Skipped unless the test runner is given
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
        // #243 (Apple 168): the F1 weekend is the Motorsport page's content (D-43/D-44); spoiler-free lives in Settings.
        let motorsport = app.buttons["sport.rail.header.Motorsport"]
        XCTAssertTrue(motorsport.waitForExistence(timeout: 20), "no Motorsport rail: is F1 followed and sportFront on?")
        motorsport.tap()
        XCTAssertTrue(app.descendants(matching: .any)["f1.page"].waitForExistence(timeout: 30), "the F1 weekend did not load")
        sleep(3) // the circuit map
        attach(app, "staging-f1-ipad-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        attach(app, "staging-f1-ipad-portrait")
    }
}
#endif
