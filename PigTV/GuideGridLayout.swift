import UIKit

// A2.1: data and layout for the UIKit guide grid. Section = channel row;
// item 0 = the pinned channel tile; items 1…n = programmes by time (or one
// "no programme information" placeholder).

/// What the programme lists were built from. A change here (the model merged
/// or corrected programmes, or the guide was reloaded) drops every cached
/// list; the channel's count and first start cannot tell a same-shape EPG
/// correction (a changed title or end time) from the old data.
nonisolated struct GuideGridRevision: Hashable {
    var programmes = 0
    var loadedAt: Date?
}

/// Rows shared by the grid's data source and layout. Programme lists are
/// ordered/deduplicated lazily and cached by channel, because the real guide
/// has ~18 000 channels and the collection view asks for every section's
/// item count on reload.
final class GuideGridStore {
    private(set) var rows: [GuideChannel] = []
    private(set) var revision = GuideGridRevision()
    private var ordered: [String: [GuideProgramme]] = [:]
    /// #360 (D1): lists ordered here, on the main thread (cache misses), for the tests.
    private(set) var mainThreadOrders = 0

    /// `primed`: lists built ahead (`orderedLists`) from these rows for `revision`, committed with them (review of 388:
    /// primed earlier, a layout of the old rows in between refilled the cache under the new revision with old lists).
    func setRows(_ rows: [GuideChannel], revision: GuideGridRevision = GuideGridRevision(),
                 primed: [String: [GuideProgramme]] = [:]) {
        if revision != self.revision {
            self.revision = revision
            ordered.removeAll()
        }
        for (id, list) in primed { ordered[id] = list }
        self.rows = rows
    }

    func programmes(in section: Int) -> [GuideProgramme] {
        guard rows.indices.contains(section) else { return [] }
        let channel = rows[section]
        if let cached = ordered[channel.id] { return cached }
        let began = GuidePerf.orderBegan(); defer { GuidePerf.orderEnded(began) } // #360 (D1)
        mainThreadOrders += 1
        let list = Self.items(of: channel)
        ordered[channel.id] = list
        return list
    }

    /// The lists for `rows`, computed away from the main actor (it is most of
    /// a reload's cost for a thousand channels) and handed to `adopt`.
    nonisolated static func orderedLists(for rows: [GuideChannel]) -> [String: [GuideProgramme]] {
        var lists: [String: [GuideProgramme]] = [:]
        lists.reserveCapacity(rows.count)
        for channel in rows where lists[channel.id] == nil {
            lists[channel.id] = items(of: channel)
        }
        return lists
    }

    /// Takes lists built by `orderedLists` for `revision`, ahead of the rows
    /// that use them.
    func prime(_ lists: [String: [GuideProgramme]], revision: GuideGridRevision) {
        if revision != self.revision {
            self.revision = revision
            ordered.removeAll()
        }
        for (id, list) in lists where ordered[id] == nil { ordered[id] = list }
    }

    /// The programmes a row's cells show (the data source's items after the tile): valid, de-duplicated by start, in
    /// order. The only place the grid normalises a row; everything that counts items goes through it.
    nonisolated static func items(of channel: GuideChannel) -> [GuideProgramme] {
        GuideNavigation.ordered(channel.programmes)
    }

    /// Codex sign-off of 389 (high): whether `b` gives the data source exactly what `a` did (the same channel, the same
    /// items). `items(of:)` is a function of the programmes alone, so equal programmes are equal items; anything else
    /// (a corrected or de-duplicated programme, a programme gained) counts as changed.
    nonisolated static func unchangedForDataSource(_ a: GuideChannel, _ b: GuideChannel) -> Bool {
        a.id == b.id && a.programmes == b.programmes
    }

    func itemCount(in section: Int) -> Int { 1 + max(1, programmes(in: section).count) }

    /// Item index → programme (nil for the tile and the placeholder).
    func programme(at indexPath: IndexPath) -> GuideProgramme? {
        guard indexPath.item > 0 else { return nil }
        let list = programmes(in: indexPath.section)
        return list.indices.contains(indexPath.item - 1) ? list[indexPath.item - 1] : nil
    }

    func isPlaceholder(_ indexPath: IndexPath) -> Bool {
        indexPath.item == 1 && programmes(in: indexPath.section).isEmpty
    }

    func indexPath(section: Int, start: Double?) -> IndexPath? {
        guard rows.indices.contains(section) else { return nil }
        guard let start else { return IndexPath(item: 0, section: section) }
        let list = programmes(in: section)
        if start < 0 || list.isEmpty { return list.isEmpty ? IndexPath(item: 1, section: section) : nil }
        return list.firstIndex { $0.startTime == start }.map { IndexPath(item: $0 + 1, section: section) }
    }
}

