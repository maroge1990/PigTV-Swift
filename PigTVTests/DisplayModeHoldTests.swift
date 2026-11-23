import XCTest
import AVFoundation
import UIKit
@testable import PigTV

// #35 (Apple 399): a channel change keeps the previous channel's display mode while the next one tunes (no drop to the
// TV's default mode and back: two HDMI resyncs); an exit or an error clears it; an equal mode is not asked for again.
@MainActor
final class DisplayModeHoldTests: XCTestCase {
    private typealias Hold = DisplayCriteriaHold<String, Int>

    func testAChannelChangeKeepsTheModeWhileTheNextChannelTunes() {
        var hold = Hold()
        XCTAssertEqual(hold.shown("50p SDR", by: 1), .apply("50p SDR"))
        hold.handOver(from: 1, to: 2)
        XCTAssertEqual(hold.ended(1), .none, "the old channel's view leaving keeps the mode")
        XCTAssertEqual(hold.applied, "50p SDR")
        XCTAssertEqual(hold.shown(nil, by: 2), .none, "the next channel, its criteria not known yet, keeps it")
        XCTAssertEqual(hold.shown("50p SDR", by: 1), .none, "a late show from the old channel changes nothing")
        XCTAssertEqual(hold.applied, "50p SDR")
    }

    func testEqualCriteriaAreNotAppliedAgainAndDifferentOnesAre() {
        var hold = Hold()
        _ = hold.shown("50p SDR", by: 1)
        hold.handOver(from: 1, to: 2)
        XCTAssertEqual(hold.shown("50p SDR", by: 2), .none, "the same mode: no second switch")
        hold.handOver(from: 2, to: 3)
        XCTAssertEqual(hold.shown("25p HLG", by: 3), .apply("25p HLG"), "a different mode is asked for")
    }

    func testAnExitClearsTheMode() {
        var hold = Hold()
        _ = hold.shown("50p PQ", by: 1)
        XCTAssertEqual(hold.ended(1), .clear)
        XCTAssertNil(hold.applied)
        // An exit while the next channel is still tuning (no view of its own yet) clears it too.
        _ = hold.shown("50p PQ", by: 2)
        hold.handOver(from: 2, to: 3)
        XCTAssertEqual(hold.ended(3), .clear)
        XCTAssertEqual(hold.ended(3), .none, "once")
    }

    func testAnErrorWhileTuningClearsTheMode() {
        var hold = Hold()
        _ = hold.shown("50p SDR", by: 1)
        hold.handOver(from: 1, to: 2)
        hold.handOver(from: 2, to: 3) // a second change before the first tuned
        XCTAssertEqual(hold.ended(2), .none, "a channel already changed away from")
        XCTAssertEqual(hold.ended(3), .clear, "the channel tuning failed")
    }

    func testNilFromAPlayThatWasNotHandedTheModeIsTheDefaultModeAsBefore() {
        var hold = Hold()
        _ = hold.shown("50p PQ", by: 1)
        XCTAssertEqual(hold.shown(nil, by: 9), .clear, "another player (a recording) with no criteria")
        // The next channel, once it showed criteria of its own, asking for none (the stream-playlist fallback) clears.
        _ = hold.shown("50p PQ", by: 1)
        hold.handOver(from: 1, to: 2)
        XCTAssertEqual(hold.shown("50p PQ", by: 2), .none)
        XCTAssertEqual(hold.shown(nil, by: 2), .clear)
    }

    #if os(tvOS)
    private func criteria(_ fps: String, _ range: String?, video: String = "h264", width: Int = 1920) -> (AVDisplayCriteria, DisplayMode) {
        let mode = DisplayMode.make(videoMode: "copy", info: ResolveStreamInfo(fps: fps, videoRange: range, video: video,
                                                                                 width: width, height: width * 9 / 16))!
        return (mode.criteria()!, mode)
    }

    func testModesMatchOnFrameRateAndRangeOnly() {
        let a = criteria("50/1", nil), b = criteria("50", "SDR", video: "hevc", width: 1280)
        XCTAssertEqual(HeldCriteria(criteria: a.0, mode: a.1), HeldCriteria(criteria: b.0, mode: b.1))
        let c = criteria("25/1", nil), d = criteria("50/1", "PQ")
        XCTAssertNotEqual(HeldCriteria(criteria: a.0, mode: a.1), HeldCriteria(criteria: c.0, mode: c.1))
        XCTAssertNotEqual(HeldCriteria(criteria: a.0, mode: a.1), HeldCriteria(criteria: d.0, mode: d.1))
    }

    /// The player views and the app as they run: what reaches the display manager over a channel change and an exit.
    func testTheDisplayManagerSeesOneModeAcrossAChannelChangeAndTheDefaultAfterExit() async throws {
        let hold = TVDisplayModeHold.shared
        hold.resetForTesting()
        var sent: [String] = []
        let saved = hold.setCriteria
        hold.setCriteria = { _, criteria in sent.append(criteria == nil ? "default" : "mode") }
        defer { hold.setCriteria = saved; hold.resetForTesting() }

        let app = AppModel()
        app.configureClientForTesting(APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
        let one = Channel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, now: nil, next: nil)
        let two = Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil)
        app.beginPlayback(one)
        let first = try XCTUnwrap(app.playback)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let fifty = criteria("50/1", nil)
        let oldView = PlayerLayerView.LayerView()
        oldView.play = first.id
        oldView.mode = fifty.1
        oldView.criteria = fifty.0
        window.addSubview(oldView)
        XCTAssertEqual(sent, ["mode"])

        app.switchPlayback(to: two)
        let second = try XCTUnwrap(app.playback)
        oldView.removeFromSuperview() // the old channel's player view goes (PlayerHost's .id)
        _ = await first.stop()
        XCTAssertEqual(sent, ["mode"], "no drop to the default mode while the next channel tunes")

        let alsoFifty = criteria("50/1", nil, video: "hevc", width: 1280)
        let newView = PlayerLayerView.LayerView()
        newView.play = second.id
        newView.mode = alsoFifty.1
        newView.criteria = alsoFifty.0
        window.addSubview(newView)
        XCTAssertEqual(sent, ["mode"], "the same mode is not asked for again")

        await app.endPlayback(second)
        newView.removeFromSuperview()
        XCTAssertEqual(sent, ["mode", "default"], "leaving the player gives the TV its default mode, once")
    }

    func testAFailedTuneAfterAChannelChangeGivesTheTVItsDefaultMode() async throws {
        let hold = TVDisplayModeHold.shared
        hold.resetForTesting()
        var sent: [String] = []
        let saved = hold.setCriteria
        hold.setCriteria = { _, criteria in sent.append(criteria == nil ? "default" : "mode") }
        defer { hold.setCriteria = saved; hold.resetForTesting() }

        let app = AppModel()
        app.configureClientForTesting(APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
        app.beginPlayback(Channel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, now: nil, next: nil))
        let first = try XCTUnwrap(app.playback)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let view = PlayerLayerView.LayerView()
        view.play = first.id
        let mode = criteria("50/1", "HLG")
        view.mode = mode.1
        view.criteria = mode.0
        window.addSubview(view)
        app.switchPlayback(to: Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil))
        view.removeFromSuperview()
        XCTAssertEqual(sent, ["mode"])
        let second = try XCTUnwrap(app.playback)
        second.playbackFailed(detail: "Synthetic")
        XCTAssertNotNil(second.error)
        XCTAssertEqual(sent, ["mode", "default"], "the error clears the mode though no player view is up")
        _ = await first.stop()
        _ = await second.stop()
        XCTAssertEqual(sent, ["mode", "default"])
    }
    #endif
}
