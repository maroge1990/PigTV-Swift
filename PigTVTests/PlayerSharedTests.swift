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
        // Build 31: PigTV's controls are the only ones; a tap on the picture toggles them.
        XCTAssertFalse(PlayerChromeTimer.afterTap(visible: true))
        XCTAssertTrue(PlayerChromeTimer.afterTap(visible: false))
        let idle = now.addingTimeInterval(PlayerChromeTimer.idle)
        XCTAssertTrue(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: false, panelOpen: false))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle.addingTimeInterval(-0.5),
                                                    paused: false, panelOpen: false))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: true, panelOpen: false),
                       "the controls stay up while paused")
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: idle, paused: false, panelOpen: true))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: false, lastInput: now, now: idle, paused: false, panelOpen: false))
    }

    func testSeekWindowMapsPositionsFractionsAndReadouts() throws {
        XCTAssertNil(PlayerSeekWindow(start: 0, end: 4, current: 2), "under 5 s is not scrubbable")
        XCTAssertNil(PlayerSeekWindow(start: 0, end: .infinity, current: 2))
        // A 3-hour timeshift window, the picture 30 min behind live.
        let window = try XCTUnwrap(PlayerSeekWindow(start: 100, end: 10_900, current: 9_100))
        XCTAssertEqual(window.fraction, 9_000.0 / 10_800, accuracy: 1e-9)
        XCTAssertEqual(window.time(at: 0.5), 5_500)
        XCTAssertEqual(window.time(at: -1), 100, "clamped to the start")
        XCTAssertEqual(window.time(at: 2), 10_900, "clamped to the live edge")
        XCTAssertEqual(window.behindLive(at: window.fraction), 1_800, accuracy: 1e-6)
        XCTAssertEqual(window.readout(at: window.fraction), "30:00 behind live")
        XCTAssertEqual(window.readout(at: 0), "3 h 00 min behind live")
        XCTAssertTrue(window.isLive(at: 1))
        XCTAssertTrue(window.isLive(at: (10_800 - 15) / 10_800.0), "within 20 s reads as live")
        XCTAssertEqual(window.readout(at: 1), "LIVE")
        XCTAssertEqual(window.skipTarget(15), 9_115)
        XCTAssertEqual(window.skipTarget(5_000), 10_900)
        XCTAssertEqual(window.skipTarget(-20_000), 100)
        // Finger position on the track.
        XCTAssertEqual(PlayerSeekWindow.fraction(forX: 150, width: 600), 0.25)
        XCTAssertEqual(PlayerSeekWindow.fraction(forX: -30, width: 600), 0)
        XCTAssertEqual(PlayerSeekWindow.fraction(forX: 700, width: 600), 1)
        XCTAssertEqual(PlayerSeekWindow.fraction(forX: 10, width: 0), 0)
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