/// Layout attributes carrying how much of a cell (or header label) is hidden
/// under the pinned channel column, so the cell keeps its title on screen.
final class GuideGridAttributes: UICollectionViewLayoutAttributes {
    // Read by isEqual, which NSObject declares nonisolated; UIKit only uses
    // layout attributes on the main thread.
    nonisolated(unsafe) var leadingClip: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! GuideGridAttributes
        copy.leadingClip = leadingClip
        return copy
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GuideGridAttributes else { return false }
        return other.leadingClip == leadingClip && super.isEqual(object)
    }
}

/// #360 (G8): a bounds change that moved the grid vertically only (same size, same horizontal offset): only the now line
/// is invalidated, so it is not a full layout pass.
final class GuideGridInvalidationContext: UICollectionViewLayoutInvalidationContext {
    var verticalScrollOnly = false
}

final class GuideGridLayout: UICollectionViewLayout {
    static let nowLineKind = "guide.nowLine"

    let store: GuideGridStore
    /// Start of the loaded data (BrowseModel.window) and how much is loaded.
    var origin = Date()
    var loadedDuration: TimeInterval = GuideNavigation.loadedDuration
    var now = Date()
    /// Rows from this one on get no cells yet. The first fill reveals the grid
    /// in steps (a frame each); building every visible SwiftUI-hosted cell
    /// at once was most of the TV Guide's first-visit stall.
    var revealedRows = Int.max
    private(set) var metrics = GuideGridMetrics()

    private let zTile = 10, zProgramme = 0, zNowLine = 5

    init(store: GuideGridStore) {
        self.store = store
        super.init()
        register(GuideGridNowLine.self, forDecorationViewOfKind: Self.nowLineKind)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override class var layoutAttributesClass: AnyClass { GuideGridAttributes.self }

    private var sectionCount: Int { collectionView?.numberOfSections ?? 0 }
    private var offset: CGPoint { collectionView?.contentOffset ?? .zero }

    /// #360 (G8): full layout passes so far (a `prepare` after an invalidation that was not a targeted scroll one), for
    /// the tests and the probe (`layoutPrepares`).
    private(set) var fullPrepares = 0
    private var fullPending = true

    override class var invalidationContextClass: AnyClass { GuideGridInvalidationContext.self }

    #if DEBUG
    /// The perf tier's comparison run (PIGTV_UI_TEST_GUIDE_LAYOUT_377=1, UI tests only) and the unit test's check of its
    /// own measure: every scroll step invalidates the whole layout, as before Apple 378, so the same build measures both.
    static var wholeLayoutOnScroll = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_GUIDE_LAYOUT_377"] == "1"
    #endif

    /// Review of 378: calls of `layoutAttributesForElements(in:)`, the layout's real work (each builds the attributes of
    /// every element in its rect; `prepare()` does almost nothing). UIKit makes one per frame after a full invalidation,
    /// and only for newly exposed rows after a vertical-only one.
    private(set) var elementQueries = 0
    /// #360 (D1): calls of `layoutAttributesForItem(at:)` (UIKit asks it per item, e.g. for every item of inserted rows).
    private(set) var itemQueries = 0

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        let targeted = (context as? GuideGridInvalidationContext)?.verticalScrollOnly == true
            && !context.invalidateEverything && !context.invalidateDataSourceCounts
        if !targeted { fullPending = true }
        super.invalidateLayout(with: context)
    }

