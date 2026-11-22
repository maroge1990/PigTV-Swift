import XCTest

// #351: the scheme's test plans. PigTV.xctestplan (named by Tools/test.sh and GitHub CI with -testPlan PigTV) skips
// nothing, as the scheme's test action did. XcodeCloud.xctestplan is the scheme's default, because Xcode Cloud's workflow
// Test actions offer only "Use scheme settings" (Xcode 27); it leaves out only the static source
// scans, which read the source tree that Xcode Cloud's test runner does not have (they run on the Mac and in GitHub CI),
// four timing probes that failed on its runners, and the Guide's speed suite (#362, the MacBook's perf tier only); every
// behavioural test stays in. A source scan itself, so the
// cloud plan leaves it out too. (No test plans: fails on Apple 335.)
final class TestPlanTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func skipped(_ plan: String) throws -> [String: [String]] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(plan))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(json["testTargets"] as? [[String: Any]])
        var result: [String: [String]] = [:]
        for target in targets {
            let name = try XCTUnwrap((target["target"] as? [String: Any])?["name"] as? String)
            result[name] = target["skippedTests"] as? [String] ?? []
        }
        return result
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheFullPlanRunsEverythingAndTheMacAndGitHubNameIt() throws {
        XCTAssertEqual(try skipped("PigTV.xctestplan"), ["PigTVTests": [], "PigTVUITests": []])
        let scheme = try text("PigTV.xcodeproj/xcshareddata/xcschemes/PigTV.xcscheme")
        XCTAssertTrue(scheme.contains("reference = \"container:PigTV.xctestplan\">"))
        XCTAssertTrue(scheme.contains("reference = \"container:XcodeCloud.xctestplan\"\n            default = \"YES\""),
                      "the cloud plan is the default: Xcode Cloud can only use the scheme's settings")
        XCTAssertTrue(try text("Tools/test.sh").contains("-scheme PigTV -testPlan PigTV "), "the Mac runs the full plan")
        let ci = try text(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("xcodebuild test \\\n            -project PigTV.xcodeproj \\\n            -scheme PigTV \\\n            -testPlan PigTV \\"),
                      "GitHub CI runs the full plan")
    }

    func testTheCloudPlanLeavesOutOnlySourceScansAndTheTimingProbes() throws {
        let sourceScans: Set = ["BrandRulesTests", "HelperLinesGoneTests", "LaunchImageTests", "SelectionFlatTests",
                                "SportHideScoresWriterTests", "TestPlanTests",
                                "PolishTests/testEveryLeagueColourKeepsItsWhiteLettersAtFourAndAHalfToOne()",
                                "PolishTests/testIncreasedContrastGivesTheStrongerRoles()",
                                "SportSpoilersTests/testEveryDecisionCallsTheOneFunction()",
                                "SportSpoilersTests/testNoScreenCombinesTheInputsItself()"]
        let timingProbes: Set = ["GuidePerfUITests", "OutsidePlayUITests/testAPlayLinkClosesAnOpenGuidePageAndThePlayerAppears()",
                                 "PlayerSlowStartUITests/testTheTuningCardKeepsItsIdentityWhenThePlayerIsInstalled()",
                                 "TabSwitchUITests/testSwitchingTabsOnAThousandChannelsIsQuick()",
                                 "TouchLayoutUITests/testPhoneGuideMenuOffersWatchOnForALiveEventOnSeveralChannels()"]
        let plan = try skipped("XcodeCloud.xctestplan")
        XCTAssertEqual(Set(plan["PigTVTests"] ?? []), sourceScans)
        XCTAssertEqual(Set(plan["PigTVUITests"] ?? []), timingProbes)
    }
}
