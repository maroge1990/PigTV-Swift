#if os(tvOS)
import UIKit

// A2.1: data and layout for the UIKit guide grid. Section = channel row;
// item 0 = the pinned channel tile; items 1…n = programmes by time (or one
// "no programme information" placeholder).

/// Rows shared by the grid's data source and layout. Programme lists are
/// ordered/deduplicated lazily and cached by channel, because the real guide
/// has ~18 000 channels and the collection view asks for every section's
/// item count on reload.
final class GuideGridStore {
    private(set) var rows: [GuideChannel] = []
    private var ordered: [String: (count: Int, first: Double, list: [GuideProgramme])] = [:]

    func setRows(_ rows: [GuideChannel]) { self.rows = rows }

    func programmes(in section: Int) -> [GuideProgramme] {
        guard rows.indices.contains(section) else { return [] }
        let channel = rows[section]
        let first = channel.programmes.first?.startTime ?? -1
        if let cached = ordered[channel.id], cached.count == channel.programmes.count, cached.first == first {
            return cached.list
        }
        let list = GuideNavigation.ordered(channel.programmes)
        ordered[channel.id] = (channel.programmes.count, first, list)
        return list
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
    var leadingClip: CGFloat = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! GuideGridAttributes
        copy.leadingClip = leadingClip
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GuideGridAttributes else { return false }
        return other.leadingClip == leadingClip && super.isEqual(object)
    }
}

final class GuideGridLayout: UICollectionViewLayout {
    static let nowLineKind = "guide.nowLine"

    let store: GuideGridStore
    /// Start of the loaded data (BrowseModel.window) and how much is loaded.
    var origin = Date()
    var loadedDuration: TimeInterval = GuideNavigation.loadedDuration
    var now = Date()
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

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        metrics.timelineWidth = max(300, collectionView.bounds.width - metrics.channelWidth)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: GuideGridMath.contentWidth(duration: loadedDuration, metrics: metrics),
               height: GuideGridMath.rowMinY(sectionCount, metrics: metrics))
    }

    // The tile, header and clipping follow the content offset, so every
    // scroll step re-lays the visible elements (cheap: frames are computed on
    // demand for the visible rows only).
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView else { return nil }
        var result: [UICollectionViewLayoutAttributes] = []
        let fromTime = GuideGridMath.viewport(forOffsetX: rect.minX - metrics.channelWidth, origin: origin, metrics: metrics)
        let toTime = GuideGridMath.viewport(forOffsetX: rect.maxX - metrics.channelWidth, origin: origin, metrics: metrics)
        for section in GuideGridMath.rows(in: rect.minY, rect.maxY, count: sectionCount, metrics: metrics) {
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
        indexPath.item == 0 ? tileAttributes(indexPath.section) : hiddenIfNil(programmeAttributes(indexPath), indexPath)
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

    /// Unclipped frame, for scroll targets.
    func fullFrame(of indexPath: IndexPath) -> CGRect? {
        if indexPath.item == 0 { return tileAttributes(indexPath.section).frame }
        if store.isPlaceholder(indexPath) {
            return GuideGridMath.placeholderFrame(row: indexPath.section, duration: loadedDuration, metrics: metrics)
        }
        guard let programme = store.programme(at: indexPath) else { return nil }
        return GuideGridMath.programmeFrame(start: programme.start, end: programme.end,
                                            row: indexPath.section, origin: origin, metrics: metrics)
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
#endif
