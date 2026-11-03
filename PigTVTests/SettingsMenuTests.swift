import XCTest
@testable import PigTV

/// D-44 batch 6 (Apple 128): what the Settings menu lists beside its page, and the summary under each item.
final class SettingsMenuTests: XCTestCase {
    func testTheMenuOrderSportOnlyWithFollowsAndDiagnosticsOnlyOnTheTV() {
        XCTAssertEqual(SettingsMenu.pages(sportFollows: true, isTV: true), [.sport, .account, .appearance, .labs, .diagnostics, .about])
        XCTAssertEqual(SettingsMenu.pages(sportFollows: true, isTV: false), [.sport, .account, .appearance, .labs, .about],
                       "no Diagnostics on the iPad or iPhone")
        XCTAssertEqual(SettingsMenu.pages(sportFollows: false, isTV: true), [.account, .appearance, .labs, .diagnostics, .about],
                       "an older server keeps no sports for the account")
    }

    func testTheSplitViewOpensOnTheFirstPageAndThePhoneOnTheMenu() {
        let pages = SettingsMenu.pages(sportFollows: true, isTV: false)
        XCTAssertEqual(SettingsMenu.opening(pages, compact: false), .sport)
        XCTAssertNil(SettingsMenu.opening(pages, compact: true))
    }

    func testSummaries() throws {
        let follows = SportFollows(spoilerFree: false, sports: [
            .init(sport: "Football", leagues: ["Premier League"], teams: ["Liverpool", "Arsenal"]),
            .init(sport: "Cricket", leagues: ["Cricket"], teams: ["Australia"]),
        ])
        XCTAssertEqual(SettingsMenu.sportSummary(follows), "2 sports · 3 follows")
        XCTAssertEqual(SettingsMenu.sportSummary(SportFollows(spoilerFree: true, sports: [.init(sport: "Golf", leagues: ["PGA"])])),
                       "1 sport · 0 follows")
        XCTAssertEqual(SettingsMenu.sportSummary(nil), "Hide scores and your sports")
        XCTAssertEqual(SettingsMenu.accountSummary(user: "mark", server: "http://pigtv.local:3000"), "mark · pigtv.local")
        XCTAssertEqual(SettingsMenu.accountSummary(user: nil, server: "http://pigtv.local:3000"), "pigtv.local")
        XCTAssertEqual(SettingsMenu.appearanceSummary("dark"), "Dark")
        let one = [Labs.Toggle(key: "a", title: "Stream info overlay", detail: "")]
        XCTAssertEqual(SettingsMenu.labsSummary(one) { _ in true }, "Stream info overlay: On")
        XCTAssertEqual(SettingsMenu.labsSummary(one) { _ in false }, "Stream info overlay: Off")
        let two = one + [Labs.Toggle(key: "b", title: "Other", detail: "")]
        XCTAssertEqual(SettingsMenu.labsSummary(two) { $0 == "b" }, "1 on")
        XCTAssertEqual(SettingsMenu.labsSummary(two) { _ in false }, "All off")
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9.0","build":"0444","apiVersion":1,"features":{}}"#.utf8))
        XCTAssertEqual(SettingsMenu.aboutSummary(appBuild: "128", server: info), "App 128 · Server 0444")
        XCTAssertEqual(SettingsMenu.aboutSummary(appBuild: "128", server: nil), "App 128")
    }
}
