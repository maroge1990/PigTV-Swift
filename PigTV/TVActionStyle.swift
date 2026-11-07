import SwiftUI

// Approved Pig family palette. Native control geometry and focus traversal are retained.
extension Color {
    /// PigTV pink, from the asset catalogue. `Color.accentColor` is not used:
    /// on tvOS it resolved to white outside a NavigationStack (the
    /// unreachable and sign-in screens showed blank white primary buttons).
    static let pigAccent = Color("AccentColor")
    // The rose over video (kit §7) is the catalog's PigMediaAccent (Color.pigMediaAccent).
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

/// #243: the one secondary action (Record beside Watch, Channel schedule, Details, Delete, Open …, Cancel). Only a
/// screen's one primary action has the accent fill (`pigPrimaryButton()`). On tvOS a dark capsule with the shared focus
/// ring (also the app-wide default there); on touch a neutral capsule with secondary text, never the accent.
struct PigSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
            .modifier(PigFocusSurface(focused: focused, scheme: scheme, shape: AnyShape(Capsule())))
        #else
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
            .foregroundStyle(Color("PigSecondary"))
            .background(Color("PigRaised"), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.pigBorder, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.45)
            .contentShape(Capsule())
        #endif
    }
}

// List row / cell. Rounded-rect; optionally suppresses its own surface when the
// content already draws one (`drawSurface: false`).
struct PigSurfaceButtonStyle: ButtonStyle {
    var drawSurface = true
    var cornerRadius: CGFloat = PigRadius.compact
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PigFocusSurface(focused: focused, scheme: scheme,
                                      shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius)), drawSurface: drawSurface))
    }
}

/// D-44 (Apple 107): a row of the long-press menu: nothing drawn until focused (tvOS) or pressed (touch), then the shared
/// focus look, a pink ring over a 22 % pink fill.
struct PigMenuRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        let on = focused || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous)
        configuration.label
            .foregroundStyle(Color("PigText"))
            .background(on ? Color.pigAccent.opacity(0.22) : .clear, in: shape)
            .overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .scaleEffect(focused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
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
            .font(.system(size: PigType.cardTitle, weight: .semibold))
            .padding(.horizontal, PigSpacing.xl).padding(.vertical, PigSpacing.s)
            #else
            .font(.headline)
            .padding(.horizontal, PigSpacing.xl).padding(.vertical, PigSpacing.l)
            #endif
            .foregroundStyle(Color.pigOnAccent)
            .background(Color.pigAccent, in: Capsule())
            .overlay { Capsule().strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3).padding(-PigSpacing.ringOutset).allowsHitTesting(false) }
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    /// A secondary action (#243): the same look on every screen of a platform.
    func pigSecondaryButton() -> some View { buttonStyle(PigSecondaryButtonStyle()) }

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
            .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            .background(selected ? Color.pigAccent.opacity(0.14) : Color.pigRaised, in: Capsule())
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(Color.pigAccent).frame(width: 26, height: 3)
                        .padding(.bottom, PigSpacing.xs).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay {
                Capsule().strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3).padding(-PigSpacing.ringOutset)
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


/// The one page header every tab draws (16 Oct: Home, Guide, Sport, Recordings and Settings each had their own, so
/// the pig and the title changed size, font or vanished between tabs). Pig mark, title, an optional secondary line
/// (Home's and Guide's date), then trailing controls. Same mark and type on every tab of a platform.
/// 18 Oct (test team: the pig and title still moved between tabs): the header also owns its placement. It insets itself
/// from the page's leading edge by `PigPageHeaderMetrics.edge` and is always `rowHeight` tall, with taller trailing
/// controls overflowing rather than re-centring the row, so a page places it at its top-leading corner with no padding of
/// its own (PageHeaderPlacementUITests).
struct PigPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: Text? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: PigPageHeaderMetrics.spacing) {
            PigBrandMark(width: PigPageHeaderMetrics.markWidth, height: PigPageHeaderMetrics.markHeight)
            Text(title).font(PigPageHeaderMetrics.title).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("page.header.title")
            if let subtitle {
                subtitle.font(GuideTypography.body).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: PigPageHeaderMetrics.rowHeight)
        .padding(.horizontal, PigPageHeaderMetrics.edge)
    }
}

extension PigPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: Text? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

nonisolated enum PigPageHeaderMetrics {
    #if os(tvOS)
    static let markWidth: CGFloat = 58
    static let markHeight: CGFloat = 48
    /// The row is the pig's height on every tab, whatever the trailing controls need.
    static let rowHeight: CGFloat = markHeight
    static let spacing: CGFloat = PigSpacing.s
    /// From the safe area's leading edge (where Home and Sport already drew it).
    static let edge: CGFloat = 0
    static var title: Font { .system(size: PigType.sectionTitle, weight: .bold) }
    #else
    // #226 (Mark, 4 Nov 2026): every iPhone and iPad tab takes the Sport page's pig (34 x 28 at a 16 pt edge), and the
    // title is smaller and lighter than the Sport page's 34 pt heavy: 22 pt semibold (title2), level with the pig. Before
    // Apple 147 the Sport tab drew its own header and the other tabs a 58 x 48 pig with a 20 pt bold title at 20 pt.
    static let markWidth: CGFloat = 34
    static let markHeight: CGFloat = 28
    /// One touch row on every tab, whatever the trailing controls need.
    static let rowHeight: CGFloat = 44
    static let spacing: CGFloat = PigSpacing.m
    static let edge: CGFloat = 16
    static var title: Font { .title2.weight(.semibold) }
    #endif
}

/// Sign-in brand block: a static halo (the splash's values) centred on the pig mark only, on top of the page's
/// corner-bloom canvas (OnboardingView sits on `PigPageBackground`). No card fill, and nothing behind the text fields:
/// radiance stays off forms. The pig is the stacked lockup's, `markInkWidth` wide, at the block's top leading padding.
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
                            y: DetailMetrics.heroPadding + PigLockup.pigInkHeight(forWidth: Self.markInkWidth) / 2 - r)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
