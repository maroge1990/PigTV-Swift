import SwiftUI

// D-44 (R5-League/Cricket/Motor/Golf/Tennis/UFC-iPhone, #177, #186): a sport's page on the iPhone, the front page's
// pattern (SportFrontPhonePage): "‹ Sport", the sport and whether scores show; the sport's leagues as chips; a 212 pt
// carousel of the selected league's games (yours, then live); its games as fixture rows under Live, Later today, Coming
// up and Earlier; then the league's own page (rounds and standings, Formula 1's weekend, the cricket scoreboard, a
// leaderboard or fight card) behind its header, pushed (#177: pages for the extra content, not one long scroll). Words:
// `SportPhonePageLayout` (pure). The Apple TV and the iPad draw `SportPageView`.

#if os(iOS)
/// The carousel shared by the front page (the follows) and a sport's page (the league's games): 212 pt cards swiped
/// sideways, each with Watch or Remind me and Record (every game of the card's team when it has one, #49), the dots and
/// the position line beneath.
struct SportPhoneCarousel: View {
    let app: AppModel
    let browse: BrowseModel
    let flow: SportRecordFlow
    let front: SportFront
    let now: Date
    let cards: [SportPhoneCard]
    /// "1 of 7 follows", "1 of 4 · yours, then live".
    let position: (Int, Int) -> String
    /// "sport.front" or "sport.page.phone": the accessibility identifiers' prefix.
    let identifier: String
    /// A card without a game (a follow with nothing in the next three days).
    let open: (SportPhoneCard) -> Void
    @Environment(\.sportPresenter) private var presenter
    @State private var shown: String?

