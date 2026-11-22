import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// #360 (D1), measurement only: one grid apply. `ms` is its own synchronous main-thread time (`checkMs` deciding the path,
/// `updateMs` the store and collection view update, `refreshMs` corrected rows' cells); `after*` is what followed on the
/// main thread before the next frame (the collection view's layout and cell configurations: UIKit lays out after the
/// apply returns), and `gapMs` that next frame's gap (the whole stall the apply was part of).
nonisolated struct ApplyRecord: Equatable, Sendable {
    var kind = ""
    /// direct (GuideView's update) or fill (a first fill, after its lists were ordered off the main thread).
    var via = "direct"
    var rowsBefore = 0
    var rowsAfter = 0
    var ms: Double = 0
    var checkMs: Double = 0
    var updateMs: Double = 0
    var refreshMs: Double = 0
    var orders = 0
    var orderMs: Double = 0
    var layoutMs: Double = 0
    var itemQueries = 0
    var itemQueryMs: Double = 0
    var countQueries = 0
    var countMs: Double = 0
    var cellConfigs = 0
    var afterLayoutMs: Double = 0
    var afterCellConfigs = 0
    var afterOrders = 0
    var gapMs: Double?
    var arrowDown = false
    var pressPendingMs: Double?
    var moveOpen = false
    var focusRow: Int?
    var inMove: Bool { arrowDown || pressPendingMs != nil || moveOpen }

    var object: [String: Any] {
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var o: [String: Any] = ["kind": kind, "via": via, "rowsBefore": rowsBefore, "rowsAfter": rowsAfter, "ms": r(ms),
                                "checkMs": r(checkMs), "updateMs": r(updateMs), "refreshMs": r(refreshMs), "orders": orders,
                                "orderMs": r(orderMs), "layoutMs": r(layoutMs), "itemQueries": itemQueries,
                                "itemQueryMs": r(itemQueryMs), "countQueries": countQueries, "countMs": r(countMs),
                                "cellConfigs": cellConfigs, "afterLayoutMs": r(afterLayoutMs),
                                "afterCellConfigs": afterCellConfigs, "afterOrders": afterOrders, "arrowDown": arrowDown,
                                "moveOpen": moveOpen, "inMove": inMove]
        if let gapMs { o["gapMs"] = r(gapMs) }
        if let pressPendingMs { o["pressPendingMs"] = r(pressPendingMs) }
        if let focusRow { o["focusRow"] = focusRow }
        return o
    }
}

