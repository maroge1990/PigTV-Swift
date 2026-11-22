import OSLog
import QuartzCore
import UIKit

/// #362 (speed programme, batch 1): what the TV Guide costs, measured, never changed. Signposts in every build (subsystem
/// = the bundle id, category "Responsiveness", read in Instruments or by `XCTOSSignpostMetric`), carrying no payload but
/// a row count and an apply kind; never a URL, token or channel address.
/// - `GuideApplyRows` (interval): one grid apply, the batch-update and the reload paths.
/// - `GuideCellConfigure` (interval): one programme or tile cell's configuration.
/// - `GuideFocusMove` (interval): the grid's focus update → the frame after the SwiftUI side handled it (`GuideFrameWait`).
/// - `GuideBodyEval` (event): `GuideView.body` evaluated.
/// - `GuideFirstScreen` (interval): the Guide appearing → the frame after its first rows were configured (`GuideFrameWait`).
/// The same hooks feed `GuidePerfProbe` while it is on (Settings › About › Guide speed readout, or the UI tests' launch
/// variable); while it is off each hook's probe part is one nil check (GuidePerfProbe.swift).
@MainActor
enum GuidePerf {
    private static var signposter: OSSignposter { PigTVSignpost.signposter }

    /// Frame ticks are armed only when someone is watching: Instruments (or XCTest) recording, or the probe.
    private static var watching: Bool { GuidePerfProbe.shared != nil || signposter.isEnabled }
    static var isWatching: Bool { watching }

    /// The probe's clock: 0 (not read) unless the probe is on.
    private static func probeClock() -> CFTimeInterval { GuidePerfProbe.shared != nil ? CACurrentMediaTime() : 0 }

    // MARK: Grid applies and cell configurations

    struct Interval {
        fileprivate let state: OSSignpostIntervalState
        fileprivate let began: CFTimeInterval
    }

    /// nil unless someone is watching: with the readout off and nothing recording, one flag check and nothing made.
    static func applyBegan() -> Interval? {
        guard watching else { return nil }
        return Interval(state: signposter.beginInterval("GuideApplyRows", id: signposter.makeSignpostID()), began: probeClock())
    }

    /// `kind`: append, extend, reload or same (which path the apply took).
    static func applyEnded(_ interval: Interval?, rows: Int, kind: String) {
        guard let interval else { return }
        signposter.endInterval("GuideApplyRows", interval.state, "\(kind, privacy: .public) \(rows)")
        if let probe = GuidePerfProbe.shared { probe.applied(ms: (CACurrentMediaTime() - interval.began) * 1000, rows: rows) }
    }

    /// nil unless someone is watching (as `applyBegan`).
    static func cellBegan() -> Interval? {
        #if DEBUG
        cellConfigurationsForTesting += 1
        #endif
        guard watching else { return nil }
        return Interval(state: signposter.beginInterval("GuideCellConfigure", id: signposter.makeSignpostID()), began: 0)
    }

    static func cellEnded(_ interval: Interval?) {
        guard let interval else { return }
        signposter.endInterval("GuideCellConfigure", interval.state)
        GuidePerfProbe.shared?.cellConfigured()
    }

    /// #360 (G8): the grid's layout ran a full `prepare` (GuideGridLayout). One nil check while the probe is off.
    static func layoutPrepared() { GuidePerfProbe.shared?.layoutPrepared() }

    /// Review of 378: the start of the layout's own work (`prepare()`, `layoutAttributesForElements(in:)`): 0, with no
    /// clock read, unless the probe is on.
    static func layoutWorkBegan() -> CFTimeInterval { probeClock() }

    /// The end of that work: the probe adds its milliseconds and counts the call. One check while the probe is off.
    static func layoutWorkEnded(_ began: CFTimeInterval, prepare: Bool) {
        guard began > 0, let probe = GuidePerfProbe.shared else { return }
        probe.layoutWorked(ms: (CACurrentMediaTime() - began) * 1000, prepare: prepare)
    }

    /// Review of 378: the header's day changed (GuideView's `shownDay`), which re-evaluates GuideView.body once.
    static func dayChanged() { GuidePerfProbe.shared?.count(\.dayChanges) }

    /// #360/#361 (C1): the size of the first guide page put on screen since launch (the small first page, or the full
    /// first page when that came first), in bytes as received. One nil check while the probe is off.
    static func firstGuidePage(bytes: Int) { GuidePerfProbe.shared?.firstGuidePage(bytes: bytes) }

    // MARK: Channel logos (#360 G4)

    #if DEBUG
    /// Tests: logo fetches started and cancelled, and logos drawn from memory at once or a frame late, probe or not.
    static var logoFetchesForTesting = 0
    static var logoCancelsForTesting = 0
    static var logoSyncHitsForTesting = 0
    static var logoLateHitsForTesting = 0
    #endif

    static func logoFetchStarted() {
        #if DEBUG
        logoFetchesForTesting += 1
        #endif
        GuidePerfProbe.shared?.count(\.logoFetches)
    }

