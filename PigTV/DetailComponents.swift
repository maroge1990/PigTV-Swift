import SwiftUI

// Build 28 consistency pass: the parts every detail screen is built from, so
// Programme, Channel, Schedule, Recording, Search, Jump to… and the sign-in
// screens share one language with Home and the guide: the page background,
// a hero card over the channel's blurred logo colours, `guideCell` surfaces,
// the pink focus family (TVActionStyle / PigSurfaceButtonStyle /
// PigPrimaryButtonStyle / GuideFilterStyle) and one type scale.

/// Type scale for detail screens (tvOS sizes; iOS uses text styles).
enum DetailType {
    #if os(tvOS)
    static let title: Font = .system(size: 52, weight: .bold)
    static let pageTitle: Font = .system(size: 34, weight: .bold)
    static let channel: Font = .system(size: 26, weight: .semibold)
    static let meta: Font = .system(size: 24, weight: .medium)
    static let body: Font = .system(size: 25)
    static let rowTitle: Font = .system(size: 26, weight: .semibold)
    static let rowDetail: Font = .system(size: 21)
    static let eyebrow: Font = .system(size: 20, weight: .bold)
    static let section: Font = .system(size: 24, weight: .semibold)
    static let button: Font = .system(size: 24, weight: .medium)
    #else
    static let title: Font = .title.bold()
    static let pageTitle: Font = .title2.bold()
    static let channel: Font = .headline
    static let meta: Font = .subheadline
    static let body: Font = .body
    static let rowTitle: Font = .headline
    static let rowDetail: Font = .subheadline
    static let eyebrow: Font = .caption.bold()
    static let section: Font = .headline
    static let button: Font = .body
    #endif
}

enum DetailMetrics {
    #if os(tvOS)
    static let pageWidth: CGFloat = .infinity
    static let readingWidth: CGFloat = 1100
    static let heroPadding: CGFloat = 52
    static let logo = CGSize(width: 208, height: 117)
    static let spacing: CGFloat = 30
    static let radius: CGFloat = 32
    #else
    static let pageWidth: CGFloat = 820
    static let readingWidth: CGFloat = 680
    static let heroPadding: CGFloat = 20
    static let logo = CGSize(width: 112, height: 63)
    static let spacing: CGFloat = 20
    static let radius: CGFloat = 22
    #endif
}

/// A full-screen detail page: the app's page background, a scroll view, and
/// content at a comfortable width. iOS gets a Done button (tvOS uses Menu).
struct DetailPage<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    if let title {
                        HStack(spacing: 14) {
                            Image("PigLogo").resizable().scaledToFit().frame(width: 58, height: 48)
                                .accessibilityHidden(true)
                            Text(title).font(DetailType.pageTitle)
                        }
                    }
                    content
                }
                #if os(tvOS)
                .padding(.vertical, 24)
                #else
                .padding(20)
                #endif
                .frame(maxWidth: DetailMetrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .background(PigPageBackground())
            #if os(tvOS)
            // Covers and sheets do not always inherit the app's default.
            .buttonStyle(TVActionStyle())
            #endif
            #if os(iOS)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #endif
        }
        .presentationBackground { PigPageBackground() }
    }
}

/// The logo's own colours, scaled up, blurred and dimmed (Home's hero wash);
/// a pink glow without a logo; a plain surface with Reduce Transparency.
struct LogoWash: View {
    let logo: String?
    let client: APIClient?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(white: 0.07) : Color(white: 0.97))
            if !reduceTransparency {
                if logo != nil {
                    ChannelArtwork(logo: logo, client: client, fill: true)
                        .scaleEffect(1.8)
                        .blur(radius: 90)
                        .saturation(1.6)
                        .opacity(scheme == .dark ? 0.75 : 0.45)
                        .allowsHitTesting(false)
                } else {
                    RadialGradient(colors: [Color.pigAccent.opacity(scheme == .dark ? 0.45 : 0.25), .clear],
                                   center: .topTrailing, startRadius: 40, endRadius: 900)
                }
                LinearGradient(colors: scheme == .dark
                               ? [.black.opacity(0.82), .black.opacity(0.55), .black.opacity(0.2)]
                               : [.white.opacity(0.9), .white.opacity(0.7), .white.opacity(0.35)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, (scheme == .dark ? Color.black : Color.white).opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hero card at the top of a detail page: content over a LogoWash.
struct DetailHero<Content: View>: View {
    let logo: String?
    let client: APIClient?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(DetailMetrics.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { LogoWash(logo: logo, client: client) }
            .clipShape(RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.12), radius: 26, y: 14)
    }
}

/// The channel's logo tile (the guide's neutral tile, adaptive).
struct ChannelLogoTile: View {
    let logo: String?
    let client: APIClient?
    let name: String
    var size = DetailMetrics.logo
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.logoTile(scheme))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, size.width * 0.1).padding(.vertical, size.height * 0.12)
            } else {
                Text(name).font(DetailType.rowDetail.weight(.semibold)).multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.6).padding(10)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// Logo tile, number and name: the channel line at the top of a hero.
