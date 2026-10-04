import SwiftUI

// The guide grid's collection view and its scroll animator (split out of GuideGridView.swift in build 39).

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
