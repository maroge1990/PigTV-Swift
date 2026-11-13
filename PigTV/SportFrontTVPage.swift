import SwiftUI

// D-43 (1 Nov, DESIGN.md › Apple TV sport pages; mock-up "V2 · Front"): the Apple TV Sport front page. No sport tiles.
// Under the tabs the banner: the hero on the left (C-R's hero, kept until its event ends unless a follow goes live; a
// long press on a card makes it the hero) and the follows on the right, in the order sent; selecting a follow flips the
// hero, and the hero offers its sport's page. Then a rail per sport (its header "Football ›" opens the sport page; its
// leagues' rails beneath). Sports with nothing in the next 72 hours sit as small buttons on the last line, "Also in your
// sports". Spoiler-free hides scores, situations and results; without the scores feed the page says so once. The iPad
// draws this page too (D-44); the iPhone has its own (`SportFrontPhonePage`).

struct SportFrontTVPage: View {
    let app: AppModel
    let browse: BrowseModel
    /// Pushes a sport page.
    let open: (String) -> Void
    @ObservedObject private var model: SportFrontModel
    /// The F1 page's data (the circuit map behind a race hero) and the preferences every sport page shares.
    @ObservedObject private var f1: F1PageModel
    @StateObject private var flow = SportRecordFlow()
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Down from the tab bar lands on the hero's first button.
    @FocusState private var heroFocused: Bool
    /// #264: how far the page has scrolled, and the banner's height: past it, the banner shows as the strip.
    @State private var pastBanner = false
    @State private var bannerHeight: CGFloat = 0

    private var stripShows: Bool {
        guard let front = model.front, !front.isEmpty else { return false }
        return pastBanner
    }

