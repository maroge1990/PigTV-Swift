import SwiftUI

// PigTV button family. One pink language, three purposeful roles:
//  • surface / secondary  — subtle at rest, bright pink outline + translucent
//    pink fill on focus (the reference look). Rounded-rect for list rows
//    (`PigSurfaceButtonStyle`), capsule for standalone buttons (`TVActionStyle`).
//  • primary CTA          — solid pink, white label, brighter ring on focus
//    (`PigPrimaryButtonStyle` / `pigPrimaryButton()`).
//  • selection            — persistent pink tint for a current choice
//    (`GuideFilterStyle` in GuideView).
// Every role uses the same accent (pink, identical in light and dark) with
// adaptive neutral surfaces/text, so dark and light get corresponding looks.

// The shared focus treatment: bright pink outline + translucent pink fill.
private struct PigFocusSurface: ViewModifier {
    var focused: Bool
    var scheme: ColorScheme
    var shape: AnyShape
    var drawSurface: Bool = true
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(drawSurface ? (focused ? Color.accentColor.opacity(0.22) : Color.guideCell(scheme)) : .clear,
                        in: shape)
            .overlay { shape.stroke(focused ? Color.accentColor : .clear, lineWidth: 3) }
    }
}

// Standalone secondary/neutral button (also the app-wide default). Capsule.
struct TVActionStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20).padding(.vertical, 12)
            .modifier(PigFocusSurface(focused: focused, scheme: scheme, shape: AnyShape(Capsule())))
    }
}

// List row / cell. Rounded-rect; optionally suppresses its own surface when the
// content already draws one (`drawSurface: false`).
struct PigSurfaceButtonStyle: ButtonStyle {
    var drawSurface = true
    var cornerRadius: CGFloat = 10
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PigFocusSurface(focused: focused, scheme: scheme,
                                      shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius)), drawSurface: drawSurface))
    }
}

// Primary call to action: solid pink, white label, white ring + lift on focus.
struct PigPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .overlay { Capsule().strokeBorder(focused ? Color.white.opacity(0.9) : .clear, lineWidth: 3) }
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    @ViewBuilder
    func pigPrimaryButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(PigPrimaryButtonStyle())
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }
}

struct PigPageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color.black : Color.white).ignoresSafeArea()
    }
}
