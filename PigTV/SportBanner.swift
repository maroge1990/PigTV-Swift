import SwiftUI
import ImageIO

// D-43 (1 Nov, DESIGN.md › Apple TV sport pages): the one banner on the Sport front page and on every sport page. 250 pt
// high under the app's tabs: the hero on the left (kicker, title, one line, Watch / Record or Remind me, over the faded
// badge or the F1 circuit map) and, split by a thin line, a list on the right inside the same banner: three items on the television (four on
// touch), then a "5 more · …" line; moving focus down scrolls the list inside the banner, which never grows. Selecting an item flips
// the hero (front page) or the league (sport page). With one item (one league) the banner runs full width, with no list
// and no line, and the badge or map moves to the right. The items are drawn in the order given (the server's: the
// account's order, anything playing now first, C-R since 0427); the banner never re-sorts them. What it draws of a game
// is the caller's: spoiler-free is applied before the hero's words reach it.

enum SportBannerMetrics {
    /// The backdrop's distance from the banner's edge: on the right when full width, past the list when split.
    static let artworkInsetFull: CGFloat = 80, artworkInsetSplit: CGFloat = 820
    static let mapInsetFull: CGFloat = 60, mapInsetSplit: CGFloat = 720
    #if os(tvOS)
    static let height: CGFloat = 250
    static let radius = PigRadius.hero
    static let padding = EdgeInsets(top: 20, leading: 32, bottom: 20, trailing: 22)
    static let listWidth: CGFloat = 540
    static let gap: CGFloat = 28
    static let listInset: CGFloat = 24
    /// Brand 1.8 §15 (#279): a list row is a 56 pt focus target with 23 pt text.
    static let row: CGFloat = 56
    static let rowGap: CGFloat = 8
    static let rowBadge: CGFloat = 32
    /// Room around the list's rows inside the list (which clips): a focused row's ring, lift and shadow
    /// (`PigFocusLift.listRow`) stay visible; less than `rowGap`, so a row outside the window never shows.
    static let focusRoom: CGFloat = 6
    /// The list column's own distance from the banner's top and bottom edges.
    static let listVertical: CGFloat = 8
    /// The "N more" count sits at the end of the header line (the three rows need the line below them).
    static let moreInHeader = true
    static let listSpacing: CGFloat = PigSpacing.xxs
    static let back: CGFloat = 56
    static let kicker: Font = .system(size: PigType.kicker, weight: .bold)
    static let title: Font = .system(size: PigType.pageTitle, weight: .heavy)
    static let wideTitle: Font = .system(size: PigType.pageTitle, weight: .heavy)
    static let line: Font = .system(size: PigType.secondary)
    static let listTitle: Font = .system(size: PigType.caption, weight: .bold)
    static let rowTitle: Font = .system(size: PigType.caption, weight: .bold)
    static let rowTrailing: Font = .system(size: PigType.caption, weight: .semibold)
    static let badgeSize: CGFloat = 300
    static let wideBadgeSize: CGFloat = 310
    static let map = CGSize(width: 420, height: 220)
    #else
    static let height: CGFloat = 220
    static let radius = PigRadius.hero
    static let padding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 16)
    static let listWidth: CGFloat = 340
    static let gap: CGFloat = 18
    static let listInset: CGFloat = 16
    static let row: CGFloat = 32
    static let rowGap: CGFloat = 5
    static let rowBadge: CGFloat = 20
    static let focusRoom: CGFloat = 0
    static let listVertical: CGFloat = 16
    static let moreInHeader = false
    static let listSpacing: CGFloat = rowGap
    static let back: CGFloat = 44
    static let kicker: Font = .caption.weight(.bold)
    static let title: Font = .title.weight(.heavy)
    static let wideTitle: Font = .title.weight(.heavy)
    static let line: Font = .subheadline
    static let listTitle: Font = .caption2.weight(.bold)
    static let rowTitle: Font = .subheadline.weight(.bold)
    static let rowTrailing: Font = .caption.weight(.semibold)
    static let badgeSize: CGFloat = 200
    static let wideBadgeSize: CGFloat = 200
    static let map = CGSize(width: 280, height: 150)
    #endif
    /// The window's rows: the list's fixed height.
    static var listHeight: CGFloat { CGFloat(SportBannerWindow.visible) * row + CGFloat(SportBannerWindow.visible - 1) * rowGap }
}

