import SwiftUI

/// Brand 1.8 (§6, §15; maroge1990/PigTV#279): the one Apple TV focus treatment. The focused item lifts (a scale and a
/// shadow), carries the accent ring outside its edge, and its fill is the kit's focus fill (`PigFocus.fill`, accent at
/// 22 %). Selection (accent at 14 % plus a bar) stays separate. Every focusable style on tvOS draws focus through
/// `pigFocus(_:in:lift:)`; BrandRulesTests fails on a style that reads focus and draws it any other way.
enum PigFocus {
    /// The ring's outer edge sits this far outside the control (§6: "a ring that extends 4 px beyond a control").
    static let ringOutset: CGFloat = 4
    /// The ring's width, inside that outset (so 1 pt of the background shows between the control and the ring).
    static let ringWidth: CGFloat = 3
    /// The unclipped room a focused control needs around it (§6: "at least 6 px"): scroll views and rails keep it.
    static let clearance: CGFloat = 6
    /// How long the lift takes. No animation under Reduce Motion.
    static let duration: Double = 0.15
    /// The focus fill (kit `derived.focusFill`): accent at 22 % over the resting fill.
    static let fillOpacity: Double = 0.22
    static var fill: Color { Color.pigAccent.opacity(fillOpacity) }
    /// Brand 1.8 §15 (#279, Apple 200): every focusable control on the television is at least 56 x 56 pt. Touch has its
    /// own (system) minimums, so 0 there.
    #if os(tvOS)
    static let minTarget: CGFloat = 56
    #else
    static let minTarget: CGFloat = 0
    #endif
}

/// How far a focused item lifts. Ring, tint, timing and Reduce Motion are the same for every kind; only the lift
/// differs. The lift is a scale, capped at a number of points on each edge, so a wide item grows by points, not by
/// percent: a full-width row (wider than `PigFocusLift.wide`) grows 2 pt, which with the 4 pt ring stays inside the
/// 8 pt its list leaves; the guide's packed cells (an 8 pt gap to each neighbour) take the shadow only.
nonisolated enum PigFocusLift {
    /// Cards in a rail (sport games, airings, tiles).
    case card
    /// Buttons and chips.
    case control
    /// Rows in a list (the settings menu, the long-press menu).
    case row
    /// The TV Guide's packed cells: no scale, the shadow only.
    case cell
    /// Rows of a short list that clips (the Sport banner's): a 1 pt lift and a tight shadow, so the ring (4 pt), lift and
    /// shadow stay inside the list's 6 pt of room on every side (SportBannerTests).
    case listRow

    /// Wider than this, an item is a full-width row whatever its kind.
    static let wide: CGFloat = 800
    /// The most a wide row grows on each edge.
    static let wideGrowth: CGFloat = 2

    var scale: CGFloat {
        switch self {
        case .card: 1.05
        case .control: 1.06
        case .row, .listRow: 1.02
        case .cell: 1
        }
    }
    /// The most the item grows on each edge, in points: with the 4 pt ring, 10 pt, inside a rail's 12 pt spacing.
    var maxGrowth: CGFloat {
        switch self {
        case .card: 6
        case .control: 6
        case .row: 4
        case .listRow: 1
        case .cell: 0
        }
    }
    var shadowRadius: CGFloat {
        switch self {
        case .card, .control: 18
        case .row, .cell: 10
        case .listRow: 3
        }
    }
    var shadowY: CGFloat {
        switch self {
        case .card, .control: 10
        case .row, .cell: 4
        case .listRow: 1
        }
    }

    /// The scale for an item `width` points wide: the kind's scale, capped so no edge grows more than its points.
    func scale(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        let growth = width > Self.wide ? min(maxGrowth, Self.wideGrowth) : maxGrowth
        return min(scale, 1 + 2 * growth / width)
    }
}

private struct PigFocusModifier<S: InsettableShape>: ViewModifier {
    let focused: Bool
    let shape: S
    let lift: PigFocusLift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .shadow(color: focused ? Color.pigShadow.opacity(scheme == .dark ? 0.55 : 0.22) : .clear,
                    radius: focused ? lift.shadowRadius : 0, y: focused ? lift.shadowY : 0)
            .overlay {
                shape.inset(by: -PigFocus.ringOutset)
                    .strokeBorder(Color.pigAccent, lineWidth: PigFocus.ringWidth)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .visualEffect { [lift, lifted = focused && !reduceMotion] content, proxy in
                content.scaleEffect(lifted ? lift.scale(forWidth: proxy.size.width) : 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: PigFocus.duration), value: focused)
    }
}

extension View {
    /// `pigFocus` for views rebuilt on every state change (the TV Guide's UIKit cells): an unfocused cell carries no
    /// focus modifier at all, so the many unfocused cells pay nothing; only the focused one does (no animation is lost:
    /// the hosting configuration rebuilds the cell anyway).
    @ViewBuilder
    func pigFocusWhenFocused<S: InsettableShape>(_ focused: Bool, in shape: S, lift: PigFocusLift) -> some View {
        if focused { pigFocus(true, in: shape, lift: lift) } else { self }
    }

    /// At least `PigFocus.minTarget` in both dimensions on the television (content centred); nothing on touch. A focus
    /// style applies it before drawing its surface, so the surface and the ring cover the whole target.
    @ViewBuilder
    func pigTarget() -> some View {
        #if os(tvOS)
        frame(minWidth: PigFocus.minTarget, minHeight: PigFocus.minTarget)
        #else
        self
        #endif
    }

    /// The shared focus treatment (tvOS): lift, the accent ring outside `shape`, and the animation. The caller fills its
    /// own background with `PigFocus.fill` when focused (the primary action keeps its accent fill). On touch it draws
    /// nothing: the touch styles keep their own pressed looks.
    @ViewBuilder
    func pigFocus<S: InsettableShape>(_ focused: Bool, in shape: S, lift: PigFocusLift) -> some View {
        #if os(tvOS)
        modifier(PigFocusModifier(focused: focused, shape: shape, lift: lift))
        #else
        self
        #endif
    }
}
