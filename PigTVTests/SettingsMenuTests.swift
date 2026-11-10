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
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9.0","build":"0503","apiVersion":1,"features":{}}"#.utf8))
        XCTAssertEqual(SettingsMenu.aboutSummary(appBuild: "128", server: info), "App 128 · Server 0503")
        XCTAssertEqual(SettingsMenu.aboutSummary(appBuild: "128", server: nil), "App 128")
    }

    /// #279 (owner, 11 Nov 2026): on the Apple TV the summary follows focus and only a press opens a page. Before Apple 201
    /// moving focus down the menu opened each page in turn.
    func testFocusShowsTheSummaryAndOnlyAPressOpensThePage() {
        var detail = SettingsTVDetail(open: .sport)
        XCTAssertEqual(detail.shown(focused: nil), .summary(.sport), "nothing pressed yet: the first section's summary")
        detail.focus(.sport)
        XCTAssertEqual(detail.shown(focused: .sport), .summary(.sport))
        detail.focus(.account)
        detail.focus(.appearance)
        XCTAssertEqual(detail.open, .sport, "moving focus never selects")
        XCTAssertEqual(detail.shown(focused: .appearance), .summary(.appearance), "two rows down: that section's summary")
        detail.press(.appearance)
        XCTAssertEqual(detail.open, .appearance)
        XCTAssertEqual(detail.shown(focused: .appearance), .page(.appearance), "a press opens it")
        detail.focus(nil)
        XCTAssertEqual(detail.shown(focused: nil), .page(.appearance), "focus inside the page")
        detail.back()
        XCTAssertEqual(detail.shown(focused: .appearance), .summary(.appearance), "Menu: back to the row and its summary")
        XCTAssertEqual(detail.open, .appearance, "the row stays selected")
        detail.press(.about)
        detail.focus(.labs)
        XCTAssertEqual(detail.shown(focused: .labs), .summary(.labs), "another row: its summary; the page closes")
        XCTAssertEqual(detail.shown(focused: .about), .summary(.about))
    }

    func testInformationPagesKeepTheFocusOnTheMenu() {
        XCTAssertFalse(SettingsTVDetail.takesFocus(.diagnostics, isTab: true))
        XCTAssertFalse(SettingsTVDetail.takesFocus(.about, isTab: true))
        XCTAssertTrue(SettingsTVDetail.takesFocus(.about, isTab: false), "About's Done outside the tab")
        for page in [SettingsPage.sport, .account, .appearance, .labs] { XCTAssertTrue(SettingsTVDetail.takesFocus(page, isTab: true)) }
    }

    func testSportFactsForTheSummary() {
        let follows = SportFollows(spoilerFree: true, sports: [.init(sport: "Football", leagues: ["EPL"], teams: ["Arsenal", "Liverpool"]),
                                                              .init(sport: "Cricket", leagues: ["Tests"])])
        XCTAssertEqual(SettingsMenu.sportFacts(follows), ["Scores are hidden", "Football: Arsenal, Liverpool", "Cricket"])
        XCTAssertEqual(SettingsMenu.sportFacts(nil), ["Your sports load when the page opens"])
    }
}
