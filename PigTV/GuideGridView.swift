import SwiftUI

/// A request from GuideView's header (Now, Earlier/Later, Jump to…) to show
/// a time. A new `id` makes it apply again.
struct GuideGridRequest: Equatable {
    var id = UUID()
    var viewport: Date
    /// Now and Jump to… move focus into the grid; Earlier/Later leave it on
    /// their header button (build 22).
    var focus = true
}

import UIKit

// A2.1: the UIKit TV-guide grid (the only tvOS grid since build 27; the
// iPad's too since build 29, with free touch scrolling). One continuous, very
// wide collection view: rows are channels, programmes sit at their times,
// horizontal movement is real contentOffset scrolling, and the collection
// view's own focus engine moves between cells. The navigation rules (column
// reveal, Up/Down time anchor, Left back to live) are GuideGridMath's pure
// functions; this file only wires them to UIKit.
//
// Build 29, iPad (touch): the horizontal offset is not locked. A pan moves
// the grid freely under the finger (a normal UIScrollView pan with
// deceleration and a directional lock), and the gesture's end snaps to the
// nearest half hour (`GuideGridMath.snappedOffsetX`); the viewport is
// committed when scrolling stops. The channel column stays pinned and the
// time header follows, exactly as on the TV. Taps: a live programme plays,
// others open details, the tile or placeholder plays; touch and hold opens
// the same menu as the TV's long press. Focus claims are TV-only.

struct GuideGridActions {
    var select: (GuideChannel, GuideProgramme) -> Void
    var play: (GuideChannel) -> Void
    var details: (GuideChannel, GuideProgramme) -> Void
    var channelOptions: (GuideChannel) -> Void
    var schedule: (GuideChannel) -> Void
    /// Focus moved to a channel (start nil = tile, -1 = placeholder).
    var focusChanged: (_ channelID: String, _ start: Double?) -> Void
    /// The grid's (half-hour) viewport changed.
    var viewportChanged: (Date) -> Void
    /// Up from the top row: GuideView focuses its header's Now button
    /// (otherwise the focus engine picks whatever lies above, e.g. Details).
    var leaveUp: () -> Void = {}
}

struct GuideGridView: UIViewControllerRepresentable {
    let rows: [GuideChannel]
    /// Bumped by GuideView whenever `rows` is recomputed.
    let rowsVersion: Int
    let model: BrowseModel
    /// Start of the loaded day (BrowseModel.window).
    let origin: Date
    /// Build 33: how much is loaded (BrowseModel.guideLoadedUntil − origin).
    /// Grows as the guide extends forward; the grid only gets wider, never
    /// reloads or moves for this.
    let loadedDuration: TimeInterval
    let clock: Date
    let scheduled: Set<String>
    let recording: Set<String>
    let request: GuideGridRequest?
    /// Bumped on a category change: back to the top row and the live baseline.
    let resetToken: Int
    /// Bumped when the player or a details cover closes: focus returns to
    /// the last focused programme or tile.
    var focusRestoreToken = 0
    let actions: GuideGridActions

    func makeUIViewController(context: Context) -> GuideGridViewController {
        GuideGridViewController()
    }

    func updateUIViewController(_ controller: GuideGridViewController, context: Context) {
        controller.update(from: self)
    }
}

