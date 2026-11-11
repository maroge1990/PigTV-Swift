import SwiftUI

// Apple's design checklist and brand 1.8 §8, §14, §16 (maroge1990/PigTV#280): two named animations, in this one place,
// instead of the ten hand-picked durations the views used (0.12, 0.15, 0.16, 0.18, 0.2, 0.22, 0.25 s and the system
// default). `standard` is the default: short and smooth, with no bounce (a panel, a fade, chrome showing or hiding, a
// switch). `momentum` is a spring for something that follows a gesture or a scroll (a carousel, a list scrolled to an
// item). Reduce Motion: a change that moves or scales something has no animation, and a slide becomes a fade.
// BrandRulesTests fails on a literal duration or a bare `withAnimation {` outside this file (the splash's brand cycle,
// the television's focus lift and a countdown clock are marked where they are).

nonisolated enum PigMotion {
    /// The standard animation's length, for UIKit animators (the guide grid's scroll).
    static let standardDuration: Double = 0.2
    /// The default: smooth, no bounce.
    static var standard: Animation { .smooth(duration: standardDuration) }
    /// For movement that follows a gesture or a scroll.
    static var momentum: Animation { .spring(duration: 0.35, bounce: 0.15) }

    /// The animation for a change, or none: under Reduce Motion a change that moves or scales has none (a fade keeps
    /// the standard animation, which moves nothing).
    static func animation(moves: Bool, momentum: Bool = false, reduceMotion: Bool) -> Animation? {
        if moves && reduceMotion { return nil }
        return momentum ? Self.momentum : standard
    }

    /// What a slide in from `edge` becomes: the slide with a fade, or the fade alone under Reduce Motion.
    static func slide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

private struct PigAnimationModifier<V: Equatable>: ViewModifier {
    let value: V
    let moves: Bool
    let momentum: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(PigMotion.animation(moves: moves, momentum: momentum, reduceMotion: reduceMotion), value: value)
    }
}

private struct PigSlideModifier: ViewModifier {
    let edge: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(PigMotion.slide(edge, reduceMotion: reduceMotion))
    }
}

extension View {
    /// `.animation(_:value:)` with one of the two named animations. `moves`: the change moves or scales something, so
    /// Reduce Motion turns it off; `momentum`: it follows a gesture or a scroll.
    func pigAnimation<V: Equatable>(value: V, moves: Bool = false, momentum: Bool = false) -> some View {
        modifier(PigAnimationModifier(value: value, moves: moves, momentum: momentum))
    }

    /// A transition that slides in from `edge` with a fade; the fade alone under Reduce Motion.
    func pigSlide(from edge: Edge) -> some View { modifier(PigSlideModifier(edge: edge)) }
}

/// `withAnimation` with a named animation, or none (`nil` under Reduce Motion for a change that moves).
@MainActor func pigWithAnimation<Result>(moves: Bool = false, momentum: Bool = false, reduceMotion: Bool,
                                         _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(PigMotion.animation(moves: moves, momentum: momentum, reduceMotion: reduceMotion), body)
}

/// Apple's checklist (#280): a plain card or row on touch shows that it is pressed: it dims, and without Reduce Motion
/// settles a little. Before Apple 206 the iPhone's plain cards (Sport, Recordings, Scheduled, On now) gave no sign.
struct PigPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(PigPress.opacity(pressed: configuration.isPressed))
            .scaleEffect(PigPress.scale(pressed: configuration.isPressed, reduceMotion: reduceMotion))
            .animation(PigMotion.animation(moves: true, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// The pressed look's values. Pure.
nonisolated enum PigPress {
    static func opacity(pressed: Bool) -> Double { pressed ? 0.6 : 1 }
    static func scale(pressed: Bool, reduceMotion: Bool) -> CGFloat { pressed && !reduceMotion ? 0.98 : 1 }
}

extension View {
    /// A plain card or row: the pressed state on touch; the television keeps `.plain` and its system focus effect.
    @ViewBuilder func pigPressable() -> some View {
        #if os(tvOS)
        buttonStyle(.plain)
        #else
        buttonStyle(PigPressStyle())
        #endif
    }
}
