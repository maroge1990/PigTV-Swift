import SwiftUI

// D-44 (R5-Front-iPhone, Apple 139): the iPhone Sport front page. The header (the pig, "Sport", and whether scores
// show); a 212 pt carousel of the follows, one card each in the order sent, swiped sideways with its dots and "1 of 10
// follows" (Watch or Remind me, and Record every game, on the card); then one card per sport under its "Football ›"
// header, which opens the sport's page, each game a fixture row (`SportFixtureRow`). Pressing a row plays it while its
// channel airs it, else opens its details; a long press offers its RECORD section. The words come from
// `SportPhoneLayout`, spoiler-free already applied. The iPad uses the Apple TV page (`SportFrontTVPage`).

#if os(iOS)
enum SportPhoneMetrics {
    static let cardWidth: CGFloat = 330
    static let cardHeight: CGFloat = 212
    static let heroBadge: CGFloat = 48
    /// #254: the hero card's score column between the two names (a longer score takes a smaller size).
    static let heroScoreWidth: CGFloat = 100
    static let rowBadge: CGFloat = 22
    static let edge: CGFloat = 16
}

struct SportFrontPhonePage: View {
    let app: AppModel
    let browse: BrowseModel
    /// Pushes a sport page.
    let open: (String) -> Void
    @ObservedObject private var model: SportFrontModel
    /// The preferences every sport page shares: unknown counts as spoiler-free (#192).
    @ObservedObject private var f1: F1PageModel
    @StateObject private var flow = SportRecordFlow()
    /// #264: how far the page has scrolled, and the carousel's height: past it, the hero shows as the strip.
    @State private var scrolled: CGFloat = 0
    @State private var carouselHeight: CGFloat = 0

