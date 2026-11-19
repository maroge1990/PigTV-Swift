import XCTest

// #351: the scheme's test plans. PigTV.xctestplan (the default: Tools/test.sh, GitHub CI, Xcode) skips nothing, as the
// scheme's test action did. XcodeCloud.xctestplan (the release workflow's Test actions) leaves out only the static source
// scans, which read the source tree that Xcode Cloud's test runner does not have (they run on the Mac and in GitHub CI),
// and three timing probes that failed on its runners; every behavioural test stays in. A source scan itself, so the
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

    func testTheDefaultPlanRunsEverything() throws {
        XCTAssertEqual(try skipped("PigTV.xctestplan"), ["PigTVTests": [], "PigTVUITests": []])
        let scheme = try String(contentsOf: Self.root.appendingPathComponent("PigTV.xcodeproj/xcshareddata/xcschemes/PigTV.xcscheme"),
                                encoding: .utf8)
        XCTAssertTrue(scheme.contains("reference = \"container:PigTV.xctestplan\"\n            default = \"YES\""), "the default plan")
        XCTAssertTrue(scheme.contains("container:XcodeCloud.xctestplan"))
    }

    func testTheCloudPlanLeavesOutOnlySourceScansAndTheTimingProbes() throws {
        let sourceScans: Set = ["BrandRulesTests", "HelperLinesGoneTests", "LaunchImageTests", "SelectionFlatTests",
                                "SportHideScoresWriterTests", "TestPlanTests",
                                "PolishTests/testEveryLeagueColourKeepsItsWhiteLettersAtFourAndAHalfToOne()",
                                "PolishTests/testIncreasedContrastGivesTheStrongerRoles()",
                                "SportSpoilersTests/testEveryDecisionCallsTheOneFunction()",
                                "SportSpoilersTests/testNoScreenCombinesTheInputsItself()"]
        let timingProbes: Set = ["OutsidePlayUITests/testAPlayLinkClosesAnOpenGuidePageAndThePlayerAppears()",
                                 "TabSwitchUITests/testSwitchingTabsOnAThousandChannelsIsQuick()",
                                 "TouchLayoutUITests/testPhoneGuideMenuOffersWatchOnForALiveEventOnSeveralChannels()"]
        let plan = try skipped("XcodeCloud.xctestplan")
        XCTAssertEqual(Set(plan["PigTVTests"] ?? []), sourceScans)
        XCTAssertEqual(Set(plan["PigTVUITests"] ?? []), timingProbes)
    }
}