    init(app: AppModel, browse: BrowseModel, open: @escaping (String) -> Void) {
        self.app = app
        self.browse = browse
        self.open = open
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    /// How far past its sides and bottom the page may draw (#263): more than a focused card grows.
    static let overdraw: CGFloat = 200
    static let bannerID = "sport.front.banner"

    /// Scores, situations and results are hidden when either the answer or the account's preference says so (#278: the
    /// same inputs as the iPhone's front page; before, this page read the preference alone).
    private var hidden: Bool { Self.scoresHidden(preference: f1.hidesSpoilers, front: model.front) }

    /// The page's decision, pure, for the tests.
    nonisolated static func scoresHidden(preference: Bool, front: SportFront?) -> Bool {
        SportSpoilers.hidden(preference: preference, answer: front?.spoilerFree, page: false)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh(preferences: f1) }
        .task { await model.loadLabels(enabled: browse.sportFollowsEnabled) }
        .onChange(of: f1.hidesSpoilers) { Task { await model.load() } }
        .task(id: model.heroGame?.league == "F1") {
            guard model.heroGame?.league == "F1", browse.sportPagesEnabled, f1.page == nil else { return }
            await f1.load()
        }
        .sportRecordFlow(flow, app: app)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            // #243: the header every tab draws, where the TV Guide draws it (before, the Sport tab had none here)
            SportTabHeader(now: now, hidden: hidden)
            scroll(now: now)
        }
    }


    private func scroll(now: Date) -> some View {
        // #264: once the banner has scrolled under, it shows as the strip, pinned above the rails.
        // #312 (Mark, 14 Nov 2026): the strip is drawn over the top of the page, whose frame never changes. In 191 it took
        // its own room above the ScrollView, which shrank by the strip's height the moment it showed, and tvOS scrolled the
        // focused card again: the row jumped. The page now keeps the strip's room at its top at all times, as a content
        // margin (`SportHeroStripMetrics.room`), so tvOS's focus scrolling never leaves a focused card beneath the strip
        // (Codex, Apple 190 round 1, medium); the content is drawn up into that room, so at rest the banner sits where it did.
        ScrollViewReader { reader in
            page(now: now)
                .overlay(alignment: .top) {
                    if stripShows, let front = model.front {
                        SportHeroStripView(strip: strip(front, now: now)) {
                            pigWithAnimation(moves: true, momentum: true, reduceMotion: reduceMotion) { reader.scrollTo(SportFrontTVPage.bannerID, anchor: .top) }
                        }
                        #if os(iOS)
                        .padding(.horizontal, PigSpacing.xl)
                        #endif
                        .pigSlide(from: .top)
                    }
                }
                .pigAnimation(value: stripShows, moves: true)
        }
    }

    private func page(now: Date) -> some View {
        ScrollView(.vertical) {
            // D-43: the banner, then the rails 20 pt below it (the television's m is the nearest step)
            // #280: the four states (PageState): placeholders shaped like the page, the pig with the one action, the pig in
            // the retry ring, or the content (with the slim notice when its refresh failed).
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                switch model.state {
                case .loading:
                    SportFrontPlaceholder()
                case .failed(let failure):
                    PigErrorState(failure: failure, retry: { await model.load() }, identifier: "sport.front.error", schedule: model.schedule)
                        .pigStateFillsPage()
                case .empty, .emptyStale:
                    // An empty answer whose refresh failed keeps E1 under the slim notice (it may be out of date); the
                    // scores feed's own note shows above it, as above the content.
                    if model.state.isStale {
                        PigStaleNotice(since: model.state.staleSince, retry: { await model.load() }, identifier: "sport.front.stale")
                    }
                    if model.front?.scoresUnavailable == true { scoresBanner }
                    SportFollowEmpty(app: app, settings: browse.sportFollowsEnabled).pigStateFillsPage()
                case .content, .stale:
                    if let front = model.front {
                        if case .stale(let since) = model.state {
                            PigStaleNotice(since: since, retry: { await model.load() }, identifier: "sport.front.stale")
                        }
                        if front.scoresUnavailable { scoresBanner }
                        banner(front, now: now)
                            .id(SportFrontTVPage.bannerID)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                        ForEach(SportFrontLayout.sections(front)) { section in sectionView(section, front: front, now: now) }
                        also(front, now: now)
                    }
                }
            }
            .padding(.bottom, PigSpacing.empty)
            #if os(iOS)
            .padding(.horizontal, PigSpacing.xl)
            #endif
            // #312: drawn up into the strip's room (the content margin below), so at the top the banner is where it was.
            .padding(.top, -SportHeroStripMetrics.room)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
        }
        .contentMargins(.top, SportHeroStripMetrics.room, for: .scrollContent)
        // Cards draw outside the scroll's frame (a focused card grows past the page's edges), except at its top: #263, the
        // rails used to slide up over the header as the page scrolled. The page now ends under the header, as the
        // TV Guide's grid does, fading out over its first few points.
        .scrollClipDisabled()
        .mask(alignment: .top) {
            // #312: while the strip shows, nothing is drawn in its room (the strip is over it).
            SportPageTopMask(overdraw: SportFrontTVPage.overdraw, top: stripShows ? SportHeroStripMetrics.room : 0)
        }
        .onScrollGeometryChange(for: Bool.self) { [bannerHeight] in
            SportHeroStrip.shows(scrolled: $0.contentOffset.y + $0.contentInsets.top, bannerHeight: bannerHeight, stripHeight: SportHeroStripMetrics.height)
        } action: { _, past in pastBanner = past }
        .defaultFocus($heroFocused, true, priority: .userInitiated)
    }

    // MARK: The banner

    private func banner(_ front: SportFront, now: Date) -> some View {
        let game = model.heroGame
        let words = heroWords(front, now: now)
        let sport = game.map { SportFrontLayout.sport(of: $0.league, in: front) }
        return SportBanner(hero: words, items: SportFrontLayout.followItems(front, now: now),
                           listTitle: "FOLLOWING · your order, playing now on top",
                           selected: model.heroFollowIndex,
                           backdrop: game.flatMap { backdrop($0, front: front) }, client: browse.client,
                           onSelect: { model.select(follow: $0) },
                           secondary: { index in
                               let sport = front.follows[index].sportName
                               return (label: "Open \(sport)", action: { open(sport) })
                           }) {
            SportHeroButtons(game: game, now: now, app: app, flow: flow,
                             team: model.heroFollowIndex.flatMap { front.follows.indices.contains($0) ? front.follows[$0].name : nil },
                             open: sport.map { name in (label: "Open \(name)", action: { open(name) }) },
                             focus: $heroFocused)
        }
    }

    private func heroWords(_ front: SportFront, now: Date) -> SportBannerHero {
        model.heroGame.map { SportFrontLayout.hero($0, in: front, hidden: hidden, now: now, labels: model.labels) }
            ?? SportBannerHero(kicker: "YOUR SPORTS", live: false, title: "Nothing on right now",
                               line: "The next games you follow are below.")
    }

    /// #264: the banner's words, slim.
    private func strip(_ front: SportFront, now: Date) -> SportHeroStrip {
        SportHeroStrip(hero: heroWords(front, now: now), items: SportFrontLayout.followItems(front, now: now),
                       selected: model.heroFollowIndex)
    }

    /// The circuit map for a race (its dark version in dark mode), else the hero team's badge.
    private func backdrop(_ game: SportsGame, front: SportFront) -> SportBannerBackdrop? {
        if game.league == "F1" {
            guard let map = f1.page?.weekend?.info?.map else { return nil }
            return .map(light: map, dark: f1.page?.weekend?.info?.mapDark)
        }
        if let index = model.heroFollowIndex, let logo = front.follows[index].cachedLogo { return .badge(logo) }
        return game.competitors.lazy.compactMap(\.cachedLogo).first.map { .badge($0) }
    }

    // MARK: A sport's rails

    private func sectionView(_ section: SportFrontLayout.Section, front: SportFront, now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            Button { open(section.sport) } label: {
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(section.sport).font(SportSectionMetrics.sectionTitle)
                    Text("›").font(SportSectionMetrics.sectionTitle).foregroundStyle(.secondary)
                    Text(SportFrontLayout.headerLine(section, in: front, now: now, labels: model.labels)).font(SportSectionMetrics.sectionLine)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.xs)
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: 12))
            .padding(.leading, -PigSpacing.m) // the header's own inset, so its text lines up with the cards
            .accessibilityLabel("\(section.sport), open its page")
            .accessibilityIdentifier("sport.rail.header.\(section.sport)")
            ForEach(section.rails, id: \.league) { rail in
                if section.rails.count > 1 {
                    Text(SportLabels.label(rail.league, in: model.labels).uppercased()).font(SportCardMetrics.kicker).tracking(1.4)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: SportCardMetrics.spacing) {
                        ForEach(front.games(in: rail)) { game in
                            SportGameCard(game: game, front: front, hidden: hidden, now: now, client: browse.client,
                                          onSelect: { SportGamePress.select(game, app: app, presenter: presenter) },
                                          onPin: { model.pin(game.id) }, flow: flow)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, PigSpacing.xs)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sport.front.rail.\(rail.league)")
            }
        }
        .tvFocusSection()
    }

    // MARK: Also in your sports

    @ViewBuilder
    private func also(_ front: SportFront, now: Date) -> some View {
        let sports = SportFrontLayout.alsoInYourSports(front)
        if !sports.isEmpty {
            HStack(spacing: PigSpacing.s) {
                Text("Also in your sports").font(SportSectionMetrics.sectionLine).foregroundStyle(.secondary)
                ForEach(sports, id: \.self) { sport in
                    Button { open(sport) } label: {
                        HStack(spacing: PigSpacing.s) {
                            Text(sport).font(SportSectionMetrics.sectionLine.weight(.bold))
                            if let line = SportFrontLayout.alsoLine(sport, in: front, now: now) {
                                Text(line).font(SportSectionMetrics.sectionLine.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("sport.also.\(sport)")
                }
            }
            .tvFocusSection()
        }
    }

    // MARK: States

    private var scoresBanner: some View {
        Label(SportFrontText.scoresUnavailable, systemImage: "info.circle")
            .font(SportCardMetrics.detail).foregroundStyle(.secondary)
            .padding(SportCardMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: SportCardMetrics.radius, style: .continuous))
            .accessibilityIdentifier("sport.front.scoresUnavailable")
    }
}

/// #280 (E1): a league's page with nothing to show: its one action is Open the TV Guide. Under the Sport banner (Apple TV,
/// iPad) the banner's own rose button is the screen's primary, so this one is secondary; the iPhone's league page has none.
struct SportLeagueEmpty: View {
    let app: AppModel
    let title: String
    let text: String
    let identifier: String
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var prominent: Bool { sizeClass == .compact }
    #else
    private var prominent: Bool { false }
    #endif

    var body: some View {
        PigEmptyState(title: title, text: text,
                      action: PigStateAction(label: PageWords.openGuide, prominent: prominent) { app.requestedTab = "guide" },
                      identifier: identifier)
    }
}

/// #280 (E1): nothing followed. With per-account follows (C-U) "Choose your sport" opens Settings › Sport; an older
/// server keeps follows in the web app, so the page says where and has no button. Every device's Sport pages draw it.
struct SportFollowEmpty: View {
    let app: AppModel
    let settings: Bool
    var title = PageWords.followTitle
    var identifier = "sport.front.empty"

    var body: some View {
        PigEmptyState(title: title, text: PageWords.followText(settings: settings),
                      action: settings ? PigStateAction(label: PageWords.followAction) { app.openSettings(.sport) } : nil,
                      identifier: identifier)
    }
}
