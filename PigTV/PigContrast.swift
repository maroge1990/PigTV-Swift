import SwiftUI

// Brand 1.8 §9 and §16 (maroge1990/PigTV#280): the accessibility settings' fallbacks, environment-driven and applied
// through the shared roles and styles, never per screen.
//
// Increase Contrast. The colour catalogue carries a high-contrast value for the roles that soften the page: PigBorder
// takes the Control boundary colour (#857B8D / #7E7589), PigSecondary takes the Primary text colour, and PigSelection
// (the accent at 14 %) doubles to 28 %. The system picks them from the environment, so every card, field, tag and
// secondary line follows. The shared surface style (cards and rows, `PigSurfaceButtonStyle`) and the touch secondary
// button add the Control boundary border, which they otherwise do not draw. Before Apple 206 nothing read the setting.
//
// Reduce Transparency. A translucent surface the app draws itself (`pigTranslucentBackground`) becomes the solid canvas
// with the border. The players' panels already had their own fallback (`pigMediaSolidPanel`); system materials and Liquid
// Glass follow the setting by themselves.

enum PigContrast {
    /// The catalogue roles that change under Increase Contrast, with the role whose value they take.
    static let strongerRoles: [(role: String, takes: String)] = [("PigBorder", "PigControlBoundary"), ("PigSecondary", "PigText")]
    /// The selection tint's opacity, normally and under Increase Contrast (PigSelection).
    static let selectionOpacity: (normal: Double, increased: Double) = (0.14, 0.28)

    /// The border a card or row draws: none normally (its fill sets it apart), the Control boundary under Increase
    /// Contrast.
    static func cardBorder(increased: Bool) -> Color? { increased ? Color.pigControlBoundary : nil }

    /// What a translucent surface the app draws is filled with: the canvas at 85 %, or solid with the border under
    /// Reduce Transparency.
    static func translucentFill(reduceTransparency: Bool) -> (opacity: Double, border: Bool) {
        reduceTransparency ? (1, true) : (0.85, false)
    }
}

private struct PigContrastBorder<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if let border = PigContrast.cardBorder(increased: contrast == .increased) {
                shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false)
            }
        }
    }
}

private struct PigTranslucentBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let fill = PigContrast.translucentFill(reduceTransparency: reduceTransparency)
        content
            .background(Color.pigCanvas.opacity(fill.opacity), in: shape)
            .overlay { if fill.border { shape.strokeBorder(Color.pigBorder, lineWidth: 1) } }
    }
}

extension View {
    /// The Control boundary border under Increase Contrast (nothing otherwise).
    func pigContrastBorder<S: InsettableShape>(_ shape: S) -> some View { modifier(PigContrastBorder(shape: shape)) }

    /// A small surface over artwork: the canvas at 85 %, solid with the border under Reduce Transparency.
    func pigTranslucentBackground<S: InsettableShape>(_ shape: S) -> some View { modifier(PigTranslucentBackground(shape: shape)) }
}
