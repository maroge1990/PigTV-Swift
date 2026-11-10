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

/// "UHD" / "HD" / "SD": UHD in pink, the others outlined.
struct QualityBadge: View {
    let quality: SportQuality
    var body: some View {
        Text(quality.rawValue)
            .font(SportMetrics.detail.weight(.bold)).monospaced()
            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xxs)
            .foregroundStyle(quality == .uhd ? Color.pigOnAccent : Color.secondary)
            .background(quality == .uhd ? Color.pigAccent : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(quality == .uhd ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5) }
            .accessibilityLabel(quality.spoken)
    }
}
