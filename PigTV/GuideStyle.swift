import SwiftUI

// The guide's shared look (split out of GuideView.swift in build 39): tiles (#280: the retry banner gave way to PigStaleNotice),
// metrics, typography and colours, also used by other screens.

// Logo tile for the channel column. The logo replaces the channel name; the
// name is only drawn here when no artwork is available.
struct ChannelTile: View {
    let name: String
    // Build 29: no channel number on the tile (Mark: it obscured logos and
    // is not important to him); numbers appear only as muted text beside a
    // channel's name (`ChannelNumberText`).
    let logo: String?
    let client: APIClient?
    /// The TV Guide's pinned tile under focus (#293): the focus fill over the backing, under the logo.
    var focused = false
    @Environment(\.colorScheme) private var scheme

    /// The focus fill a focused tile takes (#293: lift, ring and tint everywhere), nil at rest.
    static func focusFill(focused: Bool) -> Color? { focused ? PigFocus.fill : nil }

    var body: some View {
        ZStack {
            // The only app-provided artwork backing: one neutral translucent
            // tile, the same for every channel, with the logo inset so it
            // never touches the tile edge.
            RoundedRectangle(cornerRadius: PigRadius.compact).fill(Color.logoTile(scheme))
            if let tint = Self.focusFill(focused: focused) {
                RoundedRectangle(cornerRadius: PigRadius.compact).fill(tint)
            }
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
            } else {
                // Two lines at 23 pt fill the 72 pt tile on the television (#279); three on touch.
                Text(name).font(GuideTypography.small.weight(.semibold)).lineLimit(PigType.minimum > 0 ? 2 : 3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center).pigMinimumScale(0.7, size: PigType.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

enum GuideTypography {
    static var body: Font {
        #if os(tvOS)
        .system(size: PigType.body)
        #else
        .subheadline
        #endif
    }
    static var small: Font {
        #if os(tvOS)
        .system(size: PigType.secondary)
        #else
        .caption
        #endif
    }
}

// Lets a label style be chosen at runtime (SwiftUI's styles are distinct types).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension Color {
    // Guide surfaces: clearly separated from the page in both appearances.
    static func guideCell(_ scheme: ColorScheme) -> Color {
        Color.pigRaised
    }
    // Neutral translucent logo backing: darker in light mode so the tile is
    // clearly separated from the page, lighter grey in dark mode and over video.
    static func logoTile(_ scheme: ColorScheme) -> Color {
        Color.pigSecondary.opacity(scheme == .dark ? 0.38 : 0.42)
    }
}
