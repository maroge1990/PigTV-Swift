import Foundation
import QuartzCore
import SwiftUI
import UIKit

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
    var applies = 0
    var applyMs: Double = 0
    var firstScreenMs: Double?
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

    private static func append(_ value: Double, to list: inout [Double]) {
        list.append(value)
        if list.count > sampleCap { list.removeFirst(list.count - sampleCap) }
    }

    /// Zero for the next window (the reset count goes on, so a test can see its reset arrive; the rows and the focused row
    /// carry over).
    mutating func reset() {
        self = GuidePerfStats(resets: resets + 1, rowsStart: rowsEnd, rowsEnd: rowsEnd, focusRow: focusRow)
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
            "cellConfigs": cellConfigurations, "applies": applies, "applyMs": Self.rounded(applyMs),
            "resets": resets, "windowMs": Self.rounded(windowMs),
        ]
        if let rowsStart { object["rowsStart"] = rowsStart }
        if let rowsEnd { object["rowsEnd"] = rowsEnd }
        if let focusRow { object["focusRow"] = focusRow }
        if let firstScreenMs { object["firstScreenMs"] = Self.rounded(firstScreenMs) }
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
    private var active: Bool
    private var observers: [NSObjectProtocol] = []

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
        #if DEBUG
        if Self.testHooks { Self.observeResets() }
        #endif
    }

    /// Display link and observers gone (switching off).
    func stop() {
        link?.invalidate()
        link = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
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
        stats.frame(gapMs: lastFrame > 0 ? (now - lastFrame) * 1000 : nil)
        lastFrame = now
    }

    func reset() {
        stats.reset()
        lastFrame = 0
        pendingPress = nil
        movePress = nil
        windowStart = CACurrentMediaTime()
    }

    /// Settings' line, read when Settings is shown.
    var readout: String { stats.readout(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") }
    var json: String { stats.json(windowMs: (CACurrentMediaTime() - windowStart) * 1000) }

    // Hooks (GuidePerf.swift, GuideGridSupport.swift). Only while the Guide is on screen.
    func applied(ms: Double, rows: Int) {
        stats.rowsEnd = rows
        guard guideVisible else { return }
        stats.applies += 1
        stats.applyMs += ms
    }
    func focusRow(_ row: Int) { if guideVisible { stats.focusRow = row } }
    func cellConfigured() { if guideVisible { stats.cellConfigurations += 1 } }
    func bodyEvaluated() { if guideVisible { stats.bodyEvaluations += 1 } }
    func focusSuperseded() { if guideVisible { stats.focusSuperseded += 1 } }
    func firstScreen(ms: Double) { if stats.firstScreenMs == nil { stats.firstScreenMs = ms } }

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

    func pressBegan(_ timestamp: TimeInterval) { pendingPress = timestamp }

    /// A focus move began: it takes the stored press if that is fresh; either way the store is emptied, so a press is
    /// never paired with a later move.
    func focusBegan(at now: CFTimeInterval = CACurrentMediaTime()) {
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
