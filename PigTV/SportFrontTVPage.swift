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
    /// Down from the tab bar lands on the hero's first button.
    @FocusState private var heroFocused: Bool

    init(app: AppModel, browse: BrowseModel, open: @escaping (String) -> Void) {
        self.app = app
        self.browse = browse
        self.open = open
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    /// Scores, situations and results are hidden when either the answer or the account's preference says so.
    private var hidden: Bool { f1.hidesSpoilers }

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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                if let front = model.front {
                    if model.stale, let updated = model.updatedAt {
                        Text("Couldn't refresh. Last updated \(updated.formatted(date: .omitted, time: .shortened)).")
                            .font(SportCardMetrics.detail).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sport.front.stale")
                    }
                    if front.scoresUnavailable { scoresBanner }
                    if front.isEmpty {
                        emptyState
                    } else {
                        banner(front, now: now)
                        ForEach(SportFrontLayout.sections(front)) { section in sectionView(section, front: front, now: now) }
                        also(front, now: now)
                    }
                } else if !model.loaded {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    unavailable
                }
            }
            .padding(.bottom, 60)
            #if os(iOS)
            .padding(.horizontal, 24)
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
        }
        .scrollClipDisabled()
        .defaultFocus($heroFocused, true, priority: .userInitiated)
    }

    // MARK: The banner

    private func banner(_ front: SportFront, now: Date) -> some View {
        let game = model.heroGame
        let words = game.map { SportFrontLayout.hero($0, in: front, hidden: hidden, now: now, labels: model.labels) }
            ?? SportBannerHero(kicker: "YOUR SPORTS", live: false, title: "Nothing on right now",
                               line: "Your sports' next games are below.")
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
        VStack(alignment: .leading, spacing: 8) {
            Button { open(section.sport) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(section.sport).font(SportSectionMetrics.sectionTitle)
                    Text("›").font(SportSectionMetrics.sectionTitle).foregroundStyle(.secondary)
                    Text(SportFrontLayout.headerLine(section, in: front, now: now, labels: model.labels)).font(SportSectionMetrics.sectionLine)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: 12))
            .padding(.leading, -14)
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
                    .padding(.vertical, 6)
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
            HStack(spacing: 12) {
                Text("Also in your sports").font(SportSectionMetrics.sectionLine).foregroundStyle(.secondary)
                ForEach(sports, id: \.self) { sport in
                    Button { open(sport) } label: {
                        HStack(spacing: 8) {
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

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sportscourt").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("Follow a sport to start").font(DetailType.title).multilineTextAlignment(.center)
            Text(SportFrontText.followHelp(settings: browse.sportFollowsEnabled))
                .font(DetailType.meta).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
        }
        .padding(.vertical, 60).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sport.front.empty")
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "sportscourt").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("Sport is unavailable right now").font(DetailType.title).multilineTextAlignment(.center)
            Text(model.error ?? "The sport data could not be reached. The guide and playback are not affected.")
                .font(DetailType.meta).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
        }
        .padding(.vertical, 70).frame(maxWidth: .infinity)
    }
}