    static func logoFetchCancelled() {
        #if DEBUG
        logoCancelsForTesting += 1
        #endif
        GuidePerfProbe.shared?.count(\.logoCancels)
    }

    static func logoSyncHit() {
        #if DEBUG
        logoSyncHitsForTesting += 1
        #endif
        GuidePerfProbe.shared?.count(\.logoSyncHits)
    }

    static func logoLateHit() {
        #if DEBUG
        logoLateHitsForTesting += 1
        #endif
        GuidePerfProbe.shared?.count(\.logoLateHits)
    }

    // MARK: GuideView

    #if DEBUG
    /// Tests: every `GuideView.body` evaluation, probe or not.
    static var bodyEvaluationsForTesting = 0
    /// Tests: every grid cell configuration (programme or tile), probe or not.
    static var cellConfigurationsForTesting = 0
    #endif

    static func bodyEvaluated() {
        #if DEBUG
        bodyEvaluationsForTesting += 1
        #endif
        signposter.emitEvent("GuideBodyEval")
        GuidePerfProbe.shared?.bodyEvaluated()
    }

    // MARK: Frames

    /// The frame callbacks a measurement's `GuideFrameWait` counts: the display link in the app; unit tests put in a
    /// source they tick themselves.
    static var makeFrames: @MainActor () -> any GuideFrames = { DisplayLinkFrames() }

    // MARK: Focus moves

    private static var focusMove: (id: Int, state: OSSignpostIntervalState, began: CFTimeInterval)?
    private static var focusMoves = 0
    private static var ticks: [Int: GuideFrameWait] = [:]

    /// The grid's `didUpdateFocusIn` with a cell next: a move begins (a move still waiting for its frame is superseded).
    /// The probe pairs it with the arrow press that caused it, if one came just before; any other stored press is dropped.
    /// `row`: the focused row (the grid's section), which the probe keeps so the held-scroll test can check how far focus
    /// went (#362, review of 374).
    static func focusMoved(row: Int? = nil) {
        guard watching else { return }
        GuidePerfProbe.shared?.focusBegan()
        if let row { GuidePerfProbe.shared?.focusRow(row) }
        if let pending = focusMove {
            signposter.endInterval("GuideFocusMove", pending.state, "superseded")
            GuidePerfProbe.shared?.focusSuperseded()
        }
        focusMoves += 1
        focusMove = (focusMoves, signposter.beginInterval("GuideFocusMove", id: signposter.makeSignpostID()), CACurrentMediaTime())
    }

    /// GuideView has been told (`focusChanged`): the move ends at the frame after the one that change opened, once its
    /// layout and drawing have been done on the main thread (`GuideFrameWait`), timed to when that frame is due on screen.
    static func focusHandled() {
        guard let move = focusMove, ticks[move.id] == nil else { return }
        ticks[move.id] = GuideFrameWait(frames: makeFrames()) { shown in
            ticks[move.id] = nil
            guard let current = focusMove, current.id == move.id else { return }
            focusMove = nil
            let ms = (shown - current.began) * 1000
            endTimed("GuideFocusMove", current.state, ms: ms)
            GuidePerfProbe.shared?.focusLanded(ms: ms, at: shown)
        }
    }

    /// #362 (review of 374): a signpost interval can only end now, at the second frame callback, while the figure the
    /// probe and the perf test report ends when that callback's frame is due on screen (up to a frame later). So the
    /// interval's own length is callback timing; its end message carries the frame-due figure (`frameDueMs`), the same
    /// number the probe records, for Instruments and anyone comparing the two.
    private static func endTimed(_ name: StaticString, _ state: OSSignpostIntervalState, ms: Double) {
        signposter.endInterval(name, state, "frameDueMs \(ms, format: .fixed(precision: 1), privacy: .public)")
        #if DEBUG
        lastFrameDueMs["\(name)"] = ms
        #endif
    }

    #if DEBUG
    /// Tests: the frame-due figure each kind of interval last ended with (what its end message carries).
    private(set) static var lastFrameDueMs: [String: Double] = [:]
    #endif

    /// Focus left the grid (to the filter bar or the tab bar): the open move is dropped, neither landed nor superseded,
    /// so the next move into the grid does not count the time away.
    static func focusLeftGrid() {
        GuidePerfProbe.shared?.focusLeft()
        guard let pending = focusMove else { return }
        focusMove = nil
        signposter.endInterval("GuideFocusMove", pending.state, "left")
    }

    // MARK: Visibility

    /// The Guide's `whileVisible` work started (true) or ended (false: another tab, the player over it). Counted, not
    /// flagged: when that work restarts, the old run's end can arrive after the new run's start. The probe records only
    /// while at least one run is going.
    private static var visibleRuns = 0
    static var isGuideVisible: Bool { visibleRuns > 0 }
    static func guideVisible(_ visible: Bool) {
        let wasVisible = visibleRuns > 0
        visibleRuns = max(0, visibleRuns + (visible ? 1 : -1))
        GuidePerfProbe.shared?.setGuideVisible(visibleRuns > 0)
        if wasVisible, visibleRuns == 0 { abandonFirstScreen() } // left the screen before its rows were drawn
    }

