import SwiftUI

// Sizes and the quality badge the sport pages and cards share.

enum SportMetrics {
    #if os(tvOS)
    static let cardWidth: CGFloat = 380
    static let cardPadding: CGFloat = 20
    static let cardSpacing: CGFloat = 30
    static let sectionSpacing: CGFloat = 30
    static let pagePadding: CGFloat = 0
    static let radius = PigRadius.card
    static let logo = CGSize(width: 112, height: 63)
    static let rowLogo = CGSize(width: 136, height: 76)
    static let league: Font = .system(size: PigType.caption, weight: .bold)
    static let title: Font = .system(size: PigType.body, weight: .semibold)
    static let detail: Font = .system(size: PigType.secondary)
    static let sectionTitle: Font = .system(size: PigType.cardTitle, weight: .bold)
    #else
    static let cardWidth: CGFloat = 264
    static let cardPadding: CGFloat = 14
    static let cardSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 24
    static let pagePadding: CGFloat = 20
    static let radius = PigRadius.card
    static let logo = CGSize(width: 64, height: 36)
    static let rowLogo = CGSize(width: 72, height: 40)
    static let league: Font = .caption.bold()
    static let title: Font = .subheadline.weight(.semibold)
    static let detail: Font = .caption
    static let sectionTitle: Font = .title3.bold()
    #endif
}

/// D-65/D-67 (#265): the one quality badge every channel list, picker and player draws. Measured: "4K · 50", 4K in the
/// accent fill, the others on the raised surface; unmeasured: the name's label ("4K", "1080", "HD", "SD") in a dashed
/// outline. Nothing is drawn for a channel with neither (callers skip it: `QualityChip.make` is nil).
struct QualityBadge: View {
    let chip: QualityChip
    var font: Font = SportMetrics.detail.weight(.bold)
    /// On the players' dark panels: a translucent white surface instead of the raised one.
    var onDark = false

    init(chip: QualityChip, font: Font = SportMetrics.detail.weight(.bold), onDark: Bool = false) {
        self.chip = chip; self.font = font; self.onDark = onDark
    }

    /// A name-derived quality (no measurement): the dashed badge.
    init(quality: SportQuality) {
        // `make` never returns nil for a quality.
        self.init(chip: QualityChip.make(measured: nil, quality: quality)
                  ?? QualityChip(tier: 3, measured: false, fps: nil, text: quality.rawValue, spoken: quality.spoken))
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: PigRadius.inner, style: .continuous) }

    private var text: Color {
        if chip.accent { return .pigOnAccent }
        return onDark ? .pigMediaText : .pigSecondary
    }

    private var fill: Color {
        if chip.accent { return .pigAccent }
        if !chip.measured { return .clear }
        return onDark ? Color.pigMediaText.opacity(0.22) : .pigRaised
    }

    var body: some View {
        Text(chip.text)
            .font(font).pigFigures().lineLimit(1).fixedSize()
            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xxs)
            .foregroundStyle(text)
            .background(fill, in: shape)
            .overlay {
                if !chip.measured {
                    shape.strokeBorder((onDark ? Color.pigMediaText : Color.pigSecondary).opacity(0.7),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chip.spoken)
    }
}

/// D-65: a sideways row of quality chips kept inside its card. When the chips overflow, the end with chips out of sight
/// fades (the scroll cue). `inset` is room inside the clip for a focused chip's lift and ring (tvOS); the row gives it back
/// outside, so the chips still line up with the words above them.
struct ChipScroller<Content: View>: View {
    var inset: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @State private var visible: Double = 0
    @State private var contentWidth: Double = 0
    @State private var offset: Double = 0

    private static var fade: CGFloat {
        #if os(tvOS)
        60
        #else
        28
        #endif
    }

    var body: some View {
        let edges = ChipFade.edges(content: contentWidth, visible: visible, offset: offset)
        ScrollView(.horizontal) {
            content()
                .padding(inset)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chipScroller")) } action: { frame in
                    contentWidth = frame.width
                    offset = -frame.minX
                }
        }
        .coordinateSpace(.named("chipScroller"))
        .scrollIndicators(.hidden)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { visible = $0 }
        .mask {
            let edge = visible > 0 ? min(0.4, Self.fade / visible) : 0
            LinearGradient(stops: [
                .init(color: edges.leading ? .clear : Color.pigMediaCanvas, location: 0),
                .init(color: Color.pigMediaCanvas, location: edge),
                .init(color: Color.pigMediaCanvas, location: 1 - edge),
                .init(color: edges.trailing ? .clear : Color.pigMediaCanvas, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .padding(-inset)
    }
}