final class GuideGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let store = GuideGridStore()
    private lazy var layout = GuideGridLayout(store: store)
    private(set) var collectionView: GuideGridCollectionView!

    private var model: BrowseModel?
    private var actions: GuideGridActions?
    private var clock = Date()
    private var scheduled: Set<String> = []
    private var recording: Set<String> = []
    private var rowsVersion = Int.min
    private var requestID: UUID?
    private var resetToken = Int.min
    private var restoreToken = Int.min

    // Navigation state.
    /// The committed (half-hour) viewport: where the grid is or is animating to.
    private var viewport = GuideGridMath.liveBaseline(now: Date())
    /// Up/Down keep this time column (GuideView's `anchor`).
    private var anchor = Date()
    /// Focused item while focus is inside the grid.
    private var focused: IndexPath?
    /// Last focused channel/programme; survives reloads and focus leaving.
    private var focusIdentity: (channel: String, start: Double?)?
    /// Target of a redirected focus move (Left onto a hidden programme, a
    /// corrected Up/Down move, a restore after reload).
    private var pendingFocus: IndexPath?
    /// Viewport the current focus move should end at (nil: keep).
    private var plannedViewport: Date?
    private var plannedRow: Int?
    private var lastWidth: CGFloat = 0
    private let animator = GuideGridScrollAnimator()
    private let timeHeader = GuideGridTimeHeader()

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Touch devices scroll freely; the TV moves by whole columns under focus.
    private var touchScrolling: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Build 32: the page colour, not clear (see PageBackdrop.swift).
        view.backgroundColor = .pigPage
        let collectionView = GuideGridCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .pigPage
        collectionView.clipsToBounds = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "guide.grid"
        collectionView.accessibilityValue = ISO8601DateFormatter().string(from: viewport)
        collectionView.register(GuideGridTileCell.self, forCellWithReuseIdentifier: GuideGridTileCell.reuseID)
        collectionView.register(GuideGridProgrammeCell.self, forCellWithReuseIdentifier: GuideGridProgrammeCell.reuseID)
        if touchScrolling {
            collectionView.locksX = false
            collectionView.isDirectionalLockEnabled = true
            collectionView.showsVerticalScrollIndicator = true
        }
        view.addSubview(timeHeader)
        view.addSubview(collectionView)
        self.collectionView = collectionView
        animator.collectionView = collectionView
        animator.onFrame = { [weak self] in self?.animationFrame() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Time header on top; the rows scroll beneath it, never under it.
        let m = layout.metrics
        let bounds = view.bounds
        collectionView.frame = CGRect(x: 0, y: m.headerHeight, width: bounds.width,
                                      height: max(0, bounds.height - m.headerHeight))
        let edge = m.channelWidth + m.inset
        timeHeader.frame = CGRect(x: edge, y: 0, width: max(0, bounds.width - edge), height: m.headerHeight)
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        rebuildTimeHeader()
        setOffset(for: viewport, animated: false)
    }

    private func rebuildTimeHeader() {
        timeHeader.configure(origin: layout.origin, duration: layout.loadedDuration, metrics: layout.metrics)
        timeHeader.follow(offsetX: collectionView.contentOffset.x)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        timeHeader.follow(offsetX: scrollView.contentOffset.x)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    // MARK: Updates from SwiftUI

    func update(from view: GuideGridView) {
        model = view.model
        actions = view.actions
        loadViewIfNeeded()
        var needsLayout = false
        let originChanged = layout.origin != view.origin
        if originChanged {
            layout.origin = view.origin
            needsLayout = true
        }
        // Build 33: the loaded window growing forward (or, rarely, shrinking
        // back to a fresh day's worth on reset) — content width only, never
        // a reload of rows, scroll position or focus.
        let durationChanged = layout.loadedDuration != view.loadedDuration
        if durationChanged {
            layout.loadedDuration = view.loadedDuration
            needsLayout = true
        }
        if view.rowsVersion != rowsVersion {
            rowsVersion = view.rowsVersion
            apply(rows: view.rows)
        }
        if view.clock != clock {
            clock = view.clock
            layout.now = view.clock
            needsLayout = true
            reconfigureVisible()
        }
        if view.scheduled != scheduled || view.recording != recording {
            scheduled = view.scheduled
            recording = view.recording
            reconfigureVisible()
        }
        if needsLayout { layout.invalidateLayout() }
        if originChanged {
            // A new day of data: keep showing the same time.
            collectionView.layoutIfNeeded()
            rebuildTimeHeader()
            setOffset(for: viewport, animated: false)
        } else if durationChanged {
            // Wider content only: the time header's own width follows, but
            // scroll position and focus are left exactly where they were.
            collectionView.layoutIfNeeded()
            rebuildTimeHeader()
        }
        if view.resetToken != resetToken {
            let first = resetToken == Int.min
            resetToken = view.resetToken
            // First appearance or a category change: top row, live baseline.
            commit(GuideGridMath.liveBaseline(now: Date()))
            anchor = Date()
            animator.stop()
            collectionView.layoutIfNeeded()
            collectionView.setX(clampedX(for: viewport))
            collectionView.contentOffset.y = 0
            if !first { focusIdentity = nil }
        }
        if let request = view.request, request.id != requestID {
            requestID = request.id
            commit(GuideGridMath.snapped(request.viewport))
            anchor = max(request.viewport, Date())
            setOffset(for: viewport, animated: true)
            // Now / Earlier / Later / Jump to: the programme under the new
            // anchor in the focused row (else the first visible row) becomes
            // the grid's preferred focus. Now and Jump to… move focus into
            // the grid (GuideView.claimGridFocus); Earlier/Later keep it on
            // their header button and claim nothing, so no stale target
            // is left behind.
            let row = focusIdentity.flatMap { identity in store.rows.firstIndex { $0.id == identity.channel } }
                ?? firstVisibleRow()
            if request.focus, !touchScrolling, let row { claimFocus(target(in: row, at: anchor)) }
        }
        if view.focusRestoreToken != restoreToken {
            let first = restoreToken == Int.min
            restoreToken = view.focusRestoreToken
            if !first, !touchScrolling { restoreFocus() }
        }
    }

    // MARK: Focus from outside the grid

    private func firstVisibleRow() -> Int? {
        guard !store.rows.isEmpty else { return nil }
        let row = Int((collectionView.contentOffset.y / layout.metrics.rowHeight).rounded(.up))
        return min(max(0, row), store.rows.count - 1)
    }

    /// The programme under `time` in `section` (the placeholder for a row
    /// without programmes, the tile when nothing is left to focus).
    private func target(in section: Int, at time: Date) -> IndexPath {
        let list = store.programmes(in: section)
        if list.isEmpty { return IndexPath(item: 1, section: section) }
        guard let programme = GuideGridMath.verticalTarget(in: list, anchor: time, now: Date()) else {
            return IndexPath(item: 0, section: section)
        }
        return store.indexPath(section: section, start: programme.startTime) ?? IndexPath(item: 0, section: section)
    }

    /// After the player or a details cover closes: back to the last focused
    /// programme or tile (or, if that programme has finished meanwhile, to
    /// what is on now in its row).
    private func restoreFocus() {
        guard let identity = focusIdentity,
              let section = store.rows.firstIndex(where: { $0.id == identity.channel }) else { return }
        var target = store.indexPath(section: section, start: identity.start) ?? IndexPath(item: 0, section: section)
        if let programme = store.programme(at: target), programme.end <= Date() {
            target = self.target(in: section, at: Date())
        }
        claimFocus(target)
    }

    /// Makes `target` the grid's focus: the row is brought on screen and
    /// the cell becomes the preferred focus. Focus outside the grid (a header
    /// button, a closing cover) is moved in by GuideView through SwiftUI
    /// (`claimGridFocus`): UIKit's own focus requests are refused while a
    /// SwiftUI control holds focus.
    private func claimFocus(_ target: IndexPath) {
        let y = clampedY(collectionView.contentOffset.y, row: target.section)
        if y != collectionView.contentOffset.y {
            collectionView.contentOffset.y = y
            collectionView.layoutIfNeeded()
        }
        requestFocus(target)
    }

    private func apply(rows: [GuideChannel]) {
        let old = store.rows
        // Background paging appends channels; keep the existing cells (and
        // focus) then. Anything else reloads and restores focus by identity.
        let appendOnly = !old.isEmpty && rows.count >= old.count && zip(old, rows).allSatisfy { a, b in
            a.id == b.id && a.programmes.count == b.programmes.count
                && a.programmes.first?.startTime == b.programmes.first?.startTime
        }
        if appendOnly {
            guard rows.count > old.count else { store.setRows(rows); return }
            collectionView.performBatchUpdates {
                store.setRows(rows)
                collectionView.insertSections(IndexSet(old.count..<rows.count))
            }
            return
        }
        // Build 33: a forward extension (or its periodic past-trim) changed
        // some channels' programme counts in place — same channels, same
        // first programme, nothing added or removed from the row list
        // itself. UIKit requires `reloadSections` once a section's item
        // count changes, but only for the sections that actually did;
        // scroll position and every other row's focus/cells are untouched.
        let extendedOnly = !old.isEmpty && rows.count == old.count && zip(old, rows).allSatisfy { a, b in
            a.id == b.id && a.programmes.first?.startTime == b.programmes.first?.startTime
        }
        if extendedOnly {
            let changedSections = IndexSet(rows.indices.filter { rows[$0].programmes.count != old[$0].programmes.count })
            store.setRows(rows)
            guard !changedSections.isEmpty else { layout.invalidateLayout(); return }
            let refocus = focused.map { changedSections.contains($0.section) } ?? false
            collectionView.performBatchUpdates {
                collectionView.reloadSections(changedSections)
            }
            if refocus, let identity = focusIdentity,
               let section = rows.firstIndex(where: { $0.id == identity.channel }) {
                requestFocus(store.indexPath(section: section, start: identity.start) ?? IndexPath(item: 0, section: section))
            }
            return
        }
        let hadFocus = focused != nil
        store.setRows(rows)
        focused = nil
        collectionView.reloadData()
        if hadFocus, let identity = focusIdentity,
           let section = rows.firstIndex(where: { $0.id == identity.channel }) {
            let target = store.indexPath(section: section, start: identity.start)
                ?? IndexPath(item: 0, section: section)
            requestFocus(target)
        }
    }

    private func reconfigureVisible() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) else { continue }
            configure(cell, at: indexPath)
        }
    }

    // MARK: Scrolling

    private func clampedX(for viewport: Date) -> CGFloat {
        GuideGridMath.clampedOffsetX(GuideGridMath.offsetX(forViewport: viewport, origin: layout.origin, metrics: layout.metrics),
                                     duration: layout.loadedDuration, metrics: layout.metrics)
    }

    private func commit(_ viewport: Date) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        // Read by the UI tests to check which moves scroll the grid.
        collectionView.accessibilityValue = ISO8601DateFormatter().string(from: viewport)
        let reported = viewport
        DispatchQueue.main.async { [weak self] in self?.actions?.viewportChanged(reported) }
    }

    /// Moves the grid sideways to the committed viewport: 0.2 s
    /// ease-in-out, or at once with Reduce Motion. Only this moves the grid
    /// horizontally (GuideGridCollectionView ignores the focus engine's own
    /// horizontal scrolling); vertical scrolling stays the system's.
    private func setOffset(for viewport: Date, animated: Bool) {
        let target = clampedX(for: viewport)
        if animated && !reduceMotion {
            animator.animate(to: target, duration: 0.2)
        } else {
            animator.stop()
            collectionView.setX(target)
            collectionView.layoutIfNeeded()
        }
    }

    /// Called on every animation frame (and once after a redirect): a pending
    /// focus target is focused once some of it is on screen, or when the
    /// animation has finished regardless.
    private func animationFrame() {
        guard let pending = pendingFocus else { return }
        guard pending.item == 0 || layout.visibleWidth(of: pending) >= 1 || !animator.isRunning else { return }
        collectionView.setNeedsFocusUpdate()
        collectionView.updateFocusIfNeeded()
    }

    private func requestFocus(_ indexPath: IndexPath) {
        pendingFocus = indexPath
        DispatchQueue.main.async { [weak self] in self?.animationFrame() }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let pendingFocus { return pendingFocus }
        guard let identity = focusIdentity,
              let section = store.rows.firstIndex(where: { $0.id == identity.channel }) else { return nil }
        return store.indexPath(section: section, start: identity.start)
    }

    // Touch: a new pan takes over from a header button's animation.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if touchScrolling { animator.stop() }
    }

    // Touch: when a pan or its deceleration ends, the half hour at the left
    // edge becomes the viewport (header date, day loading, Earlier/Later).
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if touchScrolling && !decelerate { commitScrolledViewport() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if touchScrolling { commitScrolledViewport() }
    }

    private func commitScrolledViewport() {
        let x = collectionView.contentOffset.x
        collectionView.setX(x)
        commit(GuideGridMath.snapped(GuideGridMath.viewport(forOffsetX: x, origin: layout.origin, metrics: layout.metrics)))
    }

    // tvOS: focus-driven vertical scrolling. tvOS asks for the final offset
    // of every scroll the focus engine starts. The focused row is kept wholly
    // inside the grid; the horizontal part is the grid's own (locked).
    // Touch: a pan ends on the nearest half hour; vertical is left alone.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if touchScrolling {
            targetContentOffset.pointee.x = GuideGridMath.snappedOffsetX(targetContentOffset.pointee.x, origin: layout.origin,
                                                                        duration: layout.loadedDuration, metrics: layout.metrics)
            return
        }
        targetContentOffset.pointee.x = collectionView.lockedX
        if let row = plannedRow ?? focused?.section {
            targetContentOffset.pointee.y = clampedY(targetContentOffset.pointee.y, row: row)
        }
    }

    private func clampedY(_ y: CGFloat, row: Int) -> CGFloat {
        let m = layout.metrics
        let height = collectionView.bounds.height
        let top = CGFloat(row) * m.rowHeight
        let bottom = GuideGridMath.rowMinY(row + 1, metrics: m) - height
        var result = min(max(y, bottom), top)
        let maximum = max(0, collectionView.contentSize.height - height)
        result = min(max(0, result), maximum)
        return result
    }

    // MARK: Focus

    private func programme(_ indexPath: IndexPath) -> GuideProgramme? { store.programme(at: indexPath) }

    /// The one item of `section` an Up/Down move may land on.
    private func verticalTarget(in section: Int, from: IndexPath) -> IndexPath {
        if from.item == 0 { return IndexPath(item: 0, section: section) }
        let list = store.programmes(in: section)
        if list.isEmpty { return IndexPath(item: 1, section: section) }
        guard let target = GuideGridMath.verticalTarget(in: list, anchor: anchor, now: Date()) else {
            return IndexPath(item: 0, section: section)
        }
        return store.indexPath(section: section, start: target.startTime) ?? IndexPath(item: 0, section: section)
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if indexPath == pendingFocus { return true }
        if indexPath.item > 0, !store.isPlaceholder(indexPath) {
            // Finished programmes stay visible (dimmed) but never take focus.
            guard let programme = programme(indexPath), programme.end > Date() else { return false }
        }
        // Within the focused row everything else is focusable; in other rows
        // only the Up/Down target, so the focus engine can only choose it.
        guard let focused, focused.section != indexPath.section else { return true }
        return verticalTarget(in: indexPath.section, from: focused) == indexPath
    }

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        plannedViewport = nil
        plannedRow = context.nextFocusedIndexPath?.section
        guard let next = context.nextFocusedIndexPath else {
            // Leaving the grid upwards (only possible from the top row):
            // refuse the engine's choice and let GuideView move SwiftUI focus
            // to the header's Now button.
            if context.previouslyFocusedIndexPath != nil, context.focusHeading.contains(.up), let actions {
                DispatchQueue.main.async { actions.leaveUp() }
                return false
            }
            return true
        }
        if next == pendingFocus { return true }
        guard let previous = context.previouslyFocusedIndexPath else { return true }
        let heading = context.focusHeading
        let now = Date()
        if heading.contains(.left) || heading.contains(.right) {
            guard next.section == previous.section else { return false }
            if heading.contains(.left), next.item == 0, previous.item > 0 {
                // Nothing further left is drawn: at the live baseline the
                // tile is right; ahead of it, step back or return to live.
                let start = programme(previous)?.startTime ?? -1
                switch GuideGridMath.leftStep(from: start, in: store.programmes(in: previous.section),
                                              viewport: viewport, now: now) {
                case .tile:
                    return true
                case let .move(destination, targetStart):
                    redirect(to: store.indexPath(section: previous.section, start: targetStart)
                                 ?? IndexPath(item: 0, section: previous.section),
                             viewport: destination)
                    return false
                }
            }
            if let programme = programme(next) {
                plannedViewport = GuideGridMath.horizontalTarget(for: programme, viewport: viewport, now: now)
            }
            return true
        }
        if heading.contains(.up) || heading.contains(.down) {
            let target = verticalTarget(in: next.section, from: previous)
            if next != target {
                redirect(to: target, viewport: nil)
                return false
            }
        }
        return true
    }

    private func redirect(to target: IndexPath, viewport destination: Date?) {
        if let destination {
            commit(destination)
            anchor = store.programme(at: target).map { GuideGridMath.anchor(for: $0, viewport: destination) } ?? Date()
        }
        requestFocus(target)
        if destination != nil { setOffset(for: viewport, animated: true) }
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        let previous = context.previouslyFocusedIndexPath
        focused = context.nextFocusedIndexPath
        guard let next = focused, store.rows.indices.contains(next.section) else {
            pendingFocus = nil
            return
        }
        if next == pendingFocus { pendingFocus = nil }
        let channel = store.rows[next.section]
        let programme = programme(next)
        let start: Double? = next.item == 0 ? nil : (programme?.startTime ?? -1)
        focusIdentity = (channel.id, start)
        let sideways = previous == nil || previous?.section == next.section
        let target = plannedViewport ?? viewport
        if sideways, let programme {
            anchor = GuideGridMath.anchor(for: programme, viewport: target)
        } else if let programme, plannedViewport == nil,
                  programme.end <= viewport || programme.start >= viewport.addingTimeInterval(layout.metrics.visibleDuration) {
            // Up/Down landed on a programme wholly off screen (the row has a
            // gap under the anchor): the one case a vertical move scrolls.
            plannedViewport = GuideGridMath.horizontalTarget(for: programme, viewport: viewport, now: Date())
        }
        // A sideways move by whole columns, planned in shouldUpdateFocus.
        if let planned = plannedViewport, planned != viewport {
            commit(planned)
            setOffset(for: planned, animated: true)
        }
        plannedViewport = nil
        let id = channel.id
        DispatchQueue.main.async { [weak self] in self?.actions?.focusChanged(id, start) }
    }

    // MARK: Selection and menus

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Touch leaves a selection behind; nothing is drawn for it.
        collectionView.deselectItem(at: indexPath, animated: false)
        guard store.rows.indices.contains(indexPath.section), let actions else { return }
        let channel = store.rows[indexPath.section]
        if let programme = programme(indexPath) { actions.select(channel, programme) } else { actions.play(channel) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, store.rows.indices.contains(indexPath.section), let actions else { return nil }
        let channel = store.rows[indexPath.section]
        let options = UIAction(title: "Channel and favourites") { _ in actions.channelOptions(channel) }
        var items: [UIMenuElement] = []
        if indexPath.item == 0 {
            items = [UIAction(title: "All programmes on this channel") { _ in actions.schedule(channel) }, options]
        } else if let programme = programme(indexPath) {
            items = [UIAction(title: "Programme details") { _ in actions.details(channel, programme) }, options]
        } else {
            items = [options]
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: items) }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { store.rows.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        store.itemCount(in: section)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let id = indexPath.item == 0 ? GuideGridTileCell.reuseID : GuideGridProgrammeCell.reuseID
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: id, for: indexPath)
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: UICollectionViewCell, at indexPath: IndexPath) {
        guard store.rows.indices.contains(indexPath.section) else { return }
        let channel = store.rows[indexPath.section]
        let logo = model?.logo(for: channel)
        if let tile = cell as? GuideGridTileCell {
            tile.channel = channel
            tile.client = model?.client
            tile.info = .init(channelID: channel.id, number: model?.number(for: channel).map { String($0) },
                              logo: logo, flaky: model?.isFlaky(channel) ?? false,
                              recording: recording.contains(channel.name))
        } else if let cell = cell as? GuideGridProgrammeCell {
            let programme = programme(indexPath)
            let live = programme?.isLive(at: clock) ?? false
            cell.info = GuideGridProgrammeInfo(
                channelName: channel.name, programme: programme,
                caption: live && logo != nil ? channel.name : nil,
                scheduled: programme.map { scheduled.contains(ScheduledRecording.key(channel: channel.name, start: $0.startTime)) } ?? false,
                clock: clock)
        }
    }
}

