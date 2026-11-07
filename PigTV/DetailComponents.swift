import SwiftUI

// Build 28 consistency pass: the parts every detail screen is built from, so
// Programme, Channel, Schedule, Recording, Search, Jump to… and the sign-in
// screens share one language with Home and the guide: the page background,
// a hero card over the channel's blurred logo colours, `guideCell` surfaces,
// the pink focus family (PigSecondaryButtonStyle / PigSurfaceButtonStyle /
// PigPrimaryButtonStyle / GuideFilterStyle) and one type scale.

/// Type scale for detail screens (tvOS sizes; iOS uses text styles).
enum DetailType {
    #if os(tvOS)
    static let title: Font = .system(size: PigType.hero, weight: .bold)
    static let pageTitle: Font = .system(size: PigType.sectionTitle, weight: .bold)
    static let channel: Font = .system(size: PigType.cardTitle, weight: .semibold)
    static let meta: Font = .system(size: PigType.body, weight: .medium)
    static let body: Font = .system(size: PigType.cardTitle)
    static let rowTitle: Font = .system(size: PigType.cardTitle, weight: .semibold)
    static let rowDetail: Font = .system(size: PigType.secondary)
    static let eyebrow: Font = .system(size: PigType.secondary, weight: .bold)
    static let section: Font = .system(size: PigType.body, weight: .semibold)
    static let button: Font = .system(size: PigType.body, weight: .medium)
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
    static let smallLogo = CGSize(width: 104, height: 58)
    static let timeColumn: CGFloat = 170
    static let spacing: CGFloat = PigSpacing.xl
    static let radius = PigRadius.hero
    #else
    static let pageWidth: CGFloat = 820
    static let readingWidth: CGFloat = 680
    static let heroPadding: CGFloat = 20
    static let logo = CGSize(width: 112, height: 63)
    static let smallLogo = CGSize(width: 72, height: 40)
    static let timeColumn: CGFloat = 84
    static let spacing: CGFloat = PigSpacing.xl
    static let radius = PigRadius.hero
    #endif
}

/// A full-screen detail page: the app's page background, a scroll view, and
/// content at a comfortable width. iOS gets a Done button (tvOS uses Menu).
struct DetailPage<Content: View>: View {
    var title: String? = nil
    /// D-44 (#49): pushed on a tab's NavigationStack (Back pops; the system back button on iOS, a "‹ TV Guide"
    /// caption on the TV) instead of presented over it.
    var pushedFrom: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let pushedFrom {
            scroll(back: pushedFrom)
                .background(PigPageBackground())
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } else {
            NavigationStack {
                scroll(back: nil)
                    .background(PigPageBackground())
                    #if os(iOS)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    #endif
            }
            .presentationBackground { PigPageBackground() }
        }
    }

    private func scroll(back: String?) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    #if os(tvOS)
                    if let back {
                        Label(back, systemImage: "chevron.left").font(DetailType.rowDetail.weight(.semibold))
                            .foregroundStyle(Color.pigSecondary).accessibilityHidden(true)
                    }
                    #endif
                    if let title {
                        HStack(spacing: PigSpacing.m) {
                            PigBrandMark(width: 58, height: 48)
                                .accessibilityHidden(true)
                            Text(title).font(DetailType.pageTitle)
                        }
                    }
                    content
                }
                #if os(tvOS)
                .padding(.vertical, PigSpacing.l)
                #else
                .padding(PigSpacing.xl)
                #endif
                .frame(maxWidth: DetailMetrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            #if os(tvOS)
            // Covers and sheets do not always inherit the app's default.
            .buttonStyle(PigSecondaryButtonStyle())
            #endif
    }
}

/// D-44 (Apple 108): a page's hero card (R5-Programme-*, R5-Channel-*): the surface at the hero radius, no wash.
struct PigHeroCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) { content }
            .padding(DetailMetrics.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
    }
}