struct ChannelLine: View {
    let logo: String?
    let client: APIClient?
    let name: String
    let number: Int?
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 24) {
            ChannelLogoTile(logo: logo, client: client, name: name)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if let number { NumberCapsule(number: number) }
                    Text(name).lineLimit(1)
                }
                .font(DetailType.channel)
                if let detail {
                    Text(detail).font(DetailType.meta).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NumberCapsule: View {
    let number: Int
    var body: some View {
        Text(verbatim: String(number)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }
}

/// Small uppercase label above a title ("ON NOW", "TOMORROW").
struct Eyebrow: View {
    let text: String
    var colour: Color = .pigAccent
    var body: some View {
        Text(text.uppercased()).font(DetailType.eyebrow).tracking(2.5).foregroundStyle(colour)
    }
}

/// A status capsule ("Recording scheduled", "Recorded", "REC").
struct StatusBadge: View {
    let text: String
    var systemImage: String? = nil
    var colour: Color = .pigAccent
    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(DetailType.eyebrow)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(colour, in: Capsule())
        .foregroundStyle(.white)
    }
}

/// The pink progress bar (Home cards, detail heroes).
struct PigProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.pigAccent)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A section heading on a detail page (Settings uses the same).
struct PigSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(DetailType.section).foregroundStyle(.secondary)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The row of actions under a hero. On tvOS it is a focus section so Down
/// from the hero lands in it.
struct DetailActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 24) { content }
            .font(DetailType.button)
            .focusSection()
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(alignment: .leading, spacing: 12) { content }
        }
        .buttonStyle(.bordered)
        #endif
    }
}

/// Favourite toggle for detail screens: reads and writes BrowseModel's
/// favourites (so the guide's Favourites filter and Home agree at once).
struct FavouriteButton: View {
    @ObservedObject var model: BrowseModel
    let channel: Channel
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        let saved = model.isFavourite(channel)
        Button {
            Task {
                busy = true
                failed = !(await model.setFavourite(channel, !saved))
                busy = false
            }
        } label: {
            Label(failed ? "Try again" : (saved ? "In favourites" : "Add to favourites"),
                  systemImage: saved ? "heart.fill" : "heart")
        }
        .disabled(busy)
        .accessibilityValue(saved ? "In favourites" : "Not in favourites")
        .accessibilityIdentifier("details.favourite")
    }
}

extension View {
    /// A text field on the guide's surface (tvOS draws an unfocused field as
    /// bare text); the system field style on iOS.
    @ViewBuilder
    func pigField() -> some View {
        #if os(tvOS)
        self.padding(.horizontal, 8).padding(.vertical, 4)
            .modifier(FieldSurface())
        #else
        self.textFieldStyle(.roundedBorder)
        #endif
    }

    /// A detail page over the current one: full screen on tvOS (a tvOS
    /// sheet is a narrow panel), a sheet on iOS.
    @ViewBuilder
    func detailCover<Item: Identifiable, Page: View>(item: Binding<Item?>, @ViewBuilder page: @escaping (Item) -> Page) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, content: page)
        #else
        sheet(item: item, content: page)
        #endif
    }

    @ViewBuilder
    func detailCover<Page: View>(isPresented: Binding<Bool>, @ViewBuilder page: @escaping () -> Page) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, content: page)
        #else
        sheet(isPresented: isPresented, content: page)
        #endif
    }
}

extension GuideProgramme {
    /// "8:30 – 10:00 pm".
    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
    /// "1 h 30 min", "45 min".
    var durationText: String { DetailText.duration(end.timeIntervalSince(start)) }
}

private struct FieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // A well the field sits in; tvOS draws its own platter only in some
        // states, so without it an unfocused field reads as bare text.
        content.background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

nonisolated enum DetailText {
    /// "1 h 30 min", "45 min", "2 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "Today", "Tomorrow", else "Saturday 27 September".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
