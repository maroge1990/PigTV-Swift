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

extension Color {
    /// PigTV pink, from the asset catalogue. `Color.accentColor` is not used:
    /// on tvOS it resolved to white outside a NavigationStack (the
    /// unreachable and sign-in screens showed blank white primary buttons).
    static let pigAccent = Color("AccentColor")
}

// The shared focus treatment: bright pink outline + translucent pink fill.
private struct PigFocusSurface: ViewModifier {
    var focused: Bool
    var scheme: ColorScheme
    var shape: AnyShape
    var drawSurface: Bool = true
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(drawSurface ? (focused ? Color.pigAccent.opacity(0.22) : Color.guideCell(scheme)) : .clear,
                        in: shape)
            .overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
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
            #if os(tvOS)
            // One size with the capsules beside it (build 28); .headline
            // was 38 pt on tvOS and dwarfed its neighbours.
            .font(.system(size: 26, weight: .semibold))
            .padding(.horizontal, 30).padding(.vertical, 14)
            #else
            .font(.headline)
            .padding(.horizontal, 26).padding(.vertical, 14)
            #endif
            .foregroundStyle(.white)
            .background(Color.pigAccent, in: Capsule())
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

// Selection chips (guide categories, Jump to… days and hours, recording
// padding). Category chips share the app's pink language: focus is the bright pink
// outline + translucent pink fill; the current category keeps a quieter pink
// tint so it stays legible when focus moves elsewhere. Same treatment in both
// appearances (accent is identical; the neutral rest state adapts).
struct GuideFilterStyle: ButtonStyle {
    var selected = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GuideTypography.body)
            .foregroundStyle(selected && !focused ? Color.pigAccent : Color.primary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(focused ? Color.pigAccent.opacity(0.22)
                        : selected ? Color.pigAccent.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(focused ? Color.pigAccent
                    : selected ? Color.pigAccent.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: focused ? 3 : 1)
            }
    }
}

struct PigPageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color.black : Color.white).ignoresSafeArea()
    }
}
