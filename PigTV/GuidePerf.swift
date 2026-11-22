import OSLog
import QuartzCore
import UIKit

/// #362 (speed programme, batch 1): what the TV Guide costs, measured, never changed. Signposts in every build (subsystem
/// = the bundle id, category "Responsiveness", read in Instruments or by `XCTOSSignpostMetric`), carrying no payload but
/// a row count and an apply kind; never a URL, token or channel address.
/// - `GuideApplyRows` (interval): one grid apply, the batch-update and the reload paths.
/// - `GuideCellConfigure` (interval): one programme or tile cell's configuration.
/// - `GuideFocusMove` (interval): the grid's focus update → the first frame drawn after the SwiftUI side handled it.
/// - `GuideBodyEval` (event): `GuideView.body` evaluated.
/// - `GuideFirstScreen` (interval): the Guide appearing → the first frame with rows on screen.
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
        guard watching else { return nil }
        return Interval(state: signposter.beginInterval("GuideCellConfigure", id: signposter.makeSignpostID()), began: 0)
    }

    static func cellEnded(_ interval: Interval?) {
        guard let interval else { return }
        signposter.endInterval("GuideCellConfigure", interval.state)
        GuidePerfProbe.shared?.cellConfigured()
    }

    // MARK: GuideView

    static func bodyEvaluated() {
        signposter.emitEvent("GuideBodyEval")
        GuidePerfProbe.shared?.bodyEvaluated()
    }

    // MARK: Focus moves

    private static var focusMove: (id: Int, state: OSSignpostIntervalState, began: CFTimeInterval)?
    private static var focusMoves = 0
    private static var ticks: [Int: PigTVSignpost.FrameTick] = [:]

    /// The grid's `didUpdateFocusIn` with a cell next: a move begins (a move still waiting for its frame is superseded).
    /// The probe pairs it with the arrow press that caused it, if one came just before; any other stored press is dropped.
    static func focusMoved() {
        guard watching else { return }
        GuidePerfProbe.shared?.focusBegan()
        if let pending = focusMove {
            signposter.endInterval("GuideFocusMove", pending.state, "superseded")
            GuidePerfProbe.shared?.focusSuperseded()
        }
        focusMoves += 1
        focusMove = (focusMoves, signposter.beginInterval("GuideFocusMove", id: signposter.makeSignpostID()), CACurrentMediaTime())
    }

    /// GuideView has been told (`focusChanged`): the move ends on the next frame, which the main thread can draw only
    /// once SwiftUI has finished with what that changed.
    static func focusHandled() {
        guard let move = focusMove, ticks[move.id] == nil else { return }
        ticks[move.id] = PigTVSignpost.FrameTick {
            ticks[move.id] = nil
            guard let current = focusMove, current.id == move.id else { return }
            focusMove = nil
            signposter.endInterval("GuideFocusMove", current.state)
            GuidePerfProbe.shared?.focusLanded(ms: (CACurrentMediaTime() - current.began) * 1000)
        }
    }

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
    private static var firstScreenTick: PigTVSignpost.FrameTick?
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

    /// A grid cell was configured with a row: the interval ends on the next frame (abandoned if past the limit).
    static func rowsOnScreen() {
        guard let pending = firstScreen, firstScreenTick == nil else { return }
        if CACurrentMediaTime() - pending.began > firstScreenLimit {
            abandonFirstScreen()
            return
        }
        firstScreenTick = PigTVSignpost.FrameTick {
            guard let current = firstScreen, current.id == pending.id else { return } // abandoned meanwhile
            firstScreenTick = nil
            firstScreen = nil
            signposter.endInterval("GuideFirstScreen", current.state)
            if current.sample { GuidePerfProbe.shared?.firstScreen(ms: (CACurrentMediaTime() - current.began) * 1000) }
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
    /// Unit tests: the measurements' state as at launch (open intervals are dropped).
    static func resetForTests() {
        focusMove = nil
        ticks = [:]
        visibleRuns = 0
        firstScreen = nil
        firstScreenTick = nil
        guideHasAppeared = false
    }
    #endif
}
