import CoreGraphics
import Foundation

// A2.1: the pure maths behind the UIKit guide grid (GuideGridLayout /
// GuideGridView), kept free of UIKit so it is unit-tested directly.
//
// Coordinates: the grid's content is one very wide sheet. The channel column
// occupies the first `channelWidth` points of the *visible* area and is pinned
// (sticky); time runs from `origin` (the loaded window's start) at content x
// `channelWidth`. Scrolling horizontally is contentOffset.x, so the time shown
// at the left edge of the timeline (the "viewport") is
// `origin + contentOffset.x / pointsPerSecond`.

nonisolated struct GuideGridMetrics: Equatable, Sendable {
    // Same numbers as GuideView (R16): row pitch 80, one 8 pt gap everywhere.
    var channelWidth: CGFloat = 176
    var rowHeight: CGFloat = 80
    var gap: CGFloat = 8
    // Time header above the rows (a separate view that follows the
    // horizontal offset; the rows scroll beneath it, never under it).
    #if os(tvOS)
    var headerHeight: CGFloat = 56
    #else
    var headerHeight: CGFloat = 34
    #endif
    // Visible width of the timeline (the collection view width minus the
    // channel column); `visibleDuration` of programme time fits in it.
    var timelineWidth: CGFloat = 1696
    var visibleDuration: TimeInterval = GuideNavigation.visibleDuration

    var inset: CGFloat { gap / 2 }
    var pointsPerSecond: CGFloat { timelineWidth / CGFloat(visibleDuration) }
    var columnWidth: CGFloat { CGFloat(GuideNavigation.step) * pointsPerSecond }
}

