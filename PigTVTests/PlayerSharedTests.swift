import XCTest
@testable import PigTV

// Build 29: the player pieces shared by tvOS and iOS (the tuning card's and
// info overlay's text, the iOS chrome's visibility, the channel list).
@MainActor
final class PlayerSharedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String, from start: TimeInterval, to end: TimeInterval) -> GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    func testInfoText() {
        let current = programme("AFL Live", from: -1800, to: 1740)
        XCTAssertEqual(PlayerInfoText.progress(current, at: now), 1800.0 / 3540, accuracy: 1e-9)
        XCTAssertEqual(PlayerInfoText.progress(current, at: now.addingTimeInterval(-4000)), 0)
        XCTAssertEqual(PlayerInfoText.progress(current, at: now.addingTimeInterval(9000)), 1)
        XCTAssertEqual(PlayerInfoText.remaining(current, at: now), "29 min left")
        XCTAssertEqual(PlayerInfoText.remaining(programme("Film", from: 0, to: 5400), at: now), "1 h 30 min left")
        XCTAssertEqual(PlayerInfoText.remaining(current, at: now.addingTimeInterval(1739.5)), "1 min left")
        XCTAssertNil(PlayerInfoText.next(nil))
        let next = programme("NRL 360", from: 1740, to: 3600)
        XCTAssertEqual(PlayerInfoText.next(next),
                       "Next: NRL 360 at \(next.start.formatted(date: .omitted, time: .shortened))")
        XCTAssertTrue(PlayerInfoText.timeRange(current).contains(" – "))
    }

    func testChromeFollowsTapsAndHidesWhenIdle() {
        // A tap on the picture toggles; on an AVKit control it keeps the chrome up.
        XCTAssertFalse(PlayerChromeTimer.afterTap(visible: true, onControl: false))
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: false, onControl: false))
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: true, onControl: true))
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: false, onControl: true))
        // Up only because the channel just started: the first tap (which
        // brings AVKit's controls up) keeps it up.
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: true, onControl: false, untouched: true))
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: false, onControl: false, untouched: true))
        let idle = now.addingTimeInterval(PlayerChromeTimer.idle)
        XCTAssertTrue(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: false, panelOpen: false))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle.addingTimeInterval(-0.5),
                                                    paused: false, panelOpen: false))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: true, panelOpen: false),
                       "AVKit keeps its controls up while paused")
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: false, panelOpen: true))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: false, lastInput: now, now: idle, paused: false, panelOpen: false))
    }

    func testPlayerChannelsFollowTheZapListElseTheGuide() throws {
        let app = AppModel()
        XCTAssertTrue(app.playerChannels.isEmpty)
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://tv.local:3000"), token: "t"))
        browse.guide = [GuideChannel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, programmes: [], number: 1),
                        GuideChannel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, programmes: [], number: 2)]
        app.configureClientForTesting(browse.client, browse: browse)
        XCTAssertEqual(app.playerChannels.map(\.name), ["A", "B"])
        app.zapList = [browse.asChannel(browse.guide[1])]
        XCTAssertEqual(app.playerChannels.map(\.name), ["B"], "the row order the guide showed when playback began")
    }
}
