import SwiftUI

// Approved Pig family palette. Native control geometry and focus traversal are retained.
extension Color {
    /// PigTV pink, from the asset catalogue. `Color.accentColor` is not used:
    /// on tvOS it resolved to white outside a NavigationStack (the
    /// unreachable and sign-in screens showed blank white primary buttons).
    static let pigAccent = Color("AccentColor")
    static let pigMediaAccent = Color(red: 239/255, green: 122/255, blue: 174/255)
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

// Primary action: appearance-specific label contrast, separate focus ring and existing lift.
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
            .foregroundStyle(Color.pigOnAccent)
            .background(Color.pigAccent, in: Capsule())
            .overlay { Capsule().strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3).padding(-5).allowsHitTesting(false) }
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
        self.buttonStyle(.borderedProminent).foregroundStyle(Color.pigOnAccent)
        #endif
    }
}

// Selection persists as an inset bar and tint; focus is an independent outer ring.
struct GuideFilterStyle: ButtonStyle {
    var selected = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GuideTypography.body)
            .foregroundStyle(selected ? Color.pigAccentText : Color("PigText"))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(selected ? Color.pigAccent.opacity(0.14) : Color.pigRaised, in: Capsule())
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(Color.pigAccent).frame(width: 26, height: 3)
                        .padding(.bottom, 4).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay {
                Capsule().strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3).padding(-4)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PigPageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Color.pigCanvas.ignoresSafeArea()
    }
}


/// The measured alpha centre, inside the same footprint as the former image.
struct PigBrandMark: View {
    var width: CGFloat
    var height: CGFloat
    var body: some View {
        let drawnWidth = min(width, height * 1000 / 797)
        let drawnHeight = drawnWidth * 797 / 1000
        Image("PigLogo").resizable().scaledToFit().frame(width: width, height: height)
            .offset(x: (0.5 - BrandLayout.pigCentroidX) * drawnWidth,
                    y: (0.5 - BrandLayout.pigCentroidY) * drawnHeight)
            .accessibilityHidden(true)
    }
}


struct PigWordmark: View {
    #if os(tvOS)
    private let height: CGFloat = 52
    #else
    @ScaledMetric(relativeTo: .title) private var height: CGFloat = 28
    #endif
    var body: some View {
        Image("BrandWordmark").resizable().scaledToFit()
            .frame(width: height * 1552 / 528, height: height)
            .accessibilityLabel("PigTV")
    }
}

/// A quiet, non-interactive halo centred behind the existing sign-in pig.
struct PigIdentityBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.pigSurface
                if !reduceTransparency {
                    RadialGradient(colors: [Color.pigMediaAccent.opacity(0.24), .clear],
                                   center: UnitPoint(x: (DetailMetrics.heroPadding + 75) / max(1, geometry.size.width),
                                                     y: (DetailMetrics.heroPadding + 60) / max(1, geometry.size.height)),
                                   startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.65)
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