    override func prepare() {
        let began = GuidePerf.layoutWorkBegan(); defer { GuidePerf.layoutWorkEnded(began, prepare: true) } // #362
        super.prepare()
        if fullPending {
            fullPending = false
            fullPrepares += 1
            GuidePerf.layoutPrepared()
        }
        guard let collectionView else { return }
        metrics.timelineWidth = max(300, collectionView.bounds.width - metrics.channelWidth)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: GuideGridMath.contentWidth(duration: loadedDuration, metrics: metrics),
               height: GuideGridMath.rowMinY(sectionCount, metrics: metrics))
    }

    // The tiles and the clipping follow the horizontal offset, the now line the
    // vertical one. A step sideways (or a new size) re-lays every visible
    // element; a vertical step (every focus move up or down, every frame of a
    // held scroll) invalidates the now line alone (#360 G8: it used to redo the
    // whole layout too). Rows that come on screen are asked for as usual.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        #if DEBUG
        if Self.wholeLayoutOnScroll { return context }
        #endif
        guard let collectionView, let context = context as? GuideGridInvalidationContext else { return context }
        let old = collectionView.bounds
        guard newBounds.size == old.size, newBounds.origin.x == old.origin.x, sectionCount > 0 else { return context }
        context.verticalScrollOnly = true
        context.invalidateDecorationElements(ofKind: Self.nowLineKind, at: [IndexPath(item: 0, section: 0)])
        return context
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let began = GuidePerf.layoutWorkBegan(); defer { GuidePerf.layoutWorkEnded(began, prepare: false) } // #362
        elementQueries += 1
        guard let collectionView else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []
        let fromTime = GuideGridMath.viewport(forOffsetX: rect.minX - metrics.channelWidth, origin: origin, metrics: metrics)
        let toTime = GuideGridMath.viewport(forOffsetX: rect.maxX - metrics.channelWidth, origin: origin, metrics: metrics)
        for section in GuideGridMath.rows(in: rect.minY, rect.maxY, count: sectionCount, metrics: metrics)
        where section < revealedRows {
            let items = collectionView.numberOfItems(inSection: section)
            result.append(tileAttributes(section))
            if store.programmes(in: section).isEmpty {
                if items > 1, let placeholder = programmeAttributes(IndexPath(item: 1, section: section)) {
                    result.append(placeholder)
                }
                continue
            }
            for index in GuideGridMath.indices(of: store.programmes(in: section), overlapping: fromTime, toTime)
            where index + 1 < items {
                if let attributes = programmeAttributes(IndexPath(item: index + 1, section: section)),
                   attributes.frame.intersects(rect) {
                    result.append(attributes)
                }
            }
        }
        // The now line hangs off section 0.
        guard sectionCount > 0 else { return result }
        if let line = layoutAttributesForDecorationView(ofKind: Self.nowLineKind, at: IndexPath(item: 0, section: 0)),
           !line.isHidden, line.frame.intersects(rect) {
            result.append(line)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let began = GuidePerf.queryBegan(); defer { GuidePerf.itemQueried(began) } // #360 (D1)
        itemQueries += 1
        return indexPath.item == 0 ? tileAttributes(indexPath.section) : hiddenIfNil(programmeAttributes(indexPath), indexPath)
    }

    override func layoutAttributesForDecorationView(ofKind elementKind: String,
                                                    at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == Self.nowLineKind, let collectionView else { return nil }
        let attributes = GuideGridAttributes(forDecorationViewOfKind: elementKind, with: indexPath)
        let x = GuideGridMath.x(of: now, origin: origin, metrics: metrics)
        attributes.frame = CGRect(x: x - 1, y: offset.y, width: 2, height: collectionView.bounds.height)
        attributes.zIndex = zNowLine
        attributes.isHidden = x < GuideGridMath.clipX(offsetX: offset.x, metrics: metrics) || sectionCount == 0
        return attributes
    }

    private func tileAttributes(_ section: Int) -> GuideGridAttributes {
        let attributes = GuideGridAttributes(forCellWith: IndexPath(item: 0, section: section))
        attributes.frame = GuideGridMath.tileFrame(row: section, offsetX: offset.x, metrics: metrics)
        attributes.zIndex = zTile
        return attributes
    }

    /// Clipped frame of a programme or placeholder; nil when wholly under
    /// the channel column.
    private func programmeAttributes(_ indexPath: IndexPath) -> GuideGridAttributes? {
        let full: CGRect
        if store.isPlaceholder(indexPath) {
            full = GuideGridMath.placeholderFrame(row: indexPath.section, duration: loadedDuration, metrics: metrics)
        } else if let programme = store.programme(at: indexPath) {
            full = GuideGridMath.programmeFrame(start: programme.start, end: programme.end,
                                                row: indexPath.section, origin: origin, metrics: metrics)
        } else {
            return nil
        }
        guard let clipped = GuideGridMath.clipped(full, offsetX: offset.x, metrics: metrics) else { return nil }
        let attributes = GuideGridAttributes(forCellWith: indexPath)
        attributes.frame = clipped.frame
        attributes.leadingClip = clipped.leadingClip
        attributes.zIndex = zProgramme
        return attributes
    }

    private func hiddenIfNil(_ attributes: GuideGridAttributes?, _ indexPath: IndexPath) -> GuideGridAttributes {
        if let attributes { return attributes }
        let hidden = GuideGridAttributes(forCellWith: indexPath)
        let edge = GuideGridMath.clipX(offsetX: offset.x, metrics: metrics)
        hidden.frame = CGRect(x: edge, y: GuideGridMath.rowMinY(indexPath.section, metrics: metrics) + metrics.inset,
                              width: 0, height: metrics.rowHeight - metrics.gap)
        hidden.isHidden = true
        return hidden
    }

    /// Visible (clipped) width of an item right now.
    func visibleWidth(of indexPath: IndexPath) -> CGFloat {
        programmeAttributes(indexPath)?.frame.width ?? 0
    }
}

/// The now line: a thin accent bar across the visible rows.
final class GuideGridNowLine: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(named: "AccentColor") ?? .systemPink
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
