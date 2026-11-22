import XCTest

#if os(tvOS)
/// #362 (speed programme, batch 1): how the TV Guide responds on a production-sized guide (1,250 channels, a day of
/// programmes with real-length descriptions, a logo each, 40 categories: PIGTV_UI_TEST_GUIDE_SHAPE=production), read
/// from the app's probe (PIGTV_UI_TEST_GUIDEPROBE=1, `debug.guidePerf`, GuidePerfProbe.swift). Each scenario prints one
/// line `GUIDE-SCROLL {"scenario":…, <the probe's JSON>, …}` and attaches it. Only in `sh Tools/test.sh perf`; the cloud
/// plan skips it.
///
/// Budgets come from the test environment as PIGTV_GUIDEPERF_* (Tools/test.sh and Tools/mac-gate.sh pass them on with
/// the TEST_RUNNER_ prefix): FOCUS_MS (the worst focus move in a press scenario), GAP_MS (the longest frame gap in any
/// scenario), FIRST_MS (the first screen), BODY_PER_PRESS (body evaluations per press), CELLS_PER_VERTICAL_PRESS (cell
/// configurations per up/down press), LAYOUT_PER_VERTICAL_PRESS (the grid layout's element queries per up/down press), LOGO_LATE (logos drawn a frame late in a vertical
/// or held scenario), CELLS_AT_TICK (cell configurations in the idle window, the 30 s tick), BODY_AT_TICK (body evaluations there), APPLY_MS
/// (all applies' ms in a scenario). Unset, a scenario only records, except where a fix has earned a count budget (#360,
/// `budget(_:_:)` in `record`). Absent probe figures always fail.
final class GuidePerfUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        GuideProbeLanding.observe()
    }

    // MARK: The scenarios

    /// (a) to (f) on one launch, in order: the first screen, 40 single presses down at about three a second (each waits
    /// for its move to land), 40 up, 10 right (later in time), a held scroll down of about 100 rows, then 35 s idle so
    /// the Guide's 30 s clock tick falls inside the window.
    @MainActor
    func testGuideScrollScenarios() throws {
        launch()
        let first = try waitForFirstScreen()
        record("a-first-screen", first, presses: 0)
        try enterGrid()

        reset()
        record("b-down-40", try presses(.down, 40), presses: 40, vertical: true)
        reset()
        record("c-up-40", try presses(.up, 40), presses: 40, vertical: true)
        reset()
        record("d-right-10", try presses(.right, 10), presses: 10)
        // Where focus is before the held scroll (read before its window: a read stalls the app), to measure rows moved.
        let startRow = number(try probe(), "focusRow")
        reset()
        var held = try heldScroll(rows: 100)
        if let startRow, let endRow = number(held, "focusRow") { held["rowsMoved"] = Int(endRow - startRow) }
        record("e-held-down-100", held, presses: 0, heldMinimum: 50)
        reset()
        Thread.sleep(forTimeInterval: 35)
        record("f-idle-35s", try probe(), presses: 0, tick: true)
    }

    /// (g) The guide arrives through the app's own paging (3 pages of 500, PIGTV_UI_TEST_GUIDE_PAGED=1, 7 s apart) while
    /// the remote presses down: as soon as the first page's rows are on screen they take focus, then 45 presses at three a
    /// second (about 15 s; the setup before them takes about 5 s), so pages 2 and 3 land inside the window. Fewer than 2 applies inside it is a fault of this
    /// test's timing, not of the app, and is reported as such.
    @MainActor
    func testPagedArrivalWhilePressingDown() throws {
        launch(paged: true)
        let first = try waitForFirstScreen()
        // No accessibility query from here to the end of the window (a query is slow and stalls the app): the reset is
        // only posted, and the grid is entered by pressing Down until the app reports a focus move inside it.
        GuideProbeLanding.postReset()
        GuideProbeLanding.spin(0.3)
        var entry = 0
        let before = GuideProbeLanding.count
        while GuideProbeLanding.count == before && entry < 8 {
            XCUIRemote.shared.press(.down)
            entry += 1
            _ = GuideProbeLanding.wait(for: before + 1, timeout: 1)
        }
        XCTAssertGreaterThan(GuideProbeLanding.count, before, "no grid cell took focus")
        // Review of 374: the entry move is setup, not one of the measured presses: the window starts after it (a posted
        // reset, no query). Pages 2 and 3 are still to come (7 s and 14 s after the first).
        GuideProbeLanding.postReset()
        GuideProbeLanding.spin(0.3)
        var json = try presses(.down, 45)
        json["entryPresses"] = entry
        record("g0-paged-first-screen", first, presses: 0)
        record("g-paged-down-45", json, presses: 45, vertical: true)
        let applies = number(json, "applies") ?? 0
        XCTAssertGreaterThanOrEqual(applies, 2, "Test setup: pages missed the window (\(Int(applies)) applies inside it, rows "
            + "\(json["rowsStart"] ?? "?") → \(json["rowsEnd"] ?? "?")); not a failure of the app.")
    }

    /// (b) again under `measure(metrics:)` with `XCTOSSignpostMetric` for the GuideFocusMove signpost (three runs of 40
    /// presses down). The signpost interval can only end at the frame callback, up to a frame before that frame is due on
    /// screen, so Xcode's figure is callback timing; each run also prints the probe's own figures for the same presses
    /// (`GUIDE-SIGNPOST`), which are the frame-due timing every other scenario reports (and each signpost's end message
    /// carries as `frameDueMs`). Compare those, not Xcode's, with the GUIDE-SCROLL lines.
    @MainActor
    func testFocusMoveSignpostMetric() throws {
        launch()
        _ = try waitForFirstScreen()
        try enterGrid()
        let metric = XCTOSSignpostMetric(subsystem: "au.markrogers.PigTV", category: "Responsiveness", name: "GuideFocusMove")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        var failure: Error?
        var run = 0
        measure(metrics: [metric], options: options) {
            run += 1
            GuideProbeLanding.postReset()
            GuideProbeLanding.spin(0.3)
            do {
                let json = try presses(.down, 40)
                func ms(_ key: String) -> String { number(json, key).map { String(format: "%.1f", $0) } ?? "-" }
                print("GUIDE-SIGNPOST run \(run): probe (frame-due timing) focusMedianMs \(ms("focusMedianMs")) "
                    + "focusMaxMs \(ms("focusMaxMs")) over \(json["focusMoves"] ?? "-") moves; Xcode's GuideFocusMove "
                    + "figure is callback timing, up to a frame shorter")
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    // MARK: Driving the app

    @MainActor
    private func launch(paged: Bool = false) {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launchEnvironment["PIGTV_UI_TEST_GUIDE_SHAPE"] = "production"
        app.launchEnvironment["PIGTV_UI_TEST_CHANNELS"] = "1250"
        app.launchEnvironment["PIGTV_UI_TEST_GUIDEPROBE"] = "1"
        // Review of 378: the comparison run (PIGTV_GUIDEPERF_OLD_LAYOUT=1): the grid redoes its whole layout on every scroll
        // step, as before Apple 378 (set it with PIGTV_GUIDEPERF_LAYOUT_PER_VERTICAL_PRESS high, or that budget fails).
        if ProcessInfo.processInfo.environment["PIGTV_GUIDEPERF_OLD_LAYOUT"] == "1" {
            app.launchEnvironment["PIGTV_UI_TEST_GUIDE_LAYOUT_377"] = "1"
        }
        if paged {
            app.launchEnvironment["PIGTV_UI_TEST_GUIDE_PAGED"] = "1"
            // Pages 2 and 3 arrive about 7 s and 14 s after the first (which is not delayed): inside the presses that follow.
            app.launchEnvironment["PIGTV_UI_TEST_GUIDE_PAGE_DELAY_MS"] = "7000"
        }
        app.launch()
        self.app = app
    }

    /// The probe's figures (fails when the app has no probe: an app without the #362 instrumentation).
    private func probe() throws -> [String: Any] {
        let element = app.descendants(matching: .any)["debug.guidePerf"]
        guard element.waitForExistence(timeout: 30) else {
            XCTFail("The Guide probe (debug.guidePerf) is not on screen: this app has no #362 instrumentation.")
            throw ProbeError.absent
        }
        let label = element.label
        guard let data = label.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["frames"] != nil else {
            XCTFail("The Guide probe's label is not its JSON: \(label)")
            throw ProbeError.unreadable
        }
        return json
    }

    private enum ProbeError: Error { case absent, unreadable, noFirstScreen, notInGrid }

    private func number(_ json: [String: Any], _ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }

    private func waitForFirstScreen() throws -> [String: Any] {
        var json = try probe()
        let deadline = Date().addingTimeInterval(60)
        while number(json, "firstScreenMs") == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            json = try probe()
        }
        guard number(json, "firstScreenMs") != nil else {
            XCTFail("The Guide never reported its first screen with rows: \(json)")
            throw ProbeError.noFirstScreen
        }
        return json
    }

    /// Down until a grid cell has focus (the Guide opens with focus above the grid).
    private func enterGrid() throws {
        let grid = app.collectionViews["guide.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "guide grid not shown")
        let focusedCell = grid.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<8 where !focusedCell.exists {
            XCUIRemote.shared.press(.down)
        }
        guard focusedCell.exists else { XCTFail("no grid cell took focus"); throw ProbeError.notInGrid }
    }

    /// Zero the probe (a Darwin notification) and wait until it says so, then zero it once more without reading it:
    /// a read is an accessibility snapshot that stalls the app's main thread, and must not fall inside the window.
    private func reset() {
        let before = (try? probe()).flatMap { number($0, "resets") } ?? 0
        GuideProbeLanding.postReset()
        _ = waitUntil(5) { ((try? self.probe()).flatMap { self.number($0, "resets") } ?? 0) > before }
        GuideProbeLanding.spin(0.5)
        GuideProbeLanding.postReset()
        GuideProbeLanding.spin(0.3)
    }

    /// `count` single presses about a third of a second apart, each after the previous one's move has landed (the app's
    /// focus notification, so the wait costs the app nothing; the probe's count if notifications never arrive).
    /// `landedPresses` (review of 374): the presses whose move landed, at most one each, so extra focus events (a
    /// redirected move, a restore) never stand in for a press that moved nothing. Review of 379: each press needs a landing
    /// of its own, counted from just before it: the notifications' count, or (once they have stopped) the probe's
    /// `focusMoves` read just before the press, which must rise after it. Surplus events from earlier presses never count.
    /// The press during which the notifications stopped has no count from before it, so it is not counted as landed.
    private func presses(_ button: XCUIRemote.Button, _ count: Int) throws -> [String: Any] {
        var landedBy = "notification"
        var landed = 0
        func focusMoves() -> Double? { (try? self.probe()).flatMap { self.number($0, "focusMoves") } }
        for _ in 0..<count {
            let started = Date()
            let target = GuideProbeLanding.count + 1
            let before = landedBy == "probe" ? focusMoves() : nil
            XCUIRemote.shared.press(button)
            if landedBy == "notification" {
                if GuideProbeLanding.wait(for: target, timeout: 3) { landed += 1 } else { landedBy = "probe" }
            } else if let before, waitUntil(5, { (focusMoves() ?? 0) > before }) {
                landed += 1
            }
            let rest = 1.0 / 3 - Date().timeIntervalSince(started)
            if rest > 0 { GuideProbeLanding.spin(rest) }
        }
        GuideProbeLanding.spin(0.5) // the last move's frame
        var json = try probe()
        json["landedBy"] = landedBy
        json["landedPresses"] = landed
        return json
    }

    /// Hold Down in 2 s stretches until about `rows` focus moves have landed (at most 8 stretches). Counted from the
    /// app's notifications, so nothing queries the app inside the window.
    private func heldScroll(rows: Int) throws -> [String: Any] {
        let start = GuideProbeLanding.count
        var holds = 0
        while GuideProbeLanding.count - start < rows && holds < 8 {
            XCUIRemote.shared.press(.down, forDuration: 2)
            holds += 1
            GuideProbeLanding.spin(0.5)
        }
        var json = try probe()
        json["holds"] = holds
        return json
    }

    // MARK: The record

    /// At least this share of a single-press scenario's presses must move focus, or its figures say nothing.
    static let landedShare = 0.9

    /// Prints and attaches `GUIDE-SCROLL {"scenario":…,…}` (`presses` sent, `focusMoves` landed, and per-press counts:
    /// per move that landed), then checks the presses landed (single presses: at least 90 % moved focus; a held scroll:
    /// focus moved at least `heldMinimum` rows) and only then applies any budget set.
    private func record(_ scenario: String, _ json: [String: Any], presses: Int, vertical: Bool = false, tick: Bool = false,
                        heldMinimum: Int? = nil) {
        var json = json
        let moves = number(json, "focusMoves") ?? 0
        if presses > 0 {
            json["presses"] = presses
            for key in ["bodyEvals", "cellConfigs", "layoutPrepares", "layoutPrepareRuns", "layoutQueries", "layoutMs",
                        "logoFetches", "applies"] where moves > 0 {
                if let value = number(json, key) { json[key + "PerPress"] = (value / moves * 10).rounded() / 10 }
            }
        }
        json.removeValue(forKey: "scenario")
        func tidy(_ value: Any) -> Any {
            if let list = value as? [Any] { return list.map(tidy) }
            guard let number = value as? NSNumber, CFNumberIsFloatType(number) else { return value }
            return Decimal(string: String(format: "%.1f", number.doubleValue)) ?? number
        }
        json = json.mapValues(tidy)
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let line = "GUIDE-SCROLL {\"scenario\":\"\(scenario)\"," + body.dropFirst()
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "guide-scroll-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThan(number(json, "frames") ?? 0, 0, "\(scenario): the probe counted no frames")
        if presses > 0 {
            // Review of 374: presses that landed, at most one each (not focus events, which a setup move or a redirect adds).
            let landed = min(moves, number(json, "landedPresses") ?? 0)
            let needed = (Double(presses) * Self.landedShare).rounded(.up)
            guard landed >= needed else {
                XCTFail("\(scenario): \(Int(landed)) of \(presses) presses moved focus (at least \(Int(needed)) must); no budget applied")
                return
            }
        }
        if let heldMinimum {
            // Review of 374: forward progress in rows (the focused row's index before and after), not focus events.
            let rows = number(json, "rowsMoved") ?? 0
            guard rows >= Double(heldMinimum) else {
                XCTFail("\(scenario): the held scroll moved focus \(Int(rows)) rows down (at least \(heldMinimum) must); no budget applied")
                return
            }
        }
        let env = ProcessInfo.processInfo.environment
        /// A set budget, else the count budget the fixes have earned (#360): counts are the machine's, not the clock's,
        /// so these hold on any Mac; nil: record only.
        func budget(_ name: String, _ earned: Double? = nil) -> Double? { env["PIGTV_GUIDEPERF_" + name].flatMap(Double.init) ?? earned }
        if presses > 0, let budget = env["PIGTV_GUIDEPERF_FOCUS_MS"].flatMap(Double.init), let worst = number(json, "focusMaxMs") {
            XCTAssertLessThanOrEqual(worst, budget, "\(scenario): a focus move took \(worst) ms (budget \(budget) ms)")
        }
        if let budget = env["PIGTV_GUIDEPERF_GAP_MS"].flatMap(Double.init), let gap = number(json, "maxGapMs") {
            XCTAssertLessThanOrEqual(gap, budget, "\(scenario): a frame gap of \(gap) ms (budget \(budget) ms)")
        }
        if let budget = env["PIGTV_GUIDEPERF_FIRST_MS"].flatMap(Double.init), let firstScreen = number(json, "firstScreenMs") {
            XCTAssertLessThanOrEqual(firstScreen, budget, "\(scenario): the first screen took \(firstScreen) ms (budget \(budget) ms)")
        }
        // #360 (G1, Apple 376): a focus move no longer re-evaluates GuideView.body (1.0 per press before). Not earned in
        // the paged scenario, whose arriving pages re-evaluate it by design (a later batch's work).
        let paged = scenario.hasPrefix("g")
        let sideways = presses > 0 && !vertical && !paged
        if presses > 0, !sideways, let budget = budget("BODY_PER_PRESS", paged ? nil : 0.05), let value = number(json, "bodyEvalsPerPress") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) body evaluations per press (budget \(budget))")
        }
        // Review of 378: a sideways scenario moves the viewport through time, and a new day redraws the header's date (one
        // body evaluation each, `dayChanges`); nothing else may re-evaluate the body. Set: the per-press budget instead.
        if sideways, let value = number(json, "bodyEvals") {
            if let budget = env["PIGTV_GUIDEPERF_BODY_PER_PRESS"].flatMap(Double.init), let perPress = number(json, "bodyEvalsPerPress") {
                XCTAssertLessThanOrEqual(perPress, budget, "\(scenario): \(perPress) body evaluations per press (budget \(budget))")
            } else {
                let days = number(json, "dayChanges") ?? 0
                XCTAssertLessThanOrEqual(value, days, "\(scenario): \(Int(value)) body evaluations, \(Int(days)) day changes crossed")
            }
        }
        if vertical, let budget = env["PIGTV_GUIDEPERF_CELLS_PER_VERTICAL_PRESS"].flatMap(Double.init),
           let value = number(json, "cellConfigsPerPress") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) cell configurations per press (budget \(budget))")
        }
        // #360 (G8, Apple 378; counted as real work since the review of 378): a vertical move no longer has the grid layout
        // rebuild every visible element's attributes on each scroll frame (`layoutQueries`, its `layoutAttributesForElements`
        // calls: 19.8 per press down with the old layout, 2.6 after), only for rows coming on screen. Not earned in the
        // paged scenario, whose arriving pages insert rows (a full layout by design).
        if vertical, let budget = budget("LAYOUT_PER_VERTICAL_PRESS", paged ? nil : 5), let value = number(json, "layoutQueriesPerPress") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) layout queries per press (budget \(budget))")
        }
        // #360 (G4, Apple 379): a channel logo already in memory is drawn on its tile's first frame, never by the view's task a
        // frame later (c-up-40 drew 36 that way, e-held-down-100 199, before).
        if vertical || heldMinimum != nil, let budget = budget("LOGO_LATE", 0), let value = number(json, "logoLateHits") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) logos drawn a frame late (budget \(budget))")
        }
        // #360 (G5, Apple 377): the 30 s tick no longer re-evaluates GuideView.body (1 per tick before).
        if tick, let budget = budget("BODY_AT_TICK", 0), let value = number(json, "bodyEvals") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) body evaluations in the idle window (budget \(budget))")
        }
        // #360 (G5, Apple 377): only cells whose drawing changed are configured again at the tick (20 in this window before:
        // every visible cell). After d-right-10 the grid shows programmes hours ahead, none on air, so none changes: 0.
        if tick, let budget = budget("CELLS_AT_TICK", 0), let value = number(json, "cellConfigs") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): \(value) cell configurations in the idle window (budget \(budget))")
        }
        if let budget = env["PIGTV_GUIDEPERF_APPLY_MS"].flatMap(Double.init), let value = number(json, "applyMs") {
            XCTAssertLessThanOrEqual(value, budget, "\(scenario): applies took \(value) ms in all (budget \(budget) ms)")
        }
    }
}

/// The app's Darwin notifications (GuidePerfProbe): each focus move that reached its frame, and the reset the test asks for.
enum GuideProbeLanding {
    private static let lock = NSLock()
    private static var landed = 0
    private static var observing = false

    static var count: Int { lock.lock(); defer { lock.unlock() }; return landed }

    static func observe() {
        lock.lock(); defer { lock.unlock() }
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            GuideProbeLanding.lock.lock()
            GuideProbeLanding.landed += 1
            GuideProbeLanding.lock.unlock()
        }, "au.markrogers.PigTV.guideProbe.focus" as CFString, nil, .deliverImmediately)
    }

    static func postReset() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("au.markrogers.PigTV.guideProbe.reset" as CFString), nil, nil, true)
    }

    /// Runs the run loop (where Darwin notifications are delivered) for `seconds`.
    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
    }

    /// True once `count` reaches `target` within `timeout`.
    static func wait(for target: Int, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while count < target && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return count >= target
    }
}
#endif
