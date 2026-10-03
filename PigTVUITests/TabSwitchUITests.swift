import XCTest

#if os(tvOS)
// Build 31 (Mark: "switching between the five tabs is slow … it seems to get
// stuck loading the one you moved from"), tightened for audit R03. On the Home
// fixture enlarged to 1,000 channels and the production-sized Sport feed (215
// events), moves along the tab bar Home → Guide → Sport → Recordings →
// Settings and back, twice, reading the app's `TabSwitchProbe` (the longest
// main-thread stall and the frame time lost in the 1.5 s after each switch).
// The probe must report for every switch, both numbers must parse, and after
// each switch the remote must be able to act: Down moves focus into the tab's
// content, Up returns to the bar. The numbers are printed ("TABSWITCH …") and
// attached. Budget: PIGTV_TABSWITCH_BUDGET_MS from the test environment, else
// 500 ms (simulators on CI are noisy; the Apple TV target is 250 ms, checked
// by hand with PIGTV_TABSWITCH_BUDGET_MS=250 and Instruments, see TESTING.md).
final class TabSwitchUITests: XCTestCase {
    private static let defaultBudgetMs = 500.0

    @MainActor
    func testSwitchingTabsOnAThousandChannelsIsQuick() throws {
        let budget = ProcessInfo.processInfo.environment["PIGTV_TABSWITCH_BUDGET_MS"].flatMap(Double.init) ?? Self.defaultBudgetMs
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
        var lines: [String] = []
        var switches = 0
        let probe = app.staticTexts["debug.tabSwitch"]
        let tabBar = app.tabBars.firstMatch

        /// The first focused element, if any.
        func focused() -> XCUIElement? {
            let match = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            return match.exists ? match : nil
        }

        /// Down must land focus on something below the tab bar.
        func proveRemoteActs(in tab: String) {
            XCUIRemote.shared.press(.down)
            let below = NSPredicate { _, _ in
                guard let element = focused() else { return false }
                return element.frame.minY >= tabBar.frame.maxY - 1
            }
            let result = XCTWaiter.wait(for: [expectation(for: below, evaluatedWith: nil)], timeout: 5)
            XCTAssertEqual(result, .completed, "After switching to \(tab) the remote could not act: Down did not move focus below the tab bar (focused: \(focused()?.debugDescription ?? "nothing")).")
            // Back to the bar for the next switch.
            for _ in 0..<4 {
                XCUIRemote.shared.press(.up)
                if let element = focused(), element.frame.maxY <= tabBar.frame.maxY + 1 { break }
            }
        }

        func press(_ button: XCUIRemote.Button) {
            let from = tabs[index]
            index += button == .right ? 1 : -1
            let to = tabs[index]
            switches += 1
            XCUIRemote.shared.press(button)
            // The app's probe watches frames for 1.5 s after the switch.
            let done = NSPredicate(format: "label BEGINSWITH %@", "switch \(switches) ")
            let waited = XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: probe)], timeout: 45)
            XCTAssertEqual(waited, .completed, "The tab probe never reported switch \(switches) (\(from)→\(to)); its label is \"\(probe.label)\".")
            let parts = probe.label.split(separator: " ")
            let longest = parts.count > 3 ? Double(parts[3]) : nil
            let lost = parts.count > 6 ? Double(parts[6]) : nil
            XCTAssertNotNil(longest, "Could not read the longest stall from the probe label \"\(probe.label)\" (\(from)→\(to)).")
            XCTAssertNotNil(lost, "Could not read the lost time from the probe label \"\(probe.label)\" (\(from)→\(to)).")
            let stall = longest ?? .infinity
            XCTAssertGreaterThanOrEqual(stall, 0)
            times.append(("\(from)→\(to)", stall))
            let line = String(format: "TABSWITCH %@→%@ longest stall %.0f ms, lost %.0f ms", from, to, stall, lost ?? .nan)
            lines.append(line)
            print(line)
            // After the measurement window, so it cannot disturb it.
            proveRemoteActs(in: to)
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
        XCTAssertEqual(times.count, 16, "Expected 16 measured switches.")
        // Known outlier, tracked (blueprint, build 37 "Next"): the FIRST visit to the TV
        // Guide builds its 1,000-row UIKit grid and stalled 0.36-0.6 s on CI runners. It
        // keeps the old 1 s limit until that work lands; every other switch, Sport's
        // included, is held to the budget. Remove this once the Guide is fixed.
        let firstGuideVisit = "Home→TV Guide"
        let firstGuideAllowance = max(budget, 1000)
        let firstGuide = times.first { $0.0 == firstGuideVisit }
        let others = times.enumerated().filter { $0.offset != times.firstIndex { $0.0 == firstGuideVisit } }.map(\.element)
        let worst = others.map(\.1).max() ?? 0
        print(String(format: "TABSWITCH worst stall %.0f ms (first Guide visit %.0f ms, allowed %.0f), mean %.0f ms, budget %.0f ms",
                     worst, firstGuide?.1 ?? 0, firstGuideAllowance, times.map(\.1).reduce(0, +) / Double(max(times.count, 1)), budget))
        XCTAssertLessThan(worst, budget, "Worst tab-switch stall \(Int(worst)) ms is over the \(Int(budget)) ms budget.\n" + report)
        if let firstGuide {
            XCTAssertLessThan(firstGuide.1, firstGuideAllowance, "The first Guide visit stalled \(Int(firstGuide.1)) ms.\n" + report)
        }
    }
}
#endif
