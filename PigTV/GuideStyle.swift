import SwiftUI

// The guide's shared look (split out of GuideView.swift in build 39): tiles, the retry banner,
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // The only app-provided artwork backing: one neutral translucent
            // tile, the same for every channel, with the logo inset so it
            // never touches the tile edge.
            RoundedRectangle(cornerRadius: 10).fill(Color.logoTile(scheme))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                Text(name).font(GuideTypography.small.weight(.semibold)).lineLimit(3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RetryBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.callout)
            Spacer()
            Button("Retry", action: retry)
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
    }
}

enum GuideMetrics {
    // The single guide spacing: between the logo tile and the first cell,
    // between cells in a row, and between rows.
    static let gap: CGFloat = 8
    static var inset: CGFloat { gap / 2 }
}

enum GuideTypography {
    static var body: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .subheadline
        #endif
    }
    static var small: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .caption
        #endif
    }
    static var title: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title3.bold()
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
        scheme == .dark ? Color(white: 0.42).opacity(0.38) : Color(white: 0.22).opacity(0.42)
    }
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        Color.pigCanvas
    }
}