/// #362, measurement only: the Guide's figures since the probe was switched on or last reset, kept by `GuidePerfProbe`.
/// Pure, so the arithmetic is unit-tested (GuidePerfTests).
nonisolated struct GuidePerfStats: Equatable, Sendable {
    /// Samples kept per list (the readout can stay on for days); counts go on past it.
    static let sampleCap = 2000
    /// Focus moves that reached their frame.
    var moves = 0
    /// Each focus move: the grid's focus update → the frame after GuideView handled it (`GuideFrameWait`, ms).
    var focusMs: [Double] = []
    /// Each remote press that moved focus: the press event's own time → that same frame (ms).
    var pressMs: [Double] = []
    /// What each move felt like: press → frame where the press time is known, else focus update → frame (the readout).
    var feltMs: [Double] = []
    /// Moves overtaken by the next before their frame was drawn (no sample).
    var focusSuperseded = 0
    var frames = 0
    var maxGapMs: Double = 0
    var gapsOver50 = 0
    var gapsOver100 = 0
    var bodyEvaluations = 0
    var cellConfigurations = 0
    /// #360 (G8): full layout passes of the grid (a `prepare` after an invalidation of everything; a scroll that only
    /// moves the now line is a targeted one and is not counted).
    var layoutPrepares = 0
    /// Review of 378: the grid layout's own main-thread work: `prepare()` calls, `layoutAttributesForElements(in:)` calls,
    /// and the milliseconds spent in both (a monotonic clock, read only while the probe is on).
    var layoutPrepareRuns = 0
    var layoutQueries = 0
    var layoutMs: Double = 0
    /// Review of 378: the header's day changed (the viewport crossed midnight): one GuideView body evaluation each.
    var dayChanges = 0
    /// #360 (G4): channel logo fetches started (a logo not in memory), cancelled (no view waited for it any more), logos
    /// drawn from memory on a view's first frame, and logos found in memory only by the view's task (drawn a frame late).
    var logoFetches = 0
    var logoCancels = 0
    var logoSyncHits = 0
    var logoLateHits = 0
    var applies = 0
    var applyMs: Double = 0
    /// #360 (D1): each apply in the window, what it cost and what was going on when it began (`ApplyRecord`).
    var applyLog: [ApplyRecord] = []
    /// Applies that began while a move was in flight: an arrow down, a press not yet taken by a move, or a focus move
    /// not yet on screen.
    var appliesInMove = 0
    /// #360 (D1): each arrow press, down → up (ms); each focus move after its press went down, and after it came up
    /// (ms; a move while the press was still down is counted instead).
    var pressHeldMs: [Double] = []
    var moveAfterDownMs: [Double] = []
    var moveAfterUpMs: [Double] = []
    var movesWhileDown = 0
    /// Programme lists ordered on the main thread (the grid store's cache misses) and their ms.
    var orders = 0
    var orderMs: Double = 0
    /// #360 (D1): the layout's per-item calls (`layoutAttributesForItem(at:)`) and the data source's item counts, with ms.
    var itemQueries = 0
    var itemQueryMs: Double = 0
    var countQueries = 0
    var countMs: Double = 0
    /// #360 (D2): main-thread ms inside cell configurations (`updateConfiguration`: the cell's info to its hosting
    /// configuration; the SwiftUI content's own layout and drawing come later in the frame and are not in it).
    var cellConfigMs: Double = 0
    /// #360 (D2): the main thread's busy time (each run-loop pass from waking to sleeping, the frame's layout and commit
    /// included), an upper bound for everything the Guide does per press.
    var mainBusyMs: Double = 0
    var firstScreenMs: Double?
    /// #360/#361 (C1): the bytes of the first guide page put on screen (`GuidePerf.firstGuidePage`).
    var firstPageBytes: Int?
    /// #360 (C2, C3; DEBUG, PIGTV_UI_TEST_GUIDE_FIGURES=1): figures measured once in the app (`ProductionGuideFigures`),
    /// kept across resets.
    var figures: [String: Double] = [:]
    var resets = 0
    /// The grid's rows when the window began (the last reset), and after its latest apply.
    var rowsStart: Int?
    var rowsEnd: Int?
    /// The row (the grid's section) of the latest focus move; carried across a reset, so a test can read it before a
    /// window and again after it to see how far focus went (#362, review of 374).
    var focusRow: Int?

    /// A display-link frame; `gapMs` is the time since the previous one (nil for the first after a pause or reset).
    mutating func frame(gapMs: Double?) {
        frames += 1
        guard let gapMs else { return }
        maxGapMs = max(maxGapMs, gapMs)
        if gapMs > 50 { gapsOver50 += 1 }
        if gapMs > 100 { gapsOver100 += 1 }
    }

    /// A focus move reached its frame after `focusMs`; `pressMs` when its remote press's time is known.
    mutating func landed(focusMs focus: Double, pressMs press: Double?) {
        moves += 1
        Self.append(focus, to: &focusMs)
        if let press { Self.append(press, to: &pressMs) }
        Self.append(press ?? focus, to: &feltMs)
    }

    /// #360 (D1): a sample onto one of the lists, capped as the others.
    mutating func note(_ value: Double, _ list: WritableKeyPath<GuidePerfStats, [Double]>) { Self.append(value, to: &self[keyPath: list]) }

    private static func append(_ value: Double, to list: inout [Double]) {
        list.append(value)
        if list.count > sampleCap { list.removeFirst(list.count - sampleCap) }
    }

    /// Zero for the next window (the reset count goes on, so a test can see its reset arrive; the rows and the focused row
    /// carry over).
    mutating func reset() {
        self = GuidePerfStats(figures: figures, resets: resets + 1, rowsStart: rowsEnd, rowsEnd: rowsEnd, focusRow: focusRow)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Nearest-rank percentile (`p` in 0...100).
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Settings › About's one line: "64 moves · typical 85 ms · slowest 310 ms · 7 slow frames (over 100 ms) · longest
    /// stall 412 ms · first screen 900 ms · Apple 373".
    func readout(build: String) -> String {
        func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
        var parts: [String] = []
        if moves == 0 {
            parts.append("No moves in the TV Guide yet")
        } else {
            parts.append(moves == 1 ? "1 move" : "\(moves) moves")
            if let typical = Self.median(feltMs) { parts.append("typical \(ms(typical))") }
            if let slowest = feltMs.max() { parts.append("slowest \(ms(slowest))") }
        }
        if frames > 0 {
            parts.append("\(gapsOver100) slow \(gapsOver100 == 1 ? "frame" : "frames") (over 100 ms)")
            parts.append("longest stall \(ms(maxGapMs))")
        }
        if let firstScreenMs { parts.append("first screen \(ms(firstScreenMs))") }
        parts.append("Apple \(build)")
        return parts.joined(separator: " · ")
    }

    /// The probe's JSON (sorted keys), `windowMs` since the last reset (the UI tests read it).
    func json(windowMs: Double) -> String {
        var object: [String: Any] = [
            "focusMoves": moves, "focusMs": focusMs.map(Self.rounded), "pressMs": pressMs.map(Self.rounded),
            "focusSuperseded": focusSuperseded, "frames": frames, "maxGapMs": Self.rounded(maxGapMs),
            "gapsOver50": gapsOver50, "gapsOver100": gapsOver100, "bodyEvals": bodyEvaluations,
            "cellConfigs": cellConfigurations, "layoutPrepares": layoutPrepares,
            "layoutPrepareRuns": layoutPrepareRuns, "layoutQueries": layoutQueries, "layoutMs": Self.rounded(layoutMs),
            "dayChanges": dayChanges,
            "logoFetches": logoFetches, "logoCancels": logoCancels, "logoSyncHits": logoSyncHits, "logoLateHits": logoLateHits, "applies": applies, "applyMs": Self.rounded(applyMs),
            "applyLog": applyLog.map(\.object), "appliesInMove": appliesInMove,
            "pressHeldMs": pressHeldMs.map(Self.rounded), "moveAfterDownMs": moveAfterDownMs.map(Self.rounded),
            "moveAfterUpMs": moveAfterUpMs.map(Self.rounded), "movesWhileDown": movesWhileDown,
            "orders": orders, "orderMs": Self.rounded(orderMs), "itemQueries": itemQueries,
            "itemQueryMs": Self.rounded(itemQueryMs), "countQueries": countQueries, "countMs": Self.rounded(countMs),
            "cellConfigMs": Self.rounded(cellConfigMs), "mainBusyMs": Self.rounded(mainBusyMs),
            "cellConfigUs": cellConfigurations > 0 ? Self.rounded(cellConfigMs * 1000 / Double(cellConfigurations)) : 0,
            "resets": resets, "windowMs": Self.rounded(windowMs),
        ]
        if let rowsStart { object["rowsStart"] = rowsStart }
        if let rowsEnd { object["rowsEnd"] = rowsEnd }
        if let focusRow { object["focusRow"] = focusRow }
        if let firstScreenMs { object["firstScreenMs"] = Self.rounded(firstScreenMs) }
        if let firstPageBytes { object["firstPageBytes"] = firstPageBytes }
        for (key, value) in figures { object[key] = Self.rounded(value) }
        if let value = Self.median(focusMs) { object["focusMedianMs"] = Self.rounded(value) }
        if let value = Self.percentile(focusMs, 95) { object["focusP95Ms"] = Self.rounded(value) }
        if let value = focusMs.max() { object["focusMaxMs"] = Self.rounded(value) }
        if let value = Self.median(pressMs) { object["pressMedianMs"] = Self.rounded(value) }
        if let value = pressMs.max() { object["pressMaxMs"] = Self.rounded(value) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// #362, measurement only: the Guide's focus-move latencies, a frame-gap monitor and the counts behind them. In every
/// build, off by default; on through Settings › About › Guide speed readout (`defaultsKey`) or, in DEBUG builds, the
/// launch variable PIGTV_UI_TEST_GUIDEPROBE=1 (the UI tests).
///
/// Zero cost when off: `shared` is nil (no instance, no display link, no observers) and every hook (GuidePerf.swift, the
/// grid's press hook) stops at that one nil check. Switching off stops the display link and drops the probe.
/// Recording happens only while the Guide is on screen (and frame gaps only while the app is also active); nothing the
/// Guide observes changes because of the probe, and Settings reads the figures when it is shown.
///
/// DEBUG only: the Darwin notifications (`resetNotification` zeroes the figures; each move that reaches its frame posts
/// `focusNotification`, which the UI test waits on instead of querying the accessibility tree) and `debug.guidePerf`.
@MainActor
final class GuidePerfProbe: NSObject {
    static let defaultsKey = "pigtv.guide.speedReadout"
    nonisolated static let resetNotification = "au.markrogers.PigTV.guideProbe.reset"
    nonisolated static let focusNotification = "au.markrogers.PigTV.guideProbe.focus"
    static let readoutHint = "Typical and slowest: from the remote press (or the focus change, where the press time is not "
        + "known) to the frame after the TV Guide finished its work. Slow frames: more than 100 ms apart while the TV Guide was on "
        + "screen; longest stall: the longest of those gaps."
    /// Settings' footnote under the line: what the figures are, in plain words (#362, review of 373).
    static let readoutFootnote = "Each move is timed from the press to the frame after the TV Guide finished its work: a close "
        + "estimate of what you see, not a camera measurement. A stall shows in slow frames and the longest stall."

    #if DEBUG
    /// The UI tests' switch (launch environment).
    static let testHooks = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_GUIDEPROBE"] == "1"
    #endif

    /// Whether the probe starts on at launch.
    static func initiallyOn(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        if testHooks { return true }
        #endif
        return defaults.bool(forKey: defaultsKey)
    }

    /// nil while off. Read once, lazily, at the first hook.
    private(set) static var shared: GuidePerfProbe? = initiallyOn() ? GuidePerfProbe() : nil

    static var isOn: Bool { shared != nil }

    /// Settings' switch: on creates the probe (figures from now), off stops its display link and drops it.
    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
        if on, shared == nil {
            shared = GuidePerfProbe()
            shared?.setGuideVisible(GuidePerf.isGuideVisible)
        }
        if !on, let probe = shared {
            probe.stop()
            shared = nil
        }
    }

    private(set) var stats = GuidePerfStats()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var windowStart = CACurrentMediaTime()
    /// The last arrow press's event time, until the next focus move takes it (or finds it stale and drops it).
    private var pendingPress: TimeInterval?
    /// The press the open focus move took, until that move lands (or is superseded, or focus leaves the grid).
    private var movePress: TimeInterval?
    private(set) var guideVisible = false
    /// #360 (D1): the last arrow press's down and up times (UIPress timestamps), and whether it is down now.
    private var lastDown: TimeInterval?
    private var lastUp: TimeInterval?
    private(set) var arrowDown = false
    /// The latest apply's record index, until the next frame fills in what followed it (and the stats then).
    private var openApply: (index: Int, layoutMs: Double, cells: Int, orders: Int)?
    private var active: Bool
    private var observers: [NSObjectProtocol] = []
    /// #360 (D2): the main run loop's wake (first observer) and sleep (last observer, after Core Animation's commit).
    private var runLoopObservers: [CFRunLoopObserver] = []
    private var wokeAt: CFTimeInterval = 0

    private override init() {
        // Not yet active at launch is still the foreground: the became-active notice may have gone before this exists.
        active = UIApplication.shared.applicationState != .background
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        for (name, isActive) in [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { GuidePerfProbe.shared?.setActive(isActive) }
            })
        }
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { GuidePerfProbe.shared?.runLoopWoke() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { GuidePerfProbe.shared?.runLoopSleeps() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObservers.append(observer)
        }
        #if DEBUG
        if Self.testHooks { Self.observeResets() }
        if Self.testHooks, ProductionGuideFigures.requested {
            Task.detached(priority: .utility) {
                let figures = ProductionGuideFigures.measure()
                await MainActor.run { GuidePerfProbe.shared?.stats.figures = figures }
            }
        }
        #endif
    }

    /// Display link and observers gone (switching off).
    func stop() {
        link?.invalidate()
        link = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        runLoopObservers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        runLoopObservers = []
    }

    var hasDisplayLink: Bool { link != nil }
    var monitoringFrames: Bool { link.map { !$0.isPaused } ?? false }

    func setGuideVisible(_ visible: Bool) {
        guideVisible = visible
        updateLink()
    }

    func setActive(_ isActive: Bool) {
        active = isActive
        updateLink()
    }

    private func updateLink() {
        guard let link else { return }
        let run = guideVisible && active
        if link.isPaused == run {
            link.isPaused = !run
            lastFrame = 0 // a gap across a pause is not a stall
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let gap = lastFrame > 0 ? (now - lastFrame) * 1000 : nil
        stats.frame(gapMs: gap)
        lastFrame = now
        if let open = openApply {
            openApply = nil
            if stats.applyLog.indices.contains(open.index) {
                stats.applyLog[open.index].gapMs = gap
                stats.applyLog[open.index].afterLayoutMs = stats.layoutMs - open.layoutMs
                stats.applyLog[open.index].afterCellConfigs = stats.cellConfigurations - open.cells
                stats.applyLog[open.index].afterOrders = stats.orders - open.orders
            }
        }
    }

    func reset() {
        stats.reset()
        lastFrame = 0
        pendingPress = nil
        movePress = nil
        openApply = nil
        windowStart = CACurrentMediaTime()
    }

    /// Settings' line, read when Settings is shown.
    var readout: String { stats.readout(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") }
    var json: String { stats.json(windowMs: (CACurrentMediaTime() - windowStart) * 1000) }

    // Hooks (GuidePerf.swift, GuideGridSupport.swift). Only while the Guide is on screen.
    func applied(ms: Double, rows: Int, record: ApplyRecord? = nil) {
        stats.rowsEnd = rows
        guard guideVisible else { return }
        stats.applies += 1
        stats.applyMs += ms
        guard var record else { return }
        record.ms = ms
        if record.inMove { stats.appliesInMove += 1 }
        if stats.applyLog.count < GuidePerfStats.sampleCap { stats.applyLog.append(record) } else { return }
        openApply = (stats.applyLog.count - 1, stats.layoutMs, stats.cellConfigurations, stats.orders)
    }
    /// #360 (D1): what a moment holds: an arrow down, a press not yet taken by a move (its age, ms), the focus row.
    func moveState(into record: inout ApplyRecord) {
        record.arrowDown = arrowDown
        if let press = pendingPress {
            let age = CACurrentMediaTime() - press
            if age >= 0, age < Self.pressFreshness { record.pressPendingMs = age * 1000 }
        }
        record.focusRow = stats.focusRow
    }
    func ordered(ms: Double) {
        guard guideVisible else { return }
        stats.orders += 1
        stats.orderMs += ms
    }
    func focusRow(_ row: Int) { if guideVisible { stats.focusRow = row } }
    func cellConfigured(ms: Double = 0) {
        guard guideVisible else { return }
        stats.cellConfigurations += 1
        stats.cellConfigMs += ms
    }
    func runLoopWoke() { wokeAt = CACurrentMediaTime() }
    func runLoopSleeps() {
        guard wokeAt > 0 else { return }
        let busy = (CACurrentMediaTime() - wokeAt) * 1000
        wokeAt = 0
        if guideVisible, active { stats.mainBusyMs += busy }
    }
    func itemQueried(ms: Double) {
        guard guideVisible else { return }
        stats.itemQueries += 1
        stats.itemQueryMs += ms
    }
    func countQueried(ms: Double) {
        guard guideVisible else { return }
        stats.countQueries += 1
        stats.countMs += ms
    }
    func layoutPrepared() { if guideVisible { stats.layoutPrepares += 1 } }
    func layoutWorked(ms: Double, prepare: Bool) {
        guard guideVisible else { return }
        stats.layoutMs += ms
        if prepare { stats.layoutPrepareRuns += 1 } else { stats.layoutQueries += 1 }
    }
    func count(_ figure: WritableKeyPath<GuidePerfStats, Int>) { if guideVisible { stats[keyPath: figure] += 1 } }
    func bodyEvaluated() { if guideVisible { stats.bodyEvaluations += 1 } }
    func focusSuperseded() { if guideVisible { stats.focusSuperseded += 1 } }
    func firstScreen(ms: Double) { if stats.firstScreenMs == nil { stats.firstScreenMs = ms } }
    func firstGuidePage(bytes: Int) { if stats.firstPageBytes == nil { stats.firstPageBytes = bytes } }

    /// A press older than this when a focus move begins is not that move's press (a swipe moved focus since, or the
    /// press moved nothing): one second, three times the gap between presses at a brisk three a second.
    static let pressFreshness: TimeInterval = 1

    /// Only the four arrows move focus by a press; select, menu and play/pause reaching the grid are not kept.
    nonisolated static func movesFocus(_ type: UIPress.PressType) -> Bool {
        switch type {
        case .upArrow, .downArrow, .leftArrow, .rightArrow: true
        default: false
        }
    }

    func pressBegan(_ timestamp: TimeInterval) {
        pendingPress = timestamp
        lastDown = timestamp
        arrowDown = true
    }

    /// #360 (D1): an arrow press came up (ended or cancelled).
    func pressEnded(_ timestamp: TimeInterval) {
        if arrowDown, let down = lastDown, guideVisible {
            let held = (timestamp - down) * 1000
            if held >= 0, held < 10_000 { stats.note(held, \.pressHeldMs) }
        }
        arrowDown = false
        lastUp = timestamp
    }

    /// A focus move began: it takes the stored press if that is fresh; either way the store is emptied, so a press is
    /// never paired with a later move.
    func focusBegan(at now: CFTimeInterval = CACurrentMediaTime()) {
        if guideVisible, let down = lastDown, now - down >= 0, now - down < Self.pressFreshness {
            stats.note((now - down) * 1000, \.moveAfterDownMs)
            if arrowDown { stats.movesWhileDown += 1 } else if let up = lastUp, up >= down { stats.note((now - up) * 1000, \.moveAfterUpMs) }
            lastDown = nil
        }
        if let press = pendingPress, now - press >= 0, now - press < Self.pressFreshness {
            movePress = press
        } else {
            movePress = nil
        }
        pendingPress = nil
    }

    /// Focus left the grid: no press goes with what comes next.
    func focusLeft() {
        pendingPress = nil
        movePress = nil
    }

    /// `shown`: when the move's frame is due on screen (`GuideFrameWait`), where its press is timed to as well.
    func focusLanded(ms: Double, at shown: CFTimeInterval = CACurrentMediaTime()) {
        var pressMs: Double?
        if let press = movePress {
            movePress = nil
            // UIPress.timestamp and CACurrentMediaTime share the system's uptime clock; anything odd is dropped.
            let value = (shown - press) * 1000
            if value >= 0 && value < 10_000 { pressMs = value }
        }
        guard guideVisible else { return }
        stats.landed(focusMs: ms, pressMs: pressMs)
        #if DEBUG
        if Self.testHooks {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(Self.focusNotification as CFString), nil, nil, true)
        }
        #endif
    }

    #if DEBUG
    private static var observingResets = false
    private static func observeResets() {
        guard !observingResets else { return }
        observingResets = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GuidePerfProbe.shared?.reset() } }
        }, resetNotification as CFString, nil, .deliverImmediately)
    }
    #endif
}

#if DEBUG
/// The probe's JSON as an (almost invisible) accessibility element (UI tests only). A plain UIView whose label is
/// computed when asked, so the probe never re-renders anything to publish its figures.
struct GuidePerfProbeLabel: UIViewRepresentable {
    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityIdentifier = "debug.guidePerf"
            isUserInteractionEnabled = false
            alpha = 0.02
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var accessibilityLabel: String? {
            get { GuidePerfProbe.shared?.json ?? "off" }
            set {}
        }
    }

    func makeUIView(context: Context) -> ProbeView { ProbeView(frame: CGRect(x: 0, y: 0, width: 8, height: 8)) }
    func updateUIView(_ view: ProbeView, context: Context) {}
}
#endif
