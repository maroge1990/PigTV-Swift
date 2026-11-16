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
        return onDark ? .white : .pigSecondary
    }

    private var fill: Color {
        if chip.accent { return .pigAccent }
        if !chip.measured { return .clear }
        return onDark ? Color.white.opacity(0.22) : .pigRaised
    }

    var body: some View {
        Text(chip.text)
            .font(font).monospacedDigit().lineLimit(1).fixedSize()
            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xxs)
            .foregroundStyle(text)
            .background(fill, in: shape)
            .overlay {
                if !chip.measured {
                    shape.strokeBorder((onDark ? Color.white : Color.pigSecondary).opacity(0.7),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chip.spoken)
    }
}