struct SportBanner<Actions: View>: View {
    let hero: SportBannerHero
    let items: [SportBannerItem]
    /// "FOLLOWING · your order, playing now on top", "FOOTBALL · YOUR LEAGUES".
    let listTitle: String
    /// The item the hero (front page) or the page below (sport page) belongs to.
    let selected: Int?
    let backdrop: SportBannerBackdrop?
    let client: APIClient?
    /// A sport page: a back button before the hero (Menu goes back too).
    var showsBack = false
    let onSelect: (Int) -> Void
    /// A second action on an item (long press): "Open Football".
    var secondary: ((Int) -> (label: String, action: () -> Void)?)? = nil
    @ViewBuilder let actions: () -> Actions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedItem: Int?
    @State private var window = SportBannerWindow(count: 0)

    private var fullWidth: Bool { SportBannerLayout.fullWidth(itemCount: items.count) }

    var body: some View {
        HStack(alignment: .center, spacing: SportBannerMetrics.gap) {
            heroColumn.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SportBannerMetrics.padding.top).padding(.bottom, SportBannerMetrics.padding.bottom)
            if !fullWidth { list.frame(width: SportBannerMetrics.listWidth).padding(.vertical, SportBannerMetrics.listVertical) }
        }
        .padding(.leading, SportBannerMetrics.padding.leading).padding(.trailing, SportBannerMetrics.padding.trailing)
        .frame(maxWidth: .infinity)
        .frame(height: SportBannerMetrics.height)
        // The backdrop (a 300 pt badge) may be taller than the banner: the banner clips it and never grows.
        .background(alignment: fullWidth ? .trailing : .leading) { backdropView }
        .background(Color.pigSurface)
        .clipShape(RoundedRectangle(cornerRadius: SportBannerMetrics.radius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.banner")
        .onChange(of: items.count, initial: true) { _, count in window = SportBannerWindow(count: count, start: window.start) }
    }

    // MARK: The hero

    private var heroColumn: some View {
        HStack(alignment: .center, spacing: PigSpacing.xl) {
            if showsBack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: PigType.body, weight: .bold))
                        .frame(width: SportBannerMetrics.back, height: SportBannerMetrics.back)
                }
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                .accessibilityLabel("Back to Sport")
                .accessibilityIdentifier("sport.banner.back")
            }
            // The banner is a fixed 250 pt (D-43): its hero keeps the small steps so the title and actions fit inside it.
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(spacing: PigSpacing.s) {
                    if hero.live {
                        Circle().fill(Color.pigDanger).frame(width: 12, height: 12).accessibilityHidden(true)
                    }
                    Text(hero.kicker).font(SportBannerMetrics.kicker).tracking(1).lineLimit(1)
                        .foregroundStyle(hero.live ? Color.pigDanger : Color.pigAccentText)
                        .accessibilityIdentifier("sport.banner.hero.kicker")
                }
                Text(hero.title).font(fullWidth ? SportBannerMetrics.wideTitle : SportBannerMetrics.title)
                    .lineLimit(1).pigMinimumScale(0.7, size: PigType.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("sport.banner.hero.title")
                if !hero.line.isEmpty {
                    Text(hero.line).font(SportBannerMetrics.line).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("sport.banner.hero.line")
                }
                HStack(spacing: PigSpacing.s) { actions() }
                    .padding(.top, PigSpacing.xs)
                    .tvFocusSection()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.banner.hero")
    }

    @ViewBuilder
    private var backdropView: some View {
        if let backdrop, let client {
            switch backdrop {
            case .badge(let path):
                let side = fullWidth ? SportBannerMetrics.wideBadgeSize : SportBannerMetrics.badgeSize
                ChannelArtwork(logo: path, client: client, fill: true)
                    .frame(width: side, height: side)
                    .opacity(fullWidth ? 0.22 : 0.16)
                    // Split: beside the list, in the hero's half; full width: on the right.
                    .padding(fullWidth ? .trailing : .leading, fullWidth ? SportBannerMetrics.artworkInsetFull : SportBannerMetrics.artworkInsetSplit)
                    .accessibilityHidden(true)
            case .map:
                SportBannerMap(path: backdrop.path(dark: scheme == .dark), client: client)
                    .frame(width: SportBannerMetrics.map.width, height: SportBannerMetrics.map.height)
                    .opacity(fullWidth ? 0.45 : 0.22)
                    .padding(fullWidth ? .trailing : .leading, fullWidth ? SportBannerMetrics.mapInsetFull : SportBannerMetrics.mapInsetSplit)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: The list

    private var list: some View {
        let names = items.map(\.title)
        return VStack(alignment: .leading, spacing: SportBannerMetrics.listSpacing) {
            if SportBannerMetrics.moreInHeader {
                // #279 (Apple 199): one header line, the list's name at the left and the count at the right. The words
                // after the name ("· your order, playing now on top") and the names after the count do not fit beside
                // each other at 23 pt; the count is the "more" line's (the names are in Settings › Sport).
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(SportBannerLayout.shortTitle(listTitle)).font(SportBannerMetrics.listTitle).tracking(1.4)
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: PigSpacing.s)
                    Text(window.below > 0 ? "\(window.below) more" : " ").font(SportBannerMetrics.rowTrailing)
                        .foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("sport.banner.more")
                }
            } else {
                Text(listTitle).font(SportBannerMetrics.listTitle).tracking(1.4).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: SportBannerMetrics.rowGap) {
                        ForEach(items.indices, id: \.self) { index in row(index).id(index) }
                    }
                }
                // Room on every side inside the clipping list, so a focused row's ring is never cut (#279).
                .contentMargins(SportBannerMetrics.focusRoom, for: .scrollContent)
                .scrollIndicators(.hidden)
                .frame(height: SportBannerMetrics.listHeight + 2 * SportBannerMetrics.focusRoom)
                .accessibilityIdentifier("sport.banner.list")
                .onChange(of: focusedItem) { _, index in
                    guard let index else { return }
                    let moved = window.focusing(index)
                    guard moved != window else { return }
                    window = moved
                    // #233 (Mark, Apple 149): an animated scroll moved the rows while tvOS chose the next focus (and scrolled
                    // the list itself), so scrolling up focus jumped past a row and back. The window moves at once.
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { proxy.scrollTo(moved.start, anchor: .top) }
                }
            }
            if !SportBannerMetrics.moreInHeader {
                Text(window.moreLine(names: names) ?? " ").font(SportBannerMetrics.rowTrailing).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("sport.banner.more")
            }
        }
        .padding(.leading, SportBannerMetrics.listInset)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.pigBorder).frame(width: 1).accessibilityHidden(true)
        }
        .tvFocusSection()
    }

    private func row(_ index: Int) -> some View {
        let item = items[index]
        let isSelected = selected == index
        return Button { onSelect(index) } label: {
            HStack(spacing: PigSpacing.s) {
                if let badge = item.badge {
                    SportBadge(name: badge.name, logo: badge.logo, league: badge.league, client: client,
                               size: SportBannerMetrics.rowBadge)
                }
                Text(item.title).font(SportBannerMetrics.rowTitle).lineLimit(1)
                    .foregroundStyle(isSelected ? Color.pigAccentText : Color.primary)
                Spacer(minLength: 8)
                Text(item.trailing).font(SportBannerMetrics.rowTrailing).lineLimit(1)
                    .foregroundStyle(item.live ? Color.pigDanger : Color.secondary)
            }
            .padding(.horizontal, PigSpacing.m)
            .frame(height: SportBannerMetrics.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(Color.pigAccent).frame(width: 4).padding(.vertical, PigSpacing.xs).padding(.leading, PigSpacing.xxs)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.compact, lift: .listRow))
        .focused($focusedItem, equals: index)
        .contextMenu {
            if let second = secondary?(index) {
                Button(second.label, systemImage: "arrow.right.circle") { second.action() }
            }
        }
        .accessibilityLabel([item.title, item.trailing].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("sport.banner.item.\(index)")
    }
}

/// The circuit map (a logo-cache path, a 3840 px PNG since server 0424), decoded at the banner's size; nothing while it
/// loads, when absent or when it fails.
private struct SportBannerMap: View {
    let path: String
    let client: APIClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .task(id: path) {
            image = nil
            guard let data = try? await client.artworkData(path) else { return }
            let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}