    var body: some View {
        if !cards.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        followCard(card)
                            .opacity(card.id == (shown ?? cards[0].id) ? 1 : 0.6)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, SportPhoneMetrics.edge)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $shown)
            .scrollIndicators(.hidden)
            .frame(height: SportPhoneMetrics.cardHeight)
            .accessibilityIdentifier("\(identifier).carousel")
            let index = cards.firstIndex { $0.id == shown } ?? 0
            HStack(spacing: 6) {
                ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { offset, _ in
                    Capsule().fill(offset == index ? Color.pigAccent : Color.secondary.opacity(0.6))
                        .frame(width: offset == index ? 18 : 6, height: 6)
                }
                Text(position(index, cards.count)).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(position(index, cards.count))
            .frame(maxWidth: .infinity)
        }
    }

    private func followCard(_ card: SportPhoneCard) -> some View {
        let game = front.game(card.gameId)
        let league = game?.league ?? (front.follows.indices.contains(card.index) ? front.follows[card.index].league : "")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if card.live { Circle().fill(Color.pigDanger).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(card.kicker).font(.caption2.weight(.bold)).tracking(1).lineLimit(1)
                    .foregroundStyle(card.live ? Color.pigDanger : Color.secondary)
            }
            Button {
                if let game { SportGamePress.select(game, app: app, presenter: presenter) } else { open(card) }
            } label: {
                VStack(spacing: 6) {
                    if card.sides.count == 2 {
                        HStack(alignment: .center) {
                            side(card.sides[0], league: league)
                            Text(card.score ?? "v").font(card.score == nil ? .title3.weight(.semibold) : .system(.title, design: .rounded).weight(.heavy))
                                .monospacedDigit().foregroundStyle(card.score == nil ? Color.secondary : Color.primary)
                            side(card.sides[1], league: league)
                        }
                    } else {
                        HStack(spacing: 12) {
                            if let badge = card.sides.first {
                                SportBadge(name: badge.name, logo: badge.logo, league: league, client: browse.client,
                                           size: SportPhoneMetrics.heroBadge)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title ?? "").font(.headline).lineLimit(2)
                                if let session = card.session { Text(session).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Text(card.line).font(.footnote).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.accessibilityLabel)
            .accessibilityIdentifier(card.index >= 0 ? "\(identifier).follow.\(card.index)" : "\(identifier).card.\(card.id)")
            Spacer(minLength: 0)
            if let game { actions(game, team: card.team.isEmpty ? nil : card.team, now: now) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: SportPhoneMetrics.cardWidth, height: SportPhoneMetrics.cardHeight, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .accessibilityElement(children: .contain)
        .id(card.id)
    }

    private func side(_ side: SportFixtureRowModel.Side, league: String) -> some View {
        VStack(spacing: 4) {
            SportBadge(name: side.name, logo: side.logo, league: league, client: browse.client, size: SportPhoneMetrics.heroBadge)
            HStack(spacing: 4) {
                if side.followed { Text("★").foregroundStyle(Color.pigAccentText).accessibilityHidden(true) }
                Text(side.name).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity)
    }

    /// Watch (on now) or Remind me (before), the one rose primary; Record every game when the game has a team to follow
    /// with a rule, else Record (the record page).
    @ViewBuilder
    private func actions(_ game: SportsGame, team: String?, now: Date) -> some View {
        if !game.terminal, let event = SportFrontText.event(game) {
            HStack(spacing: 8) {
                switch SportFrontText.action(game, now: now) {
                case .watch:
                    Button { SportGamePress.watch(game, event: event, app: app, presenter: presenter) } label: {
                        Label("Watch", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .pigPrimaryButton()
                    .accessibilityIdentifier("\(identifier).card.watch")
                case .remind:
                    Button { app.watchWhenStarts(event, now: Date()) } label: {
                        Label("Remind me", systemImage: "bell").frame(maxWidth: .infinity)
                    }
                    .pigPrimaryButton()
                    .accessibilityIdentifier("\(identifier).card.remind")
                case .details, .none:
                    EmptyView()
                }
                // #49: the rule is the card's own follow's team, and the button names it.
                let every = flow.menuItems(event, game: game, team: team, now: now).first { $0.id == "recordEvery" }
                Button {
                    if let every { flow.run(every, event: event, game: game, team: team) } else { flow.record(event, game: game, team: team) }
                } label: {
                    Text(every?.title ?? "Record").lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color("PigText"))
                .accessibilityIdentifier("\(identifier).card.record")
            }
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
    }
}

/// A card of fixture rows (#205): pressing a row plays it while its channel airs it, else opens its details; a long
/// press offers its RECORD section.
struct SportPhoneRowsCard: View {
    let app: AppModel
    let browse: BrowseModel
    let flow: SportRecordFlow
    let front: SportFront
    let rows: [SportFixtureRowModel]
    /// The rows' identifier prefix ("sport.front.game").
    let identifier: String
    @Environment(\.sportPresenter) private var presenter

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                if offset > 0 { Divider().overlay(Color.pigBorder) }
                if let game = front.game(row.id) {
                    Button { SportGamePress.select(game, app: app, presenter: presenter) } label: {
                        SportFixtureRow(row: row, client: browse.client)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !game.terminal, let event = SportFrontText.event(game) {
                            SportRecordMenu(flow: flow, event: event, game: game)
                        }
                    }
                    .accessibilityIdentifier("\(identifier).\(game.id)")
                }
            }
        }
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
    }
}

/// The iPhone page's header: "‹ Sport" (back), the title and whether scores show.
struct SportPhonePageHeader: View {
    let back: String
    let title: String
    let hidden: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { dismiss() } label: {
                Text("‹ \(back)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.pigAccentText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(back)")
            .accessibilityIdentifier("sport.page.back")
            HStack(spacing: 10) {
                Text(title).font(.title.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page.header.title")
                Spacer(minLength: 8)
                Text(SportPhoneLayout.scoresChip(hidden: hidden)).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.pigRaised, in: Capsule())
                    .accessibilityIdentifier("sport.page.scores")
            }
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
    }
}

/// A sport's page on the iPhone (D-44).
struct SportPhonePage: View {
    let app: AppModel
    let browse: BrowseModel
    let sport: String
    /// Pushes the league's own page (#177).
    let more: (String) -> Void
    @ObservedObject private var model: SportFrontModel
    /// The preferences every sport page shares: unknown counts as spoiler-free (#192).
    @ObservedObject private var f1: F1PageModel
    @StateObject private var flow = SportRecordFlow()
    @State private var chosen: String?

    init(app: AppModel, browse: BrowseModel, sport: String, more: @escaping (String) -> Void) {
        self.app = app
        self.browse = browse
        self.sport = sport
        self.more = more
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var hidden: Bool { f1.hidesSpoilers || model.front?.spoilerFree == true }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop()
        .toolbar(.hidden, for: .navigationBar)
        .whileVisible { await model.keepFresh(preferences: f1) }
        .task { await model.loadLabels(enabled: browse.sportFollowsEnabled) }
        .sportRecordFlow(flow, app: app)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.page.\(sport)")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                SportPhonePageHeader(back: "Sport", title: sport, hidden: hidden)
                if let front = model.front {
                    if let league = SportPhonePageLayout.league(sport, chosen: chosen, in: front) {
                        chips(front, selected: league)
                        page(league, front: front, now: now)
                    } else {
                        SportPhoneEmpty(icon: "sportscourt", title: "Nothing in the next three days",
                                        text: SportFrontText.followHelp(settings: browse.sportFollowsEnabled))
                    }
                } else {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private func chips(_ front: SportFront, selected: String) -> some View {
        let leagues = SportPhonePageLayout.chips(sport, in: front)
        if !leagues.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(leagues, id: \.self) { league in
                        let on = league == selected
                        Button { chosen = league } label: {
                            Text(SportLabels.label(league, in: model.labels)).font(.subheadline.weight(.bold))
                                .foregroundStyle(on ? Color.pigAccentText : Color.secondary)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(on ? Color.pigAccent.opacity(0.14) : Color.pigRaised, in: Capsule())
                                .overlay(alignment: .bottom) {
                                    if on { Capsule().fill(Color.pigAccent).frame(width: 18, height: 2).padding(.bottom, 3) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("sport.page.chip.\(league)")
                    }
                }
                .padding(.horizontal, SportPhoneMetrics.edge)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func page(_ league: String, front: SportFront, now: Date) -> some View {
        let cards = SportPhonePageLayout.cards(league: league, in: front, hidden: hidden, now: now, labels: model.labels)
        let groups = SportPhonePageLayout.groups(league: league, in: front, hidden: hidden, now: now)
        SportPhoneCarousel(app: app, browse: browse, flow: flow, front: front, now: now, cards: cards,
                           position: SportPhonePageLayout.position, identifier: "sport.page.phone", open: { _ in })
            .id(league)
        if groups.isEmpty && cards.isEmpty {
            Text("Nothing in the next three days").font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, SportPhoneMetrics.edge).padding(.vertical, 8)
        }
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.title).font(.title3.weight(.heavy)).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
                SportPhoneRowsCard(app: app, browse: browse, flow: flow, front: front, rows: group.rows,
                                   identifier: "sport.page.game")
            }
            .padding(.horizontal, SportPhoneMetrics.edge)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.page.group.\(group.title)")
        }
        let content = SportPageRules.content(league: league, sport: sport, f1: browse.sportPagesEnabled,
                                             nfl: browse.nflPageEnabled, cricket: browse.cricketPageEnabled,
                                             leagues: browse.leaguePageLeagues, events: browse.eventPagesEnabled)
        if let title = SportPhonePageLayout.moreTitle(content, sport: sport) {
            Button { more(league) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.title3.weight(.heavy))
                    Text("›").font(.title3.weight(.heavy)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(SportLabels.label(league, in: model.labels)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 4).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, SportPhoneMetrics.edge)
            .accessibilityLabel("\(title), \(SportLabels.label(league, in: model.labels)), open its page")
            .accessibilityIdentifier("sport.page.more")
        }
    }
}

/// A league's own page on the iPhone (#177): what the Apple TV shows below its banner, on a page of its own.
struct SportPhoneLeaguePage: View {
    let app: AppModel
    let browse: BrowseModel
    let sport: String
    let league: String
    @ObservedObject private var model: SportFrontModel
    @ObservedObject private var f1: F1PageModel
    @StateObject private var flow = SportRecordFlow()

    init(app: AppModel, browse: BrowseModel, sport: String, league: String) {
        self.app = app
        self.browse = browse
        self.sport = sport
        self.league = league
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var hidden: Bool { f1.hidesSpoilers || model.front?.spoilerFree == true }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    SportPhonePageHeader(back: sport, title: SportLabels.label(league, in: model.labels), hidden: hidden)
                    if let front = model.front {
                        SportLeagueContent(app: app, browse: browse, sport: sport, league: league, front: front,
                                           labels: model.labels, hidden: hidden, now: context.date, flow: flow)
                            .environment(\.sportNarrow, true)
                            .padding(.horizontal, SportPhoneMetrics.edge)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .pigPageBackdrop()
        .toolbar(.hidden, for: .navigationBar)
        .whileVisible { await model.keepFresh(preferences: f1) }
        .sportRecordFlow(flow, app: app)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.page.more.\(league)")
    }
}
#endif
