import ImageIO
import XCTest
@testable import PigTV

// #362 (speed programme, batch 1): the Guide's measurement. The probe's arithmetic (frame gaps, median, percentile,
// reset), the probe being absent when its variable is not set, and the production-shaped fixture: 1,250 channels, a
// day of programmes each, descriptions of 150-300 characters, a logo each, 40 categories, the same programmes whatever
// window is asked for, and the app's own paging fetching all of it in three pages. The older fixtures stay as they were.
@MainActor
final class GuidePerfTests: XCTestCase {
    // MARK: The probe's arithmetic

    func testFrameGapsCountOverFiftyAndOverAHundredAndKeepTheLongest() {
        var stats = GuidePerfStats()
        stats.frame(gapMs: nil) // the first frame after a reset has no gap
        stats.frame(gapMs: 16.7)
        stats.frame(gapMs: 50) // not over 50
        stats.frame(gapMs: 60)
        stats.frame(gapMs: 100) // not over 100
        stats.frame(gapMs: 250)
        XCTAssertEqual(stats.frames, 6)
        XCTAssertEqual(stats.gapsOver50, 3)
        XCTAssertEqual(stats.gapsOver100, 1)
        XCTAssertEqual(stats.maxGapMs, 250)
    }

    func testMedianAndPercentile() {
        XCTAssertNil(GuidePerfStats.median([]))
        XCTAssertEqual(GuidePerfStats.median([5, 1, 3]), 3)
        XCTAssertEqual(GuidePerfStats.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(GuidePerfStats.percentile([], 95))
        let twenty = (1...20).map(Double.init)
        XCTAssertEqual(GuidePerfStats.percentile(twenty, 95), 19, "nearest rank: the 19th of 20")
        XCTAssertEqual(GuidePerfStats.percentile(twenty, 100), 20)
        XCTAssertEqual(GuidePerfStats.percentile([7], 50), 7)
    }

    func testAResetZeroesEverythingButCountsItselfAndCarriesTheRows() {
        var stats = GuidePerfStats()
        stats.landed(focusMs: 12, pressMs: 30)
        stats.frame(gapMs: 120)
        stats.bodyEvaluations = 9
        stats.firstScreenMs = 800
        stats.rowsEnd = 500
        stats.reset()
        stats.reset()
        XCTAssertEqual(stats, GuidePerfStats(resets: 2, rowsStart: 500, rowsEnd: 500))
    }

    func testAMoveFeelsLikeItsPressWhereThePressTimeIsKnown() {
        var stats = GuidePerfStats()
        stats.landed(focusMs: 20, pressMs: 45)
        stats.landed(focusMs: 30, pressMs: nil)
        XCTAssertEqual(stats.moves, 2)
        XCTAssertEqual(stats.focusMs, [20, 30])
        XCTAssertEqual(stats.pressMs, [45])
        XCTAssertEqual(stats.feltMs, [45, 30])
    }

    func testSamplesAreCappedButMovesAreCounted() {
        var stats = GuidePerfStats()
        for i in 0..<(GuidePerfStats.sampleCap + 5) { stats.landed(focusMs: Double(i), pressMs: nil) }
        XCTAssertEqual(stats.moves, GuidePerfStats.sampleCap + 5)
        XCTAssertEqual(stats.focusMs.count, GuidePerfStats.sampleCap)
        XCTAssertEqual(stats.focusMs.first, 5, "the oldest go first")
    }

    func testTheReadoutSaysItInPlainWords() {
        var stats = GuidePerfStats()
        XCTAssertEqual(stats.readout(build: "373"), "No moves in the TV Guide yet · Apple 373")
        for (focus, press) in [(60.0, 80.0), (70, 90.4), (300, nil as Double?)] { stats.landed(focusMs: focus, pressMs: press) }
        stats.frame(gapMs: nil)
        stats.frame(gapMs: 412)
        stats.frame(gapMs: 16)
        stats.firstScreenMs = 900.2
        XCTAssertEqual(stats.readout(build: "373"),
                       "3 moves · typical 90 ms · slowest 300 ms · 1 slow frame (over 100 ms) · longest stall 412 ms · first screen 900 ms · Apple 373")
        stats.landed(focusMs: 10, pressMs: nil)
        stats.frame(gapMs: 101)
        XCTAssertTrue(stats.readout(build: "373").hasPrefix("4 moves · typical 85 ms · slowest 300 ms · 2 slow frames (over 100 ms)"))
    }

    func testTheJSONCarriesTheFiguresAndTheSummaries() throws {
        var stats = GuidePerfStats()
        for (focus, press) in [(10.0, nil as Double?), (30, nil), (20, nil), (200, 40)] { stats.landed(focusMs: focus, pressMs: press) }
        stats.frame(gapMs: nil)
        stats.frame(gapMs: 120.04)
        stats.cellConfigurations = 14
        stats.layoutPrepares = 3
        stats.logoFetches = 5
        stats.logoSyncHits = 7
        stats.applies = 2
        stats.applyMs = 33.333
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stats.json(windowMs: 1000).utf8)) as? [String: Any])
        XCTAssertEqual(json["focusMoves"] as? Int, 4)
        XCTAssertEqual(json["focusMedianMs"] as? Double, 25)
        XCTAssertEqual(json["focusMaxMs"] as? Double, 200)
        XCTAssertEqual(json["focusP95Ms"] as? Double, 200)
        XCTAssertEqual(json["pressMaxMs"] as? Double, 40)
        XCTAssertEqual(json["maxGapMs"] as? Double, 120)
        XCTAssertEqual(json["gapsOver100"] as? Int, 1)
        XCTAssertEqual(json["cellConfigs"] as? Int, 14)
        XCTAssertEqual(json["layoutPrepares"] as? Int, 3)
        XCTAssertEqual(json["logoFetches"] as? Int, 5)
        XCTAssertEqual(json["logoSyncHits"] as? Int, 7)
        XCTAssertEqual(json["logoCancels"] as? Int, 0)
        XCTAssertEqual(json["logoLateHits"] as? Int, 0)
        XCTAssertEqual(json["applyMs"] as? Double, 33.3)
        XCTAssertNil(json["firstScreenMs"], "absent until the first screen has been drawn")
    }

    /// Zero cost when off: without the Settings switch or PIGTV_UI_TEST_GUIDEPROBE the probe does not exist (no display
    /// link, no observer), so every hook stops at one nil check.
    func testTheProbeIsOffByDefault() {
        XCTAssertNil(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_GUIDEPROBE"])
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: "GuidePerfTests-\(UUID().uuidString)"))
        XCTAssertFalse(GuidePerfProbe.initiallyOn(defaults: defaults))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: GuidePerfProbe.defaultsKey), "the test host has the switch off")
        XCTAssertNil(GuidePerfProbe.shared)
        GuidePerf.bodyEvaluated() // a hook with the probe off: nothing to record into, nothing created
        XCTAssertNil(GuidePerfProbe.shared)
    }

    /// The switch: on creates the probe and keeps the choice; off stops its display link and drops it.
    func testTheSwitchCreatesTheProbeAndOffDestroysIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GuidePerfTests-\(UUID().uuidString)"))
        defer { GuidePerfProbe.setEnabled(false, defaults: defaults) }
        GuidePerfProbe.setEnabled(true, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: GuidePerfProbe.defaultsKey))
        XCTAssertTrue(GuidePerfProbe.initiallyOn(defaults: defaults), "on again at the next launch")
        let probe = try XCTUnwrap(GuidePerfProbe.shared)
        XCTAssertTrue(probe.hasDisplayLink)
        XCTAssertFalse(probe.monitoringFrames, "no frames counted until the Guide is on screen")
        GuidePerfProbe.setEnabled(false, defaults: defaults)
        XCTAssertNil(GuidePerfProbe.shared)
        XCTAssertFalse(probe.hasDisplayLink, "the display link is stopped")
        XCTAssertFalse(defaults.bool(forKey: GuidePerfProbe.defaultsKey))
    }

    /// Nothing is recorded while the Guide is not on screen; a reset zeroes what was.
    func testNothingIsRecordedWhileTheGuideIsNotVisible() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GuidePerfTests-\(UUID().uuidString)"))
        defer { GuidePerfProbe.setEnabled(false, defaults: defaults) }
        GuidePerfProbe.setEnabled(true, defaults: defaults)
        let probe = try XCTUnwrap(GuidePerfProbe.shared)
        func hooks() {
            GuidePerf.bodyEvaluated()
            GuidePerf.cellEnded(GuidePerf.cellBegan())
            GuidePerf.applyEnded(GuidePerf.applyBegan(), rows: 12, kind: "reload")
            probe.focusLanded(ms: 20)
        }
        hooks()
        XCTAssertEqual(probe.stats.bodyEvaluations + probe.stats.cellConfigurations + probe.stats.applies + probe.stats.moves, 0)
        GuidePerf.guideVisible(true)
        // The Guide's visible work restarting: the new run starts before the old run's end arrives.
        GuidePerf.guideVisible(true)
        GuidePerf.guideVisible(false)
        XCTAssertTrue(probe.guideVisible, "a late end of an old run does not hide the Guide")
        hooks()
        XCTAssertEqual(probe.stats.bodyEvaluations, 1)
        XCTAssertEqual(probe.stats.cellConfigurations, 1)
        XCTAssertEqual(probe.stats.applies, 1)
        XCTAssertEqual(probe.stats.moves, 1)
        XCTAssertEqual(probe.stats.rowsEnd, 12)
        GuidePerf.guideVisible(false)
        hooks()
        XCTAssertEqual(probe.stats.moves, 1)
        probe.reset()
        XCTAssertEqual(probe.stats.moves, 0)
        XCTAssertEqual(probe.stats.resets, 1)
    }

    // MARK: Review findings (#362): what the probe pairs and records

    /// A press the tests can make: UIKit gives no public way to build one.
    private final class FakePress: UIPress {
        private let fakeType: UIPress.PressType
        private let fakeTime: TimeInterval
        init(_ type: UIPress.PressType, at time: TimeInterval) {
            fakeType = type
            fakeTime = time
            super.init()
        }
        override var type: UIPress.PressType { fakeType }
        override var timestamp: TimeInterval { fakeTime }
    }

    /// The probe on, the Guide on screen, and the measurement's own state as at launch.
    private func probeOnScreen(_ defaults: UserDefaults, fromLaunch: Bool = true) throws -> GuidePerfProbe {
        if fromLaunch { GuidePerf.resetForTests() }
        for _ in 0..<8 { GuidePerf.guideVisible(false) }
        GuidePerfProbe.setEnabled(true, defaults: defaults)
        GuidePerf.guideVisible(true)
        return try XCTUnwrap(GuidePerfProbe.shared)
    }

    private func tidy(_ defaults: UserDefaults) {
        GuidePerfProbe.setEnabled(false, defaults: defaults)
        for _ in 0..<8 { GuidePerf.guideVisible(false) }
    }

    private func newDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "GuidePerfTests-\(UUID().uuidString)"))
    }

    /// Finding 1: only an arrow press is a move's press; select (or menu, play/pause) reaching the grid is not kept.
    func testOnlyAnArrowPressIsPairedWithAMove() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        let grid = GuideGridCollectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                           collectionViewLayout: UICollectionViewFlowLayout())
        grid.pressesBegan([FakePress(.select, at: CACurrentMediaTime() - 0.05)], with: nil)
        GuidePerf.focusMoved()
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs, [], "a select press is not the press that moved focus")
        XCTAssertEqual(probe.stats.feltMs, [20])
        grid.pressesBegan([FakePress(.downArrow, at: CACurrentMediaTime() - 0.05)], with: nil)
        GuidePerf.focusMoved()
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs.count, 1, "an arrow press is")
    }

    /// Finding 1: a press seconds old (a swipe moved focus since, with no press) is never paired with a later move.
    func testAStalePressIsNeverPairedWithALaterMove() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        probe.pressBegan(CACurrentMediaTime() - 5)
        GuidePerf.focusMoved()
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs, [], "a press 5 s before the move is not its press")
        XCTAssertEqual(probe.stats.feltMs, [20])
    }

    /// Finding 4: an empty Guide that leaves the screen ends its first-screen measurement; a later fill records none.
    func testAFirstScreenThatLeftTheScreenEmptyIsAbandoned() async throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        GuidePerf.screenAppeared(rowsShown: false)
        GuidePerf.guideVisible(false)
        GuidePerf.guideVisible(true)
        GuidePerf.rowsOnScreen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(probe.stats.firstScreenMs, "the Guide left the screen before it had rows")
    }

    /// Finding 4: switching the readout on after launch and going back to the Guide is a tab return, not a first screen.
    func testATabReturnAfterSwitchingOnIsNotAFirstScreen() async throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        GuidePerf.resetForTests()
        GuidePerf.guideVisible(true) // launch: the Guide appears with the readout off
        GuidePerf.screenAppeared(rowsShown: false)
        GuidePerf.rowsOnScreen()
        try await Task.sleep(for: .milliseconds(300))
        GuidePerf.guideVisible(false)
        let probe = try probeOnScreen(defaults, fromLaunch: false) // switched on in Settings, then back to the Guide
        GuidePerf.screenAppeared(rowsShown: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(probe.stats.firstScreenMs, "a return to the tab is not the Guide's first screen")
    }

    /// Finding 1: a move takes a press from under a second before it; an older one, or one already taken, it does not.
    func testAMoveTakesOnlyAFreshPressAndOnlyOnce() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        let now = CACurrentMediaTime()
        probe.pressBegan(now - 1.2)
        probe.focusBegan(at: now)
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs, [], "1.2 s is past the \(GuidePerfProbe.pressFreshness) s window")
        probe.pressBegan(now - 0.05)
        probe.focusBegan(at: now)
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs.count, 1)
        probe.focusBegan(at: now) // a swipe: no press of its own
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs.count, 1, "the press went with the move before")
        XCTAssertFalse(GuidePerfProbe.movesFocus(.select))
        XCTAssertFalse(GuidePerfProbe.movesFocus(.menu))
        XCTAssertFalse(GuidePerfProbe.movesFocus(.playPause))
        XCTAssertTrue([UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow].allSatisfy(GuidePerfProbe.movesFocus))
    }

    /// The focus engine moves focus while UIKit dispatches an arrow press down (its window-level arrow recognizer), and
    /// only then does the press reach the grid's pressesBegan (measured on the simulator: focus updated about 13 ms after
    /// the press's own time, the grid's pressesBegan about 23 ms later, in the same dispatch). Each move is timed from its
    /// own press, never from the press before it: before this, every move took the previous press, so press-to-frame was
    /// the gap between presses plus the move (about 340 ms at three presses a second) and a move after a pause took none.
    func testAMoveIsTimedFromThePressBeingDispatchedWhenItBegan() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        let now = CACurrentMediaTime()
        for press in [now - 0.6, now] { // two presses 600 ms apart, as UIKit delivers each
            probe.focusBegan(at: press + 0.013)
            probe.pressBegan(press, at: press + 0.036)
            probe.pressEnded(press + 0.005)
            probe.focusLanded(ms: 37, at: press + 0.05)
        }
        XCTAssertEqual(probe.stats.pressMs.count, 2, "each move has its own press")
        for value in probe.stats.pressMs { XCTAssertEqual(value, 50, accuracy: 0.5, "press to frame, not the gap between presses") }
        XCTAssertEqual(probe.stats.moveAfterDownMs.count, 2)
        for value in probe.stats.moveAfterDownMs { XCTAssertEqual(value, 13, accuracy: 0.5) }
        XCTAssertEqual(probe.stats.movesWhileDown, 2)
        XCTAssertEqual(probe.stats.pressHeldMs.count, 2)
        // A move the press did not make (a swipe, a redirect after a veto) still takes no press, and a press that arrives
        // while an older move is open is kept for the move it makes next.
        probe.focusBegan(at: now + 1)
        probe.focusLanded(ms: 20, at: now + 1.05)
        XCTAssertEqual(probe.stats.pressMs.count, 2)
        probe.focusBegan(at: now + 2)
        probe.pressBegan(now + 2.01, at: now + 2.02)
        probe.focusLanded(ms: 20, at: now + 2.05)
        XCTAssertEqual(probe.stats.pressMs.count, 2, "a press after the move began is not that move's")
        probe.focusBegan(at: now + 2.06)
        probe.focusLanded(ms: 20, at: now + 2.1)
        XCTAssertEqual(probe.stats.pressMs.last ?? 0, 90, accuracy: 0.5, "it goes with the move it made")
    }

    /// A busy main thread delays the press's dispatch, and the move it makes, well past the press's own (hardware) time:
    /// that move is still the press's, timed from the press, and the next pair is unaffected. A press that moved nothing,
    /// reaching the grid long after another move (a swipe's) began, is not that move's.
    func testAMoveDelayedByABusyMainThreadIsStillTimedFromItsPress() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        let now = CACurrentMediaTime()
        let late = now - 1
        probe.focusBegan(at: late + 0.6) // dispatched 600 ms after the press
        probe.pressBegan(late, at: late + 0.62)
        probe.pressEnded(late + 0.005)
        probe.focusLanded(ms: 40, at: late + 0.64)
        XCTAssertEqual(probe.stats.pressMs.count, 1)
        XCTAssertEqual(probe.stats.pressMs.first ?? 0, 640, accuracy: 0.5, "600 ms of delay plus the move's frame")
        XCTAssertEqual(probe.stats.moveAfterDownMs.first ?? 0, 600, accuracy: 0.5)
        probe.focusBegan(at: now + 0.013)
        probe.pressBegan(now, at: now + 0.036)
        probe.focusLanded(ms: 37, at: now + 0.05)
        XCTAssertEqual(probe.stats.pressMs.count, 2)
        XCTAssertEqual(probe.stats.pressMs.last ?? 0, 50, accuracy: 0.5, "the next pair is its own")
        probe.focusBegan(at: now + 1) // a swipe's move, still open
        probe.pressBegan(now + 1.2, at: now + 1.5) // a press after it began: not its press
        probe.pressBegan(now + 0.9, at: now + 1.4) // before it began, but not in its dispatch
        probe.focusLanded(ms: 20, at: now + 1.6)
        XCTAssertEqual(probe.stats.pressMs.count, 2, "no press paired with the swipe's move")
    }

    /// Finding 2: with the readout off and nothing recording, the apply and cell hooks make nothing (nil), and their ends
    /// take that nil. Whether Instruments-style recording is on in the test host is the signposter's to say.
    func testHooksMakeNothingWhileNobodyIsWatching() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        XCTAssertNil(GuidePerfProbe.shared)
        XCTAssertEqual(GuidePerf.applyBegan() == nil, !GuidePerf.isWatching)
        XCTAssertEqual(GuidePerf.cellBegan() == nil, !GuidePerf.isWatching)
        GuidePerf.applyEnded(nil, rows: 3, kind: "reload")
        GuidePerf.cellEnded(nil)
        let probe = try probeOnScreen(defaults)
        XCTAssertTrue(GuidePerf.isWatching)
        let apply = GuidePerf.applyBegan()
        let cell = GuidePerf.cellBegan()
        XCTAssertNotNil(apply)
        XCTAssertNotNil(cell)
        GuidePerf.applyEnded(apply, rows: 3, kind: "reload")
        GuidePerf.cellEnded(cell)
        XCTAssertEqual(probe.stats.applies, 1)
        XCTAssertEqual(probe.stats.cellConfigurations, 1)
    }

    /// Finding 3: focus leaving the grid drops the open move; the next move into the grid supersedes nothing and takes
    /// no press from before.
    func testFocusLeavingTheGridDropsTheOpenMove() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        probe.pressBegan(CACurrentMediaTime() - 0.05)
        GuidePerf.focusMoved()
        GuidePerf.focusLeftGrid() // to the filter bar before the move's frame
        GuidePerf.focusMoved() // back into the grid
        XCTAssertEqual(probe.stats.focusSuperseded, 0, "the time away is not a superseded move")
        probe.focusLanded(ms: 20)
        XCTAssertEqual(probe.stats.pressMs, [])
        GuidePerf.focusMoved()
        XCTAssertEqual(probe.stats.focusSuperseded, 1, "a move overtaken inside the grid still counts")
    }

    /// Finding 4: the launch's first screen is recorded when the probe was already on; one not drawn within 30 s is not.
    func testTheLaunchFirstScreenIsRecordedButNotOnePastThirtySeconds() async throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        GuidePerf.screenAppeared(rowsShown: false, now: CACurrentMediaTime() - GuidePerf.firstScreenLimit - 1)
        GuidePerf.rowsOnScreen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(probe.stats.firstScreenMs, "an empty Guide filled after 31 s is not a first screen")
        GuidePerf.resetForTests()
        GuidePerf.screenAppeared(rowsShown: false)
        GuidePerf.rowsOnScreen()
        try await Task.sleep(for: .milliseconds(300))
        let ms = try XCTUnwrap(probe.stats.firstScreenMs, "the launch's first screen, the probe on")
        XCTAssertLessThan(ms, 5000)
    }

    // MARK: Review of 373: a measurement ends one frame after the Guide's work

    /// Frame callbacks the test makes itself, each with the time it says its frame is due.
    @MainActor private final class ManualFrames: GuideFrames {
        private var frame: (@MainActor (CFTimeInterval) -> Void)?
        var running: Bool { frame != nil }
        func start(_ frame: @escaping @MainActor (CFTimeInterval) -> Void) { self.frame = frame }
        func stop() { frame = nil }
        func tick(due: CFTimeInterval = CACurrentMediaTime() + 1.0 / 60) { frame?(due) }
    }

    /// High: the first frame callback after a focus change only opens the chance to draw; the layout and drawing of the
    /// change come after it on the main thread. A stall there (here 200 ms between the first and second callbacks) is in
    /// the figure, which ends at the second callback's due time.
    func testAFocusMoveEndsAtTheFrameAfterItsWorkSoAStallBeforeThatFrameCounts() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults); GuidePerf.resetForTests() }
        let probe = try probeOnScreen(defaults)
        let frames = ManualFrames()
        GuidePerf.makeFrames = { frames }
        probe.pressBegan(CACurrentMediaTime())
        GuidePerf.focusMoved()
        GuidePerf.focusHandled()
        frames.tick() // the first callback after the work
        XCTAssertEqual(probe.stats.moves, 0, "not landed at the first callback after the work: its frame is not drawn yet")
        Thread.sleep(forTimeInterval: 0.2) // layout and drawing of the change stall the main thread
        let due = CACurrentMediaTime() + 1.0 / 60
        frames.tick(due: due)
        XCTAssertEqual(probe.stats.moves, 1)
        let focus = try XCTUnwrap(probe.stats.focusMs.first)
        let press = try XCTUnwrap(probe.stats.pressMs.first)
        XCTAssertGreaterThanOrEqual(focus, 200, "the stall before the move's frame is in the focus figure")
        XCTAssertGreaterThanOrEqual(press, 200, "and in the press figure")
        XCTAssertLessThan(focus, 1000)
        XCTAssertFalse(frames.running, "the wait stops at its frame")
    }

    /// High, the first screen: the same, from the first row configured.
    func testTheFirstScreenEndsAtTheFrameAfterItsRowsSoAStallBeforeThatFrameCounts() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults); GuidePerf.resetForTests() }
        let probe = try probeOnScreen(defaults)
        let frames = ManualFrames()
        GuidePerf.makeFrames = { frames }
        GuidePerf.screenAppeared(rowsShown: false)
        GuidePerf.rowsOnScreen()
        frames.tick()
        XCTAssertNil(probe.stats.firstScreenMs, "not ended at the first callback after the rows were configured")
        Thread.sleep(forTimeInterval: 0.2)
        frames.tick()
        let ms = try XCTUnwrap(probe.stats.firstScreenMs)
        XCTAssertGreaterThanOrEqual(ms, 200, "the stall before the first screen's frame is in the figure")
        XCTAssertLessThan(ms, 1000)
    }

    // MARK: Review of 374 (mediums)

    /// Medium: the signposts ended at callback time while the probe used the frame's due time. A completed interval's end
    /// now carries the frame-due figure, the same number the probe records (for a move and for the first screen).
    func testTheSignpostsCarryTheSameFrameDueFigureAsTheProbe() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults); GuidePerf.resetForTests() }
        let probe = try probeOnScreen(defaults)
        let frames = ManualFrames()
        GuidePerf.makeFrames = { frames }
        GuidePerf.focusMoved(row: 3)
        GuidePerf.focusHandled()
        frames.tick()
        frames.tick(due: CACurrentMediaTime() + 0.25) // due well after the callback: the two timings differ by 250 ms
        let move = try XCTUnwrap(probe.stats.focusMs.first)
        XCTAssertGreaterThanOrEqual(move, 240, "the probe's figure ends when the frame is due")
        XCTAssertEqual(try XCTUnwrap(GuidePerf.lastFrameDueMs["GuideFocusMove"], "the move's signpost carries no figure"),
                       move, accuracy: 0.001)
        GuidePerf.screenAppeared(rowsShown: false)
        GuidePerf.rowsOnScreen()
        frames.tick()
        frames.tick(due: CACurrentMediaTime() + 0.25)
        let first = try XCTUnwrap(probe.stats.firstScreenMs)
        XCTAssertEqual(try XCTUnwrap(GuidePerf.lastFrameDueMs["GuideFirstScreen"], "the first screen's signpost carries no figure"),
                       first, accuracy: 0.001)
    }

    /// Medium: the held-scroll gate counted focus events, not rows. The probe keeps the focused row (the grid's section)
    /// of the latest move, across a reset, and says it in its JSON, so the test can measure forward progress in rows.
    func testTheProbeKeepsTheFocusedRowAcrossAReset() throws {
        let defaults = try newDefaults()
        defer { tidy(defaults) }
        let probe = try probeOnScreen(defaults)
        GuidePerf.focusMoved(row: 7)
        GuidePerf.focusMoved(row: 8)
        XCTAssertEqual(probe.stats.focusRow, 8)
        probe.reset()
        XCTAssertEqual(probe.stats.focusRow, 8, "a reset keeps where focus is")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["focusRow"] as? Int, 8)
        GuidePerf.guideVisible(false)
        GuidePerf.focusMoved(row: 40)
        XCTAssertEqual(probe.stats.focusRow, 8, "nothing is recorded while the Guide is not on screen")
    }

    // MARK: Review of 373: the fixtures never publish to the Top Shelf

    #if os(tvOS)
    /// Medium: the Guide fixtures' line-ups (the 14-channel one and the production-shaped one, loaded and paged through
    /// the app's own loading) never reach the shared Top Shelf snapshot: the seeded last-written snapshot stays, no Top
    /// Shelf file change is queued and the App Group's snapshot file (if this host has one) is as it was.
    func testTheGuideFixturesNeverPublishToTheTopShelf() async throws {
        let savedSnapshot = TopShelfExport.lastWritten
        let filterKey = "pigtv.guide.filter"
        let savedFilter = UserDefaults.standard.object(forKey: filterKey)
        defer {
            TopShelfExport.lastWritten = savedSnapshot
            UserDefaults.standard.set(savedFilter, forKey: filterKey)
        }
        await TopShelfCardExport.finish()
        let seeded = TopShelfSnapshot(kind: "favourites", channels: [
            TopShelfSnapshot.Entry(id: "seeded", sourceId: 1, name: "Seeded", number: nil, logo: nil, programmes: []),
        ], savedAt: Date(timeIntervalSince1970: 1_795_000_000))
        TopShelfExport.lastWritten = seeded
        let onDisk = TopShelfSnapshot.fileURL.flatMap { try? Data(contentsOf: $0) }
        let queued = TopShelfPublication.shared.queuedCount

        let app = AppModel()
        app.injectGuideFixture()
        let small = try XCTUnwrap(app.browse)
        await small.exportTopShelfUntilWritten()
        app.injectProductionGuideFixture()
        let large = try XCTUnwrap(app.browse)
        ProductionGuideServer.pageDelay = 0
        await large.exportTopShelfUntilWritten()
        await large.loadGuide()
        for _ in 0..<500 where large.guidePaging { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(large.guide.count, ProductionGuideFixture.channelCount, "the fixture was loaded and paged")
        await TopShelfCardExport.finish()

        XCTAssertEqual(TopShelfExport.lastWritten, seeded, "a fixture's line-up replaced the Top Shelf snapshot")
        XCTAssertEqual(TopShelfPublication.shared.queuedCount, queued, "a fixture queued a Top Shelf file change")
        XCTAssertEqual(TopShelfSnapshot.fileURL.flatMap { try? Data(contentsOf: $0) }, onDisk)
    }

    /// Review of 374, medium: signing out inside a Guide fixture (Settings › Account › Sign out) cleared the shared Top
    /// Shelf and retired its generation although the fixture never published. With a seeded snapshot (in memory and, where
    /// this host has the App Group, on disk) the sign-out leaves it, its generation and the file queue as they were.
    func testSigningOutOfAGuideFixtureLeavesTheTopShelfAlone() async throws {
        let savedSnapshot = TopShelfExport.lastWritten
        let fileURL = TopShelfSnapshot.fileURL
        let savedFile = fileURL.flatMap { try? Data(contentsOf: $0) }
        defer {
            TopShelfExport.lastWritten = savedSnapshot
            if let fileURL {
                if let savedFile { try? savedFile.write(to: fileURL) } else { try? FileManager.default.removeItem(at: fileURL) }
            }
        }
        await TopShelfCardExport.finish()
        let seeded = TopShelfSnapshot(kind: "favourites", channels: [
            TopShelfSnapshot.Entry(id: "seeded", sourceId: 1, name: "Seeded", number: nil, logo: nil, programmes: []),
        ], savedAt: Date(timeIntervalSince1970: 1_795_000_000))
        TopShelfExport.lastWritten = seeded
        if fileURL != nil { XCTAssertTrue(seeded.write(container: TopShelfSnapshot.containerURL)) }
        let onDisk = fileURL.flatMap { try? Data(contentsOf: $0) }

        for production in [false, true] {
            let generation = TopShelfPublication.shared.current
            let queued = TopShelfPublication.shared.queuedCount
            let app = AppModel()
            if production { app.injectProductionGuideFixture() } else { app.injectGuideFixture() }
            XCTAssertNotNil(app.browse)
            await app.logout()
            XCTAssertNil(app.browse, "signed out")
            // A queued removal would run on the file queue: it has run once the queue is idle.
            await TopShelfPublication.shared.idle()
            XCTAssertEqual(TopShelfExport.lastWritten, seeded, "the sign-out cleared the Top Shelf snapshot (production \(production))")
            XCTAssertEqual(TopShelfPublication.shared.current, generation, "the sign-out retired the Top Shelf generation")
            XCTAssertEqual(TopShelfPublication.shared.queuedCount, queued + 1, "the sign-out queued a Top Shelf file change") // +1: the wait above
            XCTAssertEqual(fileURL.flatMap { try? Data(contentsOf: $0) }, onDisk, "the snapshot on disk changed")
        }
    }
    #endif

    // MARK: The production-shaped fixture

    private let window = ProductionGuideFixture.window(now: Date(timeIntervalSince1970: 1_795_000_000))

    func testTheProductionGuideHasTheShapeOfARealOne() {
        let channels = ProductionGuideFixture.channels(count: 1250, window: window)
        XCTAssertEqual(channels.count, 1250)
        XCTAssertEqual(Set(channels.map(\.id)).count, 1250)
        XCTAssertEqual(Set(channels.compactMap(\.logo)).count, 1250, "a logo of its own on every channel")
        let from = window.timeIntervalSince1970 * 1000
        let to = from + 24 * 3_600_000
        let categoryIDs = Set(ProductionGuideFixture.categories(count: 1250).map(\.rawID))
        // #360: like a real guide, divider rows (2-hour blocks titled with a run of 14 symbols, about 15 in 500 rows) and
        // channels with no programmes (about 6 in 500).
        let kinds = (0..<500).map(ProductionGuideFixture.rowKind)
        XCTAssertEqual(kinds.filter { $0 == .divider }.count, 15)
        XCTAssertEqual(kinds.filter { $0 == .empty }.count, 6)
        for (index, channel) in channels.enumerated() {
            let programmes = channel.programmes
            switch ProductionGuideFixture.rowKind(index) {
            case .empty:
                XCTAssertTrue(programmes.isEmpty, "\(channel.name) has programmes")
                continue
            case .divider:
                XCTAssertTrue((12...13).contains(programmes.count), "\(channel.name): \(programmes.count) blocks")
                XCTAssertTrue(programmes.allSatisfy { $0.endTime - $0.startTime == 7_200_000 && $0.title.count == 14
                    && !$0.title.contains { $0.isLetter || $0.isNumber } }, channel.name)
                XCTAssertLessThanOrEqual(programmes.first?.startTime ?? .infinity, from)
                XCTAssertGreaterThanOrEqual(programmes.last?.endTime ?? 0, to)
                continue
            case .ordinary: break
            }
            XCTAssertTrue((24...26).contains(programmes.count), "\(channel.name): \(programmes.count) programmes")
            XCTAssertLessThanOrEqual(programmes.first?.startTime ?? .infinity, from, "\(channel.name) starts late")
            XCTAssertGreaterThanOrEqual(programmes.last?.endTime ?? 0, to, "\(channel.name) ends early")
            XCTAssertTrue(zip(programmes, programmes.dropFirst()).allSatisfy { $0.endTime == $1.startTime }, "\(channel.name) has a gap")
            for programme in programmes {
                XCTAssertTrue((150...300).contains(programme.description?.count ?? 0),
                              "\(programme.description?.count ?? 0) characters: \(programme.description ?? "")")
            }
            XCTAssertTrue(categoryIDs.contains(channel.category ?? ""))
        }
    }

    func testFortyCategoriesThreeOfThemSportCountingEveryChannelOnce() {
        let categories = ProductionGuideFixture.categories(count: 1250)
        XCTAssertEqual(categories.count, 40)
        XCTAssertEqual(categories.filter(\.sport).count, 3)
        XCTAssertEqual(categories.map(\.channelCount).reduce(0, +), 1250)
        let channels = ProductionGuideFixture.channels(count: 1250, window: window)
        for category in categories {
            XCTAssertEqual(channels.filter { $0.matches(category) }.count, category.channelCount, category.name)
        }
        XCTAssertEqual(GuideChips.make(categories: categories).count, 43, "All, Favourites, Sport and the 40")
    }

    func testAnyWindowAgreesWithAnyOther() {
        let a = window.timeIntervalSince1970 * 1000
        let b = a + 24 * 3_600_000, c = b + 24 * 3_600_000
        for channel in [0, 5, 7, 20, 1249] {
            let whole = ProductionGuideFixture.programmes(channel: channel, from: a, to: c)
            let merged = GuideNavigation.mergeProgrammes(ProductionGuideFixture.programmes(channel: channel, from: a, to: b),
                                                         adding: ProductionGuideFixture.programmes(channel: channel, from: b, to: c))
            XCTAssertEqual(merged, whole)
        }
    }

    func testTheServerAnswersLogosAsPNGAndNothingElseItDoesNotKnow() throws {
        let logo = ProductionGuideServer.answer(for: try XCTUnwrap(URL(string: "http://127.0.0.1:3000/api/logo/fixture-prod-42")))
        XCTAssertEqual(logo.status, 200)
        XCTAssertEqual(logo.type, "image/png")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(logo.body as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(ProductionGuideServer.answer(for: try XCTUnwrap(URL(string: "http://127.0.0.1:3000/api/recordings"))).status, 404)
    }

    /// The paged arrival goes through the app's own loading: the version, then three pages of 500.
    func testTheAppsOwnPagingFetchesTheWholeGuideInThreePages() async throws {
        ProductionGuideServer.channelCount = 1250
        ProductionGuideServer.pageDelay = 0
        let client = APIClient(address: try ServerAddress(ProductionGuideFixture.address), token: "fixture",
                               session: ProductionGuideFixture.session())
        let model = BrowseModel(client: client, guideCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        model.window = window
        await model.loadGuide()
        XCTAssertEqual(model.guide.count, 500, "the first page")
        for _ in 0..<500 where model.guidePaging { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.guide.count, 1250)
        XCTAssertEqual(model.guideTotal, 1250)
        XCTAssertFalse(model.guideHasMore)
        XCTAssertNil(model.guideError)
        XCTAssertEqual(model.guide.map(\.rawID), (0..<1250).map { "p\($0)" })
        XCTAssertEqual(model.guide[3].programmes, ProductionGuideFixture.channels(count: 4, window: window)[3].programmes)
    }

    // MARK: The other fixtures are as they were

    func testTheOtherGuideFixturesAreUnchanged() throws {
        XCTAssertNil(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_GUIDE_SHAPE"])
        let base = GuideFixtures.channels()
        XCTAssertEqual(base.count, 14)
        XCTAssertEqual(base.map(\.name).first, "Sky Sports Main Event")
        XCTAssertTrue(base.allSatisfy { $0.logo == nil })
        XCTAssertTrue(base[9].programmes.isEmpty, "the channel without EPG")
        XCTAssertTrue(base[0].programmes.first?.description?.hasPrefix("Synthetic programme for layout testing on") == true)
        XCTAssertEqual(GuideFixtures.categories().map(\.name), ["Sports", "Movies", "News", "Kids"])
        let app = AppModel()
        app.injectGuideFixture()
        let browse = try XCTUnwrap(app.browse)
        XCTAssertEqual(browse.guide.count, GuideFixtures.requestedCount ?? 14)
        XCTAssertEqual(browse.guide.first?.rawID, "ch0")
        XCTAssertEqual(app.categories.count, 4)
        XCTAssertNil(browse.guide.first?.logo, "the guide fixture has no logos")
    }
}
