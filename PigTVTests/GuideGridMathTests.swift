import XCTest
@testable import PigTV

// A2.1: the UIKit guide grid's layout and navigation maths.
final class GuideGridMathTests: XCTestCase {
    // 2 h across 1440 pt: 0.2 pt per second, 360 pt per half hour.
    private let m = GuideGridMetrics(channelWidth: 176, rowHeight: 80, gap: 8, headerHeight: 56,
                                     timelineWidth: 1440, visibleDuration: 7200)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000) // a whole half hour

    private func at(_ minutes: Double) -> Date { origin.addingTimeInterval(minutes * 60) }
    private func programme(_ from: Double, _ to: Double, _ title: String = "P") -> GuideProgramme {
        GuideProgramme(title: title, description: nil,
                       startTime: at(from).timeIntervalSince1970 * 1000, endTime: at(to).timeIntervalSince1970 * 1000)
    }

    func testPositionsAndWidths() {
        XCTAssertEqual(m.pointsPerSecond, 0.2, accuracy: 1e-9)
        XCTAssertEqual(m.columnWidth, 360, accuracy: 1e-9)
        XCTAssertEqual(GuideGridMath.x(of: origin, origin: origin, metrics: m), 176)
        XCTAssertEqual(GuideGridMath.x(of: at(30), origin: origin, metrics: m), 176 + 360, accuracy: 1e-6)
        // Cells are inset by half a gap on each side: 30 min → 360 − 8 wide.
        let frame = GuideGridMath.programmeFrame(start: at(30), end: at(60), row: 2, origin: origin, metrics: m)
        XCTAssertEqual(frame.minX, 176 + 360 + 4, accuracy: 1e-6)
        XCTAssertEqual(frame.width, 352, accuracy: 1e-6)
        XCTAssertEqual(frame.minY, 160 + 4)
        XCTAssertEqual(frame.height, 72)
        // Content spans the whole loaded day; the last viewport shows its final two hours.
        XCTAssertEqual(GuideGridMath.contentWidth(duration: 86400, metrics: m), 176 + 17280, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.maximumOffsetX(duration: 86400, metrics: m), 22 * 3600 * 0.2, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.clampedOffsetX(-5, duration: 86400, metrics: m), 0)
    }

    func testViewportOffsetRoundTrip() {
        let x = GuideGridMath.offsetX(forViewport: at(90), origin: origin, metrics: m)
        XCTAssertEqual(x, 1080, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.viewport(forOffsetX: x, origin: origin, metrics: m).timeIntervalSince(at(90)), 0, accuracy: 1e-6)
    }

    func testStickyTileFollowsTheOffset() {
        let tile = GuideGridMath.tileFrame(row: 3, offsetX: 1234, metrics: m)
        XCTAssertEqual(tile.minX, 1238)
        XCTAssertEqual(tile.width, 168)
        XCTAssertEqual(tile.minY, 240 + 4)
    }

    func testCellsClipUnderTheChannelColumn() {
        let frame = GuideGridMath.programmeFrame(start: at(0), end: at(60), row: 0, origin: origin, metrics: m)
        // Unscrolled: whole, no clip.
        let whole = GuideGridMath.clipped(frame, offsetX: 0, metrics: m)
        XCTAssertEqual(whole?.leadingClip, 0)
        XCTAssertEqual(whole?.frame, frame)
        // Scrolled 30 min: the first half hides under the column (edge at offset + 176 + 4).
        let half = GuideGridMath.clipped(frame, offsetX: 360, metrics: m)
        XCTAssertEqual(half?.frame.minX ?? 0, 540, accuracy: 1e-6)
        XCTAssertEqual(half?.frame.maxX ?? 0, frame.maxX, accuracy: 1e-6)
        XCTAssertEqual(half?.leadingClip ?? 0, 360, accuracy: 1e-6)
        // Scrolled past its end: hidden.
        XCTAssertNil(GuideGridMath.clipped(frame, offsetX: 720, metrics: m))
    }

    func testHeaderMarksAndRows() {
        let marks = GuideGridMath.headerMarks(origin: at(10), duration: 3600)
        XCTAssertEqual(marks.first, origin)
        XCTAssertEqual(marks.last, at(90))
        // Labels line up with the cell edges below and slide with the offset.
        XCTAssertEqual(GuideGridMath.headerLabelX(mark: at(30), origin: origin, offsetX: 0, metrics: m), 360, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.headerLabelX(mark: at(30), origin: origin, offsetX: 360, metrics: m), 0, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.rows(in: 0, 80 * 3 - 1, count: 100, metrics: m), 0..<3)
        XCTAssertEqual(GuideGridMath.rows(in: 800, 880, count: 100, metrics: m), 10..<12)
        XCTAssertEqual(GuideGridMath.rows(in: 0, 1000, count: 2, metrics: m), 0..<2)
        XCTAssertEqual(GuideGridMath.rows(in: 0, 1000, count: 0, metrics: m), 0..<0)
    }

    func testVisibleProgrammeIndices() {
        let list = [programme(0, 30), programme(30, 90), programme(90, 120), programme(120, 240)]
        XCTAssertEqual(GuideGridMath.indices(of: list, overlapping: at(45), at(100)), [1, 2])
        XCTAssertEqual(GuideGridMath.indices(of: list, overlapping: at(0), at(30)), [0])
        XCTAssertEqual(GuideGridMath.indices(of: list, overlapping: at(300), at(400)), [])
    }

    func testColumnSnappingAndBaseline() {
        XCTAssertEqual(GuideGridMath.snapped(at(14)), origin)
        XCTAssertEqual(GuideGridMath.snapped(at(16)), at(30))
        XCTAssertEqual(GuideGridMath.liveBaseline(now: at(59)), at(30))
        XCTAssertEqual(GuideGridMath.easeInOut(0), 0)
        XCTAssertEqual(GuideGridMath.easeInOut(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GuideGridMath.easeInOut(1), 1)
    }

    func testHorizontalTargetRevealsByWholeColumns() {
        let now = at(10)
        let viewport = origin // two hours: 0…120
        // Fully inside: stays.
        XCTAssertEqual(GuideGridMath.horizontalTarget(for: programme(60, 90), viewport: viewport, now: now), viewport)
        // Starting in the last half column: brought a whole column inside.
        XCTAssertEqual(GuideGridMath.horizontalTarget(for: programme(110, 150), viewport: viewport, now: now), at(30))
        // Beyond the right edge: its start column ends a whole column inside the edge.
        XCTAssertEqual(GuideGridMath.horizontalTarget(for: programme(185, 200), viewport: viewport, now: now), at(120))
        // A future programme clipped on the left brings its start column in.
        XCTAssertEqual(GuideGridMath.horizontalTarget(for: programme(95, 200), viewport: at(120), now: now), at(90))
        // A live one clipped on the left returns to the live baseline.
        XCTAssertEqual(GuideGridMath.horizontalTarget(for: programme(0, 200), viewport: at(120), now: now), origin)
    }

    func testVerticalTargetKeepsTheAnchor() {
        let now = at(10)
        let row = [programme(-30, 20), programme(20, 60), programme(60, 75), programme(90, 150)]
        // The programme under the anchor.
        XCTAssertEqual(GuideGridMath.verticalTarget(in: row, anchor: at(65), now: now)?.startTime, row[2].startTime)
        // An anchor in the past counts as now (never a finished programme).
        XCTAssertEqual(GuideGridMath.verticalTarget(in: row, anchor: at(0), now: now)?.startTime, row[0].startTime)
        // In a gap: the nearest unfinished programme.
        XCTAssertEqual(GuideGridMath.verticalTarget(in: row, anchor: at(85), now: now)?.startTime, row[3].startTime)
        XCTAssertEqual(GuideGridMath.verticalTarget(in: row, anchor: at(77), now: now)?.startTime, row[2].startTime)
        // Nothing unfinished: the channel tile.
        XCTAssertNil(GuideGridMath.verticalTarget(in: [programme(-60, 0)], anchor: at(30), now: now))
        XCTAssertEqual(GuideGridMath.anchor(for: row[0], viewport: origin), origin)
        XCTAssertEqual(GuideGridMath.anchor(for: row[3], viewport: origin), at(90))
    }

    func testLeftStepAtAndAheadOfTheBaseline() {
        let now = at(10)
        let row = [programme(-30, 20), programme(20, 60), programme(60, 150), programme(150, 200)]
        // At the live baseline Left goes to the tile.
        XCTAssertEqual(GuideGridMath.leftStep(from: row[0].startTime, in: row, viewport: origin, now: now), .tile)
        // Ahead of it: one column back onto the previous unfinished programme…
        XCTAssertEqual(GuideGridMath.leftStep(from: row[3].startTime, in: row, viewport: at(180), now: now),
                       .move(viewport: at(60), start: row[2].startTime))
        XCTAssertEqual(GuideGridMath.leftStep(from: row[2].startTime, in: row, viewport: at(90), now: now),
                       .move(viewport: at(0), start: row[1].startTime))
        // …or back to live when only the live/finished one lies behind.
        XCTAssertEqual(GuideGridMath.leftStep(from: row[1].startTime, in: row, viewport: at(30), now: now),
                       .move(viewport: origin, start: row[0].startTime))
    }

    func testRowFilter() {
        let sports = Category(rawID: "sports", sourceId: 1, name: "Sports", channelCount: 2)
        let a = GuideChannel(rawID: "a", sourceId: 1, name: "Alpha Sport", logo: nil, category: "sports", programmes: [], stableId: "x")
        let b = GuideChannel(rawID: "b", sourceId: 1, name: "Beta News", logo: nil, category: "news", programmes: [])
        let a2 = GuideChannel(rawID: "a2", sourceId: 1, name: "Alpha Sport HD", logo: nil, category: "sports", programmes: [], stableId: "x")
        let guide = [a, b, a2]
        XCTAssertEqual(GuideRowFilter.rows(from: guide, category: sports, search: "", onlyFavourites: false, favouriteKeys: []).map(\.id),
                       ["1:a", "1:a2"])
        XCTAssertEqual(GuideRowFilter.rows(from: guide, category: nil, search: "beta", onlyFavourites: false, favouriteKeys: []).map(\.id),
                       ["1:b"])
        // A cross-listed favourite (same stable identity) is shown once.
        XCTAssertEqual(GuideRowFilter.rows(from: guide, category: nil, search: "", onlyFavourites: true,
                                           favouriteKeys: ["1:s:x"]).map(\.id), ["1:a"])
    }

    func testClipAppearanceChangesOnlyWhenTheDrawingDoes() {
        XCTAssertEqual(GuideGridMath.clipAppearance(leadingClip: 0, visibleWidth: 352), .init())
        XCTAssertEqual(GuideGridMath.clipAppearance(leadingClip: 0.3, visibleWidth: 100), .init())
        // Clipped but still wide: the same appearance at every clipped amount,
        // so sliding does not re-render the cell.
        let wide = GuideGridMath.clipAppearance(leadingClip: 40, visibleWidth: 312)
        XCTAssertEqual(wide, .init(clipped: true, titleShift: 0))
        XCTAssertEqual(GuideGridMath.clipAppearance(leadingClip: 150, visibleWidth: 202), wide)
        // Narrower than the title: it slides by whole points.
        XCTAssertEqual(GuideGridMath.clipAppearance(leadingClip: 252, visibleWidth: 100.4).titleShift, -60)
        XCTAssertEqual(GuideGridMath.clipAppearance(leadingClip: 252, visibleWidth: 100.2),
                       GuideGridMath.clipAppearance(leadingClip: 252.2, visibleWidth: 100))
    }

    // Build 29 (iPad free scrolling): a pan's deceleration ends on the
    // nearest half hour, inside the loaded content, also when the loaded
    // window does not start on a half hour.
    func testFreeScrollSnapsToTheNearestHalfHour() {
        let day: TimeInterval = 86400
        XCTAssertEqual(GuideGridMath.snappedOffsetX(500, origin: origin, duration: day, metrics: m), 360, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.snappedOffsetX(600, origin: origin, duration: day, metrics: m), 720, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.snappedOffsetX(-250, origin: origin, duration: day, metrics: m), 0, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.snappedOffsetX(99_999, origin: origin, duration: day, metrics: m),
                       GuideGridMath.maximumOffsetX(duration: day, metrics: m), accuracy: 1e-6)
        // Loaded from 10 past: half hours sit at 240, 600, … (x = 0 is 10 past).
        let offOrigin = at(10)
        XCTAssertEqual(GuideGridMath.snappedOffsetX(0, origin: offOrigin, duration: day, metrics: m), 240, accuracy: 1e-6,
                       "the nearest half hour is before the content; the next one inside it")
        XCTAssertEqual(GuideGridMath.snappedOffsetX(300, origin: offOrigin, duration: day, metrics: m), 240, accuracy: 1e-6)
        XCTAssertEqual(GuideGridMath.snappedOffsetX(450, origin: offOrigin, duration: day, metrics: m), 600, accuracy: 1e-6)
        // Whatever the proposal, the result is a whole half hour in time.
        for proposed in stride(from: CGFloat(0), through: 16_000, by: 137) {
            let x = GuideGridMath.snappedOffsetX(proposed, origin: offOrigin, duration: day, metrics: m)
            let time = GuideGridMath.viewport(forOffsetX: x, origin: offOrigin, metrics: m)
            XCTAssertEqual(time, GuideGridMath.snapped(time), "\(proposed)")
            XCTAssertLessThanOrEqual(x, GuideGridMath.maximumOffsetX(duration: day, metrics: m) + 1e-6)
        }
    }
}