/// A recording state as a word in its colour: "Recording scheduled" with the red dot over a 14 % red fill.
struct StatusPill: View {
    let text: String
    var colour: Color = .pigDanger
    var body: some View {
        HStack(spacing: PigSpacing.s) {
            Circle().fill(colour).frame(width: 11, height: 11).accessibilityHidden(true)
            Text(text)
        }
        .font(DetailType.eyebrow)
        .foregroundStyle(colour)
        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
        .background(colour.opacity(0.14), in: Capsule())
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
            Color.pigSurface
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
                // The wash fades into the page canvas (its role, both appearances) so text reads over the artwork.
                LinearGradient(colors: scheme == .dark
                               ? [Color.pigCanvas.opacity(0.82), Color.pigCanvas.opacity(0.55), Color.pigCanvas.opacity(0.2)]
                               : [Color.pigCanvas.opacity(0.9), Color.pigCanvas.opacity(0.7), Color.pigCanvas.opacity(0.35)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, Color.pigCanvas.opacity(0.35)],
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
        VStack(alignment: .leading, spacing: PigSpacing.m) { content }
            .padding(DetailMetrics.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { LogoWash(logo: logo, client: client) }
            .clipShape(RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous)
                    .strokeBorder(Color.pigBorder, lineWidth: 1)
            }
            .shadow(color: Color.pigShadow.opacity(scheme == .dark ? 0.5 : 0.12), radius: 26, y: 14)
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
            RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).fill(Color.logoTile(scheme))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, size.width * 0.1).padding(.vertical, size.height * 0.12)
            } else {
                Text(name).font(DetailType.rowDetail.weight(.semibold)).multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.6).padding(PigSpacing.s)
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
        HStack(spacing: PigSpacing.l) {
            ChannelLogoTile(logo: logo, client: client, name: name)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(name).lineLimit(1).font(DetailType.channel)
                    if let number { ChannelNumberText(number: String(number), font: DetailType.meta) }
                }
                if let detail {
                    Text(detail).font(DetailType.meta).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// C-A, build 29: a channel number as small, muted text placed after the
/// channel's name, never over artwork (Mark: numbers are secondary to him).
/// `Text(verbatim:)` so it is never locale-grouped.
struct ChannelNumberText: View {
    let number: String
    let font: Font
    /// Over the player's always-dark chrome use a fixed white; elsewhere the
    /// hierarchy's tertiary style.
    var onDark = false
    var body: some View {
        Text(verbatim: number).font(font).monospacedDigit().fontDesign(.rounded)
            .foregroundStyle(onDark ? AnyShapeStyle(Color.pigMediaText.opacity(0.5)) : AnyShapeStyle(.tertiary))
    }
}

/// Small uppercase label above a title ("ON NOW", "TOMORROW").
struct Eyebrow: View {
    let text: String
    var colour: Color = .pigAccentText
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
        HStack(spacing: PigSpacing.s) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(DetailType.eyebrow)
        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.xs)
        .background(colour, in: Capsule())
        .foregroundStyle(colour == .pigAccent ? Color.pigOnAccent : Color.pigOnStatus)
    }
}

/// The pink progress bar (Home cards, detail heroes).
struct PigProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pigBorder)
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
            .padding(.top, PigSpacing.s)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The row of actions under a hero. On tvOS it is a focus section so Down
/// from the hero lands in it.
struct DetailActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(tvOS)
        HStack(spacing: PigSpacing.l) { content }
            .font(DetailType.button)
            .focusSection()
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PigSpacing.m) { content }
            VStack(alignment: .leading, spacing: PigSpacing.m) { content }
        }
        .buttonStyle(PigSecondaryButtonStyle()) // #243: the one primary keeps its own style
        #endif
    }
}

/// Favourite toggle for detail screens: reads and writes BrowseModel's
/// favourites (so the guide's Favourites filter and Home agree at once).
struct FavouriteButton: View {
    let model: BrowseModel
    @ObservedObject private var library: LibraryStore
    let channel: Channel
    @State private var busy = false
    @State private var failed = false

    init(model: BrowseModel, channel: Channel) {
        self.model = model
        _library = ObservedObject(wrappedValue: model.library)
        self.channel = channel
    }

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
    /// Keep native field surfaces and focus rendering on both platforms.
    @ViewBuilder
    func pigField() -> some View {
        #if os(tvOS)
        // Preserve the existing footprint without a second shape behind the native capsule.
        self.padding(.horizontal, PigSpacing.xs).padding(.vertical, PigSpacing.xxs)
        #else
        self.textFieldStyle(.roundedBorder)
        #endif
    }

    /// A detail page over the current one: full screen on tvOS (a tvOS
    /// sheet is a narrow panel), a sheet on iOS. #14: every such page closes when playback is started from outside it
    /// (a Top Shelf channel, a "watch when it starts" timer): the player cannot present over a cover.
    @ViewBuilder
    func detailCover<Item: Identifiable, Page: View>(item: Binding<Item?>, @ViewBuilder page: @escaping (Item) -> Page) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in item.wrappedValue = nil }
        #else
        sheet(item: item, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in item.wrappedValue = nil }
        #endif
    }

    /// As above, with an action once the page has gone (play after a
    /// cover closes: the player cannot present over another cover).
    @ViewBuilder
    func detailCover<Item: Identifiable, Page: View>(item: Binding<Item?>, onDismiss: @escaping () -> Void,
                                                     @ViewBuilder page: @escaping (Item) -> Page) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, onDismiss: onDismiss, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in item.wrappedValue = nil }
        #else
        sheet(item: item, onDismiss: onDismiss, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in item.wrappedValue = nil }
        #endif
    }

    @ViewBuilder
    func detailCover<Page: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder page: @escaping () -> Page) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in isPresented.wrappedValue = false }
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: page)
            .onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in isPresented.wrappedValue = false }
        #endif
    }
}

extension Notification.Name {
    /// #14: close every detail page, so the player can present (AppModel.playOverCovers).
    static let pigCloseCovers = Notification.Name("PigTV.closeCovers")
}

extension View {
    /// #179: a screen's own fullScreenCover or sheet (not a `detailCover`) closes for a play started from outside the
    /// screen too: `close` sets its presentation state back.
    func closesForOutsidePlay(_ close: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .pigCloseCovers)) { _ in close() }
    }
}

extension GuideProgramme {
    /// "8:30 – 10:00 pm".
    nonisolated var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
    /// "1 h 30 min", "45 min".
    nonisolated var durationText: String { DetailText.duration(end.timeIntervalSince(start)) }
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