/// The grid's collection view. On tvOS its horizontal offset is locked to
/// `lockedX`, which only the grid sets (by whole columns): the focus engine's
/// own scroll-into-view would otherwise slide the grid sideways on Up/Down
/// and stop between columns. Vertical scrolling is untouched. On iPad
/// (`locksX == false`, build 29) a touch pan moves it freely.
final class GuideGridCollectionView: UICollectionView {
    private(set) var lockedX: CGFloat = 0
    var locksX = true

    func setX(_ x: CGFloat) {
        lockedX = x
        contentOffset.x = x
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            var bounds = newValue
            if locksX { bounds.origin.x = lockedX }
            super.bounds = bounds
        }
    }
}

/// Animates the grid's horizontal offset frame by frame (so the pinned
/// column, header and clipping follow every frame), 0.2 s ease-in-out.
final class GuideGridScrollAnimator: NSObject {
    weak var collectionView: GuideGridCollectionView?
    var onFrame: (() -> Void)?
    private var link: CADisplayLink?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.2

    func animate(to target: CGFloat, duration: CFTimeInterval) {
        guard let collectionView else { return }
        stop()
        from = collectionView.lockedX
        to = target
        guard from != to else { return }
        self.duration = duration
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    var isRunning: Bool { link != nil }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        guard let collectionView else { stop(); return }
        let t = min(1, (CACurrentMediaTime() - startTime) / duration)
        collectionView.setX(from + (to - from) * GuideGridMath.easeInOut(t))
        collectionView.layoutIfNeeded()
        if t >= 1 { stop() }
        onFrame?()
    }
}