    // MARK: First screen

    /// A first screen not drawn within this long (an empty Guide) is abandoned, not timed.
    static let firstScreenLimit: CFTimeInterval = 30

    /// `sample`: the probe records it (the Guide's first appearance since launch, with the probe already on).
    private static var firstScreen: (id: Int, state: OSSignpostIntervalState, began: CFTimeInterval, sample: Bool)?
    private static var firstScreens = 0
    private static var firstScreenTick: GuideFrameWait?
    private static var guideHasAppeared = false

    /// The Guide appeared. `rowsShown`: its grid already has rows (a return to the tab), so the next frame shows them.
    /// Only the first appearance since launch, with the probe on then, is the readout's first screen; later ones (a return
    /// to the tab, the readout switched on later) are signposts only.
    static func screenAppeared(rowsShown: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let launch = !guideHasAppeared
        guideHasAppeared = true
        guard watching else { return }
        if let pending = firstScreen, now - pending.began > firstScreenLimit { abandonFirstScreen() }
        guard firstScreen == nil else { return }
        firstScreens += 1
        firstScreen = (firstScreens, signposter.beginInterval("GuideFirstScreen", id: signposter.makeSignpostID()), now,
                       launch && GuidePerfProbe.shared != nil)
        if rowsShown { rowsOnScreen() }
    }

    /// A grid cell was configured with a row: the interval ends at the frame after the next (`GuideFrameWait`), timed to
    /// when that frame is due on screen (abandoned if past the limit).
    static func rowsOnScreen() {
        guard let pending = firstScreen, firstScreenTick == nil else { return }
        if CACurrentMediaTime() - pending.began > firstScreenLimit {
            abandonFirstScreen()
            return
        }
        firstScreenTick = GuideFrameWait(frames: makeFrames()) { shown in
            guard let current = firstScreen, current.id == pending.id else { return } // abandoned meanwhile
            firstScreenTick = nil
            firstScreen = nil
            let ms = (shown - current.began) * 1000
            endTimed("GuideFirstScreen", current.state, ms: ms)
            if current.sample { GuidePerfProbe.shared?.firstScreen(ms: ms) }
        }
    }

    /// The Guide left the screen, or never had rows in time: the open first-screen measurement ends without a figure.
    private static func abandonFirstScreen() {
        firstScreenTick = nil // its frame may still come; it finds a different (or no) measurement and does nothing
        guard let pending = firstScreen else { return }
        firstScreen = nil
        signposter.endInterval("GuideFirstScreen", pending.state, "abandoned")
    }

    #if DEBUG
    /// Unit tests: the measurements' state as at launch (open intervals are dropped), on the display link.
    static func resetForTests() {
        makeFrames = { DisplayLinkFrames() }
        focusMove = nil
        ticks = [:]
        visibleRuns = 0
        firstScreen = nil
        firstScreenTick = nil
        guideHasAppeared = false
        lastFrameDueMs = [:]
        logoFetchesForTesting = 0
        logoCancelsForTesting = 0
        logoSyncHitsForTesting = 0
        logoLateHitsForTesting = 0
    }
    #endif
}

/// One frame callback after another, each with when its frame is due on screen (CACurrentMediaTime's clock), until stopped.
@MainActor protocol GuideFrames: AnyObject {
    func start(_ frame: @escaping @MainActor (_ due: CFTimeInterval) -> Void)
    func stop()
}

/// The app's frames: a display link on the main run loop, `targetTimestamp` as the time due.
@MainActor final class DisplayLinkFrames: NSObject, GuideFrames {
    private var link: CADisplayLink?
    private var frame: (@MainActor (CFTimeInterval) -> Void)?

    func start(_ frame: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.frame = frame
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        frame = nil
    }

    @objc private func tick(_ link: CADisplayLink) { frame?(link.targetTimestamp) }
}

/// #362 (review of 373, high): a measurement's end, two frame callbacks after the Guide's work, then gone. The first
/// callback after the work (a focus change handled, a row configured) only opens the chance to draw: the layout and drawing
/// of that work happen after it, on the main thread, and a stall there would go uncounted. The second can come only once
/// they are done, so the measurement ends there, at the time its frame is due on screen: a close estimate of what you see,
/// one frame later than the work's own end, not a camera measurement.
@MainActor final class GuideFrameWait {
    static let callbacks = 2
    private let frames: any GuideFrames
    private var seen = 0

    init(frames: any GuideFrames, _ done: @escaping @MainActor (_ shown: CFTimeInterval) -> Void) {
        self.frames = frames
        frames.start { [self] due in
            seen += 1
            guard seen >= Self.callbacks else { return }
            self.frames.stop()
            done(due)
        }
    }
}