nonisolated enum GuideGridMath {
    // MARK: Positions

    /// Content x of a time (the timeline starts at `channelWidth`).
    static func x(of time: Date, origin: Date, metrics m: GuideGridMetrics) -> CGFloat {
        m.channelWidth + CGFloat(time.timeIntervalSince(origin)) * m.pointsPerSecond
    }

    /// contentOffset.x that puts `viewport` at the left edge of the timeline.
    static func offsetX(forViewport viewport: Date, origin: Date, metrics m: GuideGridMetrics) -> CGFloat {
        CGFloat(viewport.timeIntervalSince(origin)) * m.pointsPerSecond
    }

    /// Time at the left edge of the timeline for a contentOffset.x.
    static func viewport(forOffsetX offsetX: CGFloat, origin: Date, metrics m: GuideGridMetrics) -> Date {
        guard m.pointsPerSecond > 0 else { return origin }
        return origin.addingTimeInterval(TimeInterval(offsetX / m.pointsPerSecond))
    }

    /// Total content width for `duration` seconds of loaded programme data.
    static func contentWidth(duration: TimeInterval, metrics m: GuideGridMetrics) -> CGFloat {
        m.channelWidth + CGFloat(duration) * m.pointsPerSecond
    }

    /// Largest viewport the content can show (the last two hours end at the
    /// content end).
    static func maximumOffsetX(duration: TimeInterval, metrics m: GuideGridMetrics) -> CGFloat {
        max(0, CGFloat(duration - m.visibleDuration) * m.pointsPerSecond)
    }

    static func clampedOffsetX(_ x: CGFloat, duration: TimeInterval, metrics m: GuideGridMetrics) -> CGFloat {
        min(max(0, x), maximumOffsetX(duration: duration, metrics: m))
    }

    /// Build 29 (iPad free scrolling): where a pan's deceleration should end,
    /// the nearest whole half hour to the proposed offset, within the loaded
    /// content. Half hours are clock times, so this holds when `origin` (the
    /// loaded window's start) is not itself on a half hour.
    static func snappedOffsetX(_ proposed: CGFloat, origin: Date, duration: TimeInterval,
                               metrics m: GuideGridMetrics) -> CGFloat {
        let clamped = clampedOffsetX(proposed, duration: duration, metrics: m)
        let x = offsetX(forViewport: snapped(viewport(forOffsetX: clamped, origin: origin, metrics: m)), origin: origin, metrics: m)
        if x <= maximumOffsetX(duration: duration, metrics: m) + 0.5, x >= -0.5 {
            return clampedOffsetX(x, duration: duration, metrics: m)
        }
        // The nearest half hour lies outside the loaded content: the one
        // inside it, a column the other way.
        let step = CGFloat(GuideNavigation.step) * m.pointsPerSecond
        return clampedOffsetX(x < 0 ? x + step : x - step, duration: duration, metrics: m)
    }

    static func rowMinY(_ row: Int, metrics m: GuideGridMetrics) -> CGFloat {
        CGFloat(row) * m.rowHeight
    }

    /// Unclipped content frame of a programme cell: inset by half a gap on
    /// every side, like GuideView's cells.
    static func programmeFrame(start: Date, end: Date, row: Int, origin: Date,
                               metrics m: GuideGridMetrics) -> CGRect {
        let minX = x(of: start, origin: origin, metrics: m) + m.inset
        let width = max(1, CGFloat(end.timeIntervalSince(start)) * m.pointsPerSecond - m.gap)
        return CGRect(x: minX, y: rowMinY(row, metrics: m) + m.inset, width: width, height: m.rowHeight - m.gap)
    }

    /// Left edge of the visible timeline in content coordinates: cells are
    /// clipped here so they slide under the pinned channel column with the
    /// same 8 pt gap as everywhere else.
    static func clipX(offsetX: CGFloat, metrics m: GuideGridMetrics) -> CGFloat {
        offsetX + m.channelWidth + m.inset
    }

    /// A programme frame clipped at the timeline's left edge, with the amount
    /// clipped (the cell uses it to keep its title on screen, like
    /// GuideView's `hiddenLeading`). Nil when the cell is wholly hidden.
    static func clipped(_ frame: CGRect, offsetX: CGFloat, metrics m: GuideGridMetrics)
        -> (frame: CGRect, leadingClip: CGFloat)? {
        let edge = clipX(offsetX: offsetX, metrics: m)
        guard frame.maxX > edge + 0.5 else { return nil }
        guard frame.minX < edge else { return (frame, 0) }
        var result = frame
        result.origin.x = edge
        result.size.width = frame.maxX - edge
        return (result, edge - frame.minX)
    }

    /// What a programme cell draws differently when clipped: square
    /// leading corners, and a title shifted left (≤ 0, whole points) once the
    /// visible part is narrower than the 160 pt the title needs. The cell
    /// re-renders its SwiftUI content only when this changes, not on every
    /// scroll frame that changes the clipped amount.
    struct ClipAppearance: Equatable {
        var clipped = false
        var titleShift: CGFloat = 0
    }

    static func clipAppearance(leadingClip: CGFloat, visibleWidth: CGFloat) -> ClipAppearance {
        guard leadingClip > 0.5 else { return ClipAppearance() }
        return ClipAppearance(clipped: true, titleShift: min(0, (visibleWidth - 160).rounded()))
    }

    /// The pinned channel tile: always at the left of the visible area.
    static func tileFrame(row: Int, offsetX: CGFloat, metrics m: GuideGridMetrics) -> CGRect {
        CGRect(x: offsetX + m.inset, y: rowMinY(row, metrics: m) + m.inset,
               width: m.channelWidth - m.gap, height: m.rowHeight - m.gap)
    }

    /// The no-programme-information placeholder spans the whole loaded day,
    /// so it always lies under the time anchor.
    static func placeholderFrame(row: Int, duration: TimeInterval, metrics m: GuideGridMetrics) -> CGRect {
        CGRect(x: m.channelWidth + m.inset, y: rowMinY(row, metrics: m) + m.inset,
               width: max(1, CGFloat(duration) * m.pointsPerSecond - m.gap), height: m.rowHeight - m.gap)
    }

    /// x of a half-hour label in the time header, whose left edge is the
    /// timeline's clip edge: labels line up with the cells below and slide
    /// with the content (the header clips them at the same edge).
    static func headerLabelX(mark: Date, origin: Date, offsetX: CGFloat, metrics m: GuideGridMetrics) -> CGFloat {
        x(of: mark, origin: origin, metrics: m) + m.inset - clipX(offsetX: offsetX, metrics: m)
    }

    /// Half-hour marks covering the loaded day (the first at or before origin).
    static func headerMarks(origin: Date, duration: TimeInterval) -> [Date] {
        let first = GuideNavigation.rounded(origin)
        let count = Int(ceil(origin.addingTimeInterval(duration).timeIntervalSince(first) / GuideNavigation.step)) + 1
        return (0..<max(0, count)).map { first.addingTimeInterval(Double($0) * GuideNavigation.step) }
    }

    /// Rows intersecting a vertical range.
    static func rows(in minY: CGFloat, _ maxY: CGFloat, count: Int, metrics m: GuideGridMetrics) -> Range<Int> {
        guard count > 0, m.rowHeight > 0 else { return 0..<0 }
        let first = max(0, Int(floor(minY / m.rowHeight)))
        let last = min(count - 1, Int(floor(maxY / m.rowHeight)))
        return first <= last ? first..<(last + 1) : 0..<0
    }

    /// Programmes (ordered by start) that overlap [from, to): a binary search
    /// for the first start ≥ `to` bounds the scan.
    static func indices(of programmes: [GuideProgramme], overlapping from: Date, _ to: Date) -> [Int] {
        let toMs = to.timeIntervalSince1970 * 1000
        let fromMs = from.timeIntervalSince1970 * 1000
        var low = 0, high = programmes.count
        while low < high {
            let mid = (low + high) / 2
            if programmes[mid].startTime < toMs { low = mid + 1 } else { high = mid }
        }
        return (0..<low).filter { programmes[$0].endTime > fromMs }
    }

    /// Cubic ease-in-out for the grid's own scroll animation (t in 0…1).
    static func easeInOut(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }

    // MARK: Navigation policy

    /// The live baseline: the current half hour, where the guide opens and
    /// where "Now" and Left return to.
    static func liveBaseline(now: Date) -> Date { GuideNavigation.rounded(now) }

    /// Column snapping: a viewport is always a whole half hour.
    static func snapped(_ viewport: Date) -> Date {
        Date(timeIntervalSince1970: (viewport.timeIntervalSince1970 / GuideNavigation.step).rounded() * GuideNavigation.step)
    }

    /// The time anchor Up/Down keeps: the focused programme's start, or the
    /// viewport when it started earlier (as GuideView's `anchor`).
    static func anchor(for programme: GuideProgramme, viewport: Date) -> Date {
        max(programme.start, viewport)
    }

    /// Viewport after focus lands on `programme` by a sideways move within a
    /// row. A programme starting in the last half column (or beyond) is
    /// brought a whole column inside the right edge; a future programme
    /// clipped on the left brings its start column into view; a live one
    /// returns to the baseline. Otherwise the grid stays put.
    static func horizontalTarget(for programme: GuideProgramme, viewport: Date, now: Date,
                                 duration: TimeInterval = GuideNavigation.visibleDuration) -> Date {
        if programme.start > viewport.addingTimeInterval(duration - GuideNavigation.step / 2) {
            return GuideNavigation.revealAhead(programme, from: viewport, duration: duration)
        }
        if programme.start < viewport {
            return GuideNavigation.revealMovingLeft(programme, from: viewport, now: now)
        }
        return viewport
    }

    /// Up/Down target in an adjacent row: the programme under the anchor
    /// (never a finished one: before now the anchor is treated as now), else
    /// the nearest unfinished programme, else nil (the channel tile).
    static func verticalTarget(in programmes: [GuideProgramme], anchor: Date, now: Date) -> GuideProgramme? {
        let at = max(anchor, now)
        let open = programmes.filter { $0.end > now && $0.end > $0.start }
        if let hit = open.first(where: { $0.start <= at && at < $0.end }) { return hit }
        func distance(_ p: GuideProgramme) -> TimeInterval {
            if p.start > at { return p.start.timeIntervalSince(at) }
            return at.timeIntervalSince(p.end)
        }
        return open.min { distance($0) < distance($1) }
    }

    enum LeftStep: Equatable {
        /// Leave focus on the channel tile (the grid is at the live baseline).
        case tile
        /// Move the grid to `viewport` and focus the programme starting at
        /// `start` (milliseconds), or the tile when nil.
        case move(viewport: Date, start: Double?)
    }

    /// Left from a programme when the focus engine would otherwise land on
    /// the channel tile (nothing further left is drawn). At the live baseline
    /// that is right; ahead of it the grid steps back onto the previous
    /// unfinished programme, or returns to live when only finished ones lie
    /// behind (GuideView's `reachedEdge`, R02/R19).
    static func leftStep(from startTime: Double?, in programmes: [GuideProgramme], viewport: Date, now: Date) -> LeftStep {
        let baseline = liveBaseline(now: now)
        guard viewport > baseline else { return .tile }
        if let startTime, startTime >= 0,
           let previous = GuideNavigation.neighbour(of: startTime, in: programmes, forward: false),
           previous.end > now, !previous.isLive(at: now) {
            let destination = max(baseline, min(viewport.addingTimeInterval(-GuideNavigation.step),
                GuideNavigation.revealMovingLeft(previous, from: viewport, now: now)))
            return .move(viewport: destination, start: previous.startTime)
        }
        let live = GuideNavigation.programme(in: GuideNavigation.ordered(programmes), at: now)
            ?? programmes.first { $0.end > now }
        return .move(viewport: baseline, start: live?.startTime)
    }
}

// The guide's row filter (category, channel-name search, favourites), shared
// by GuideView and the UIKit grid. Favourites match on the stable identity,
// and a cross-listed channel is shown once in the Favourites filter (server
// 0097 semantics).
nonisolated enum GuideRowFilter {
    static func rows(from guide: [GuideChannel], category: Category?, search: String,
                     onlyFavourites: Bool, favouriteKeys: Set<String>) -> [GuideChannel] {
        var shownFavourites = Set<String>()
        return guide.filter { channel in
            (category.map { channel.matches($0) } ?? true) &&
            (search.isEmpty || channel.name.localizedStandardContains(search)) &&
            // Last, so a listing is only counted as shown once it passes.
            (!onlyFavourites || ((favouriteKeys.contains(channel.identityKey) || favouriteKeys.contains(channel.id))
                                 && shownFavourites.insert(channel.identityKey).inserted))
        }
    }
}