    init(app: AppModel, browse: BrowseModel, open: @escaping (String) -> Void) {
        self.app = app
        self.browse = browse
        self.open = open
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var hidden: Bool { f1.hidesSpoilers || model.front?.spoilerFree == true }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh(preferences: f1) }
        .task { await model.loadLabels(enabled: browse.sportFollowsEnabled) }
        .onChange(of: f1.hidesSpoilers) { Task { await model.load() } }
        .sportRecordFlow(flow, app: app)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // #263: the header stays put above the page, as the TV Guide's does; before, it scrolled away with the cards.
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            header
            // #264: the strip takes its own room above the page (see SportFrontTVPage.scroll).
            ScrollViewReader { reader in
                VStack(alignment: .leading, spacing: SportHeroStripMetrics.gap) {
                    if stripShows, let front = model.front {
                        SportHeroStripView(strip: strip(front, now: now)) {
                            withAnimation { reader.scrollTo(Self.carouselID, anchor: .top) }
                        }
                        .padding(.horizontal, SportPhoneMetrics.edge)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    page(now: now)
                }
                .animation(.easeOut(duration: 0.2), value: stripShows)
            }
        }
    }

    static let carouselID = "sport.front.carousel"

    private var stripShows: Bool {
        guard let front = model.front, !front.isEmpty else { return false }
        return SportHeroStrip.shows(scrolled: scrolled, bannerHeight: carouselHeight, stripHeight: SportHeroStripMetrics.height)
    }

    /// #264: the hero's words, slim (the carousel's first card is the hero's follow).
    private func strip(_ front: SportFront, now: Date) -> SportHeroStrip {
        let words = model.heroGame.map { SportFrontLayout.hero($0, in: front, hidden: hidden, now: now, labels: model.labels) }
            ?? SportBannerHero(kicker: "YOUR SPORTS", live: false, title: "Nothing on right now",
                               line: "Your sports' next games are below.")
        return SportHeroStrip(hero: words, items: SportFrontLayout.followItems(front, now: now), selected: model.heroFollowIndex)
    }

    private func page(now: Date) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                if let front = model.front {
                    if model.stale, let updated = model.updatedAt {
                        Text("Couldn't refresh. Last updated \(updated.formatted(date: .omitted, time: .shortened)).")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, SportPhoneMetrics.edge)
                            .accessibilityIdentifier("sport.front.stale")
                    }
                    if front.scoresUnavailable {
                        Label(SportFrontText.scoresUnavailable, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, SportPhoneMetrics.edge)
                            .accessibilityIdentifier("sport.front.scoresUnavailable")
                    }
                    if front.isEmpty {
                        SportPhoneEmpty(icon: "sportscourt", title: "Follow a sport to start",
                                        text: SportFrontText.followHelp(settings: browse.sportFollowsEnabled))
                            .accessibilityIdentifier("sport.front.empty")
                    } else {
                        carousel(front, now: now)
                            .id(Self.carouselID)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { carouselHeight = $0 }
                        ForEach(SportPhoneLayout.groups(front, hidden: hidden, now: now, labels: model.labels)) { group in
                            groupView(group, front: front, now: now)
                        }
                        also(front, now: now)
                    }
                } else if !model.loaded {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, PigSpacing.empty)
                } else {
                    VStack(spacing: PigSpacing.l) {
                        SportPhoneEmpty(icon: "sportscourt", title: "Sport is unavailable right now",
                                        text: model.error ?? "The sport data could not be reached. The guide and playback are not affected.")
                        Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, PigSpacing.section)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in scrolled = y }
    }

    /// #226: the one page header every tab draws (PigPageHeader), the scores chip trailing.
    private var header: some View {
        SportTabHeader(now: Date(), hidden: hidden)
    }

    @ViewBuilder
    private func carousel(_ front: SportFront, now: Date) -> some View {
        SportPhoneCarousel(app: app, browse: browse, flow: flow, front: front, now: now,
                           cards: SportPhoneLayout.cards(front, hidden: hidden, now: now, labels: model.labels),
                           position: SportPhoneLayout.position, identifier: "sport.front",
                           open: { card in open(front.follows[card.index].sportName) })
    }

    // MARK: A sport's card

    private func groupView(_ group: SportPhoneGroup, front: SportFront, now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            Button { open(group.sport) } label: {
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(group.sport).font(.title3.weight(.heavy))
                    Text("›").font(.title3.weight(.heavy)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(group.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, PigSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.sport), \(group.note), open its page")
            .accessibilityIdentifier("sport.rail.header.\(group.sport)")
            SportPhoneRowsCard(app: app, browse: browse, flow: flow, front: front, rows: group.rows, identifier: "sport.front.game")
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.front.group.\(group.sport)")
    }

    /// Sports with nothing in the next 72 hours: a line of buttons to their pages.
    @ViewBuilder
    private func also(_ front: SportFront, now: Date) -> some View {
        let sports = SportFrontLayout.alsoInYourSports(front)
        if !sports.isEmpty {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Text("Also in your sports").font(.footnote).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: PigSpacing.s) {
                        ForEach(sports, id: \.self) { sport in
                            Button { open(sport) } label: {
                                HStack(spacing: PigSpacing.s) {
                                    Text(sport).font(.subheadline.weight(.bold))
                                    if let line = SportFrontLayout.alsoLine(sport, in: front, now: now) {
                                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, PigSpacing.l).frame(minHeight: 36)
                                .background(Color.pigRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sport.also.\(sport)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, SportPhoneMetrics.edge)
        }
    }
}

/// D-44's fixture row (#205, #213): logo · Team v Team · logo on the left, the score on the right; the state (red while
/// live), time and channel on a second line. A session's row has its league's square badge and title instead. Real
/// logos from the logo cache; the monogram disc only without one. VoiceOver reads the row's label (no hidden score).
struct SportFixtureRow: View {
    let row: SportFixtureRowModel
    let client: APIClient?

    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
            HStack(spacing: PigSpacing.s) {
                if row.sides.count == 2 {
                    SportBadge(name: row.sides[0].name, logo: row.sides[0].logo, league: row.league, client: client,
                               size: SportPhoneMetrics.rowBadge)
                    title.font(.subheadline.weight(.bold)).lineLimit(1)
                    SportBadge(name: row.sides[1].name, logo: row.sides[1].logo, league: row.league, client: client,
                               size: SportPhoneMetrics.rowBadge)
                } else {
                    Text(row.badge ?? "").font(.system(size: PigType.micro, weight: .heavy)).foregroundStyle(Color.pigOnStatus)
                        .frame(width: SportPhoneMetrics.rowBadge, height: SportPhoneMetrics.rowBadge)
                        .background(Color(teamHex: SportFrontText.leagueColor(row.league)) ?? Color.pigDanger,
                                    in: RoundedRectangle(cornerRadius: PigRadius.inner, style: .continuous))
                        .accessibilityHidden(true)
                    Text(row.title).font(.subheadline.weight(.bold)).lineLimit(1)
                }
                Spacer(minLength: 10)
                if let score = row.shortScore ?? row.score {
                    Text(score).font(.system(.subheadline, design: .rounded).weight(.heavy)).monospacedDigit().lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: PigSpacing.s) {
                if let live = row.live {
                    Text("● \(live)").font(.caption.weight(.bold)).foregroundStyle(Color.pigDanger).monospacedDigit()
                        .fixedSize()
                    if !row.sub.isEmpty { Text("·") }
                }
                Text(row.sub).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .padding(.leading, PigSpacing.section)
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// "★ Packers v Lions": the followed side starred in pink.
    private var title: Text {
        var text = Text("")
        for (index, side) in row.sides.enumerated() {
            if index > 0 { text = text + Text(" v ") }
            if side.followed { text = text + Text("★ ").foregroundStyle(Color.pigAccentText) }
            text = text + Text(side.name)
        }
        return text
    }
}

/// A short centred state: an icon, a title and a line.
struct SportPhoneEmpty: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: PigSpacing.m) {
            Image(systemName: icon).font(.system(size: PigType.hero, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, PigSpacing.empty).padding(.horizontal, PigSpacing.xl).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
#endif
