import XCTest

#if os(tvOS)
// Build 31 (Mark: "switching between the five tabs is slow … it seems to get
// stuck loading the one you moved from"). On the Home fixture enlarged to
// 1,000 channels, moves along the tab bar Home → Guide → Sport →
// Recordings → Settings and back, twice, reading the app's `TabSwitchProbe` (the longest main-thread stall
// and the frame time lost in the 1.5 s after each switch). The numbers are
// printed ("TABSWITCH …") and attached; the test fails only on a clear
// regression (a stall over 1 s).
final class TabSwitchUITests: XCTestCase {
    @MainActor
    func testSwitchingTabsOnAThousandChannelsIsQuick() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launchEnvironment["PIGTV_UI_TEST_CHANNELS"] = "1000"
        app.launchEnvironment["PIGTV_UI_TEST_SPORT_EVENTS"] = "215"
        app.launchEnvironment["PIGTV_UI_TEST_TABPROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["home.watch"].waitForExistence(timeout: 15))
        let tabs = ["Home", "TV Guide", "Sport", "Recordings", "Settings"]
        var index = 0
        var times: [(String, Double)] = []
        var switches = 0
        let probe = app.staticTexts["debug.tabSwitch"]
        func press(_ button: XCUIRemote.Button) {
            let from = tabs[index]
            index += button == .right ? 1 : -1
            switches += 1
            XCUIRemote.shared.press(button)
            // The app's probe watches frames for 1.5 s after the switch.
            let done = NSPredicate(format: "label BEGINSWITH %@", "switch \(switches) ")
            _ = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: probe)], timeout: 6)
            let parts = probe.label.split(separator: " ")
            let longest = parts.count > 3 ? Double(parts[3]) ?? -1 : -1
            let lost = parts.count > 6 ? Double(parts[6]) ?? -1 : -1
            times.append(("\(from)→\(tabs[index])", longest))
            print(String(format: "TABSWITCH %@→%@ longest stall %.0f ms, lost %.0f ms", from, tabs[index], longest, lost))
        }
        for _ in 0..<2 {
            for _ in 0..<4 { press(.right) }
            for _ in 0..<4 { press(.left) }
        }
        let report = times.map { String(format: "%@ %.0f ms", $0.0, $0.1) }.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "tab-switch-times"
        attachment.lifetime = .keepAlways
        add(attachment)
        let worst = times.map(\.1).max() ?? 0
        print(String(format: "TABSWITCH worst stall %.0f ms, mean %.0f ms", worst, times.map(\.1).reduce(0, +) / Double(times.count)))
        XCTAssertLessThan(worst, 1000, report)
    }
}
#endif
