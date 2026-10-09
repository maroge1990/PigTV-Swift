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
        self.buttonStyle(.glassProminent).tint(Color.pigAccent).foregroundStyle(Color.pigOnAccent)
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

/// The in-app canvas (brand 1.6): the canvas colour with one rose radial gradient from the top leading corner
/// (mirrored for right-to-left layouts), fading out by 0.62 of the canvas diagonal. Plain canvas with Reduce
/// Transparency. Cards, bars and controls sit opaque above it. `PageBackdrop` paints the same gradient into UIKit
/// containers' layers, so a UIKit-hosted screen shows this canvas too (see PageBackdrop.swift).
struct PigPageBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            let diagonal = hypot(geometry.size.width, geometry.size.height)
            ZStack {
                Color.pigCanvas
                if !reduceTransparency {
                    RadialGradient(stops: BrandLayout.cornerBloom(dark: scheme == .dark).gradientStops,
                                   center: layoutDirection == .rightToLeft ? .topTrailing : .topLeading,
                                   startRadius: 0, endRadius: diagonal * BrandLayout.cornerBloomRadiusOfDiagonal)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension [BrandLayout.Stop] {
    /// The stops as SwiftUI gradient stops (sRGB).
    var gradientStops: [Gradient.Stop] {
        map { Gradient.Stop(color: Color(.sRGB, red: $0.r / 255, green: $0.g / 255, blue: $0.b / 255, opacity: $0.a), location: $0.at) }
    }
}

/// The pig mark (the PigTV product pig, vector). `width` x `height` is the footprint the pig's ink used to fill (the old
/// raster was ink-wide, 1000:797); mark.svg is a 1024 square with the pig optically centred, ink about 65% of its width,
/// so the square is sized by the ink fraction and centred: the pig stays the same size on screen.
struct PigBrandMark: View {
    var width: CGFloat
    var height: CGFloat
    var body: some View {
        let inkWidth = min(width, height * 1000 / 797)
        let side = inkWidth / BrandLayout.markInkFraction
        Image("PigLogo").resizable().scaledToFit().frame(width: side, height: side)
            .frame(width: width, height: height)
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
            .frame(width: height * BrandLayout.wordmarkAspect, height: height)
            .accessibilityLabel("PigTV")
    }
}

/// Sign-in brand block: a static halo (the splash's values) centred on the pig mark only, on top of the page's
/// corner-bloom canvas (OnboardingView sits on `PigPageBackground`). No card fill, and nothing behind the text fields:
/// radiance stays off forms. The mark is `PigBrandMark(width: 150, ...)` at the block's top leading padding.
struct PigIdentityBackdrop: View {
    static let markInkWidth: CGFloat = 150
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment: .topLeading) {
            if !reduceTransparency {
                let r = BrandLayout.haloRadius / BrandLayout.pigInkWidth * Self.markInkWidth
                RadialGradient(stops: BrandLayout.halo(dark: scheme == .dark).gradientStops,
                               center: .center, startRadius: 0, endRadius: r)
                    .frame(width: 2 * r, height: 2 * r)
                    .offset(x: DetailMetrics.heroPadding + Self.markInkWidth / 2 - r,
                            y: DetailMetrics.heroPadding + 60 - r)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
