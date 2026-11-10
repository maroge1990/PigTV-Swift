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
                LazyHStack(spacing: PigSpacing.m) {
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
            HStack(spacing: PigSpacing.s) {
                ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { offset, _ in
                    Capsule().fill(offset == index ? Color.pigAccent : Color.secondary.opacity(0.6))
                        .frame(width: offset == index ? 18 : 6, height: 6)
                }
                Text(position(index, cards.count)).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, PigSpacing.s)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(position(index, cards.count))
            .frame(maxWidth: .infinity)
        }
    }

    private func followCard(_ card: SportPhoneCard) -> some View {
        let game = front.game(card.gameId)
        let league = game?.league ?? (front.follows.indices.contains(card.index) ? front.follows[card.index].league : "")
        return VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(spacing: PigSpacing.s) {
                if card.live { Circle().fill(Color.pigDanger).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(card.kicker).font(.caption2.weight(.bold)).tracking(1).lineLimit(1)
                    .foregroundStyle(card.live ? Color.pigDanger : Color.secondary)
            }
            Button {
                if let game { SportGamePress.select(game, app: app, presenter: presenter) } else { open(card) }
            } label: {
                VStack(spacing: PigSpacing.s) {
                    if card.sides.count == 2 {
                        HStack(alignment: .center) {
                            side(card.sides[0], league: league)
                            // #254 (Mark, 8 Nov): the short score in the middle, the rest small under it; never wider than
                            // the two names leave (a cricket score filled the card).
                            VStack(spacing: PigSpacing.xxs) {
                                if let score = card.score {
                                    // The largest size that fits the column, never cut off ("60–47" large, "245/6–180/3" smaller).
                                    ViewThatFits(in: .horizontal) {
                                        ForEach(Self.scoreSizes, id: \.self) { size in
                                            Text(score).font(.system(size, design: .rounded).weight(.heavy)).monospacedDigit()
                                                .lineLimit(1).fixedSize()
                                        }
                                    }
                                } else {
                                    Text("v").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                if let detail = card.scoreDetail {
                                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                                        .fixedSize() // one size on every card; it may run a little past the column
                                }
                            }
                            .frame(width: SportPhoneMetrics.heroScoreWidth) // the names share the rest
                            side(card.sides[1], league: league)
                        }
                    } else {
                        HStack(spacing: PigSpacing.m) {
                            if let badge = card.sides.first {
                                SportBadge(name: badge.name, logo: badge.logo, league: league, client: browse.client,
                                           size: SportPhoneMetrics.heroBadge)
                            }
                            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
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
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.l)
        .frame(width: SportPhoneMetrics.cardWidth, height: SportPhoneMetrics.cardHeight, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .accessibilityElement(children: .contain)
        .id(card.id)
    }

    /// #254: the score's sizes, largest first; the hero takes the first that fits its column.
    private static let scoreSizes: [Font.TextStyle] = [.title, .title2, .title3, .headline, .subheadline, .footnote]

    private func side(_ side: SportFixtureRowModel.Side, league: String) -> some View {
        VStack(spacing: PigSpacing.xs) {
            SportBadge(name: side.name, logo: side.logo, league: league, client: browse.client, size: SportPhoneMetrics.heroBadge)
                // The followed side's star sits on its badge, so the name keeps the width.
                .overlay(alignment: .topTrailing) {
                    if side.followed {
                        Text("★").font(.subheadline.weight(.bold)).foregroundStyle(Color.pigAccentText)
                            .padding(PigSpacing.xxs).background(Color.pigRaised, in: Circle())
                            .offset(x: 6, y: -4).accessibilityHidden(true)
                    }
                }
            // #252: one size for both names and the rows below (each side shrank on its own to 80%): a long name takes
            // a second line instead.
            Text(side.name).font(.subheadline.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Watch (on now) or Remind me (before), the one rose primary, then Record (the record page, which offers every game of
    /// the card's team, #49): the same glass family, width and height (#225).
    @ViewBuilder
    private func actions(_ game: SportsGame, team: String?, now: Date) -> some View {
        if !game.terminal, let event = SportFrontText.event(game) {
            HStack(spacing: PigSpacing.s) {
                switch SportFrontText.action(game, now: now) {
                case .watch:
                    Button { SportGamePress.watch(game, event: event, app: app, presenter: presenter) } label: {
                        Label(SportPhoneCardButtons.primary(.watch) ?? "", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .pigPrimaryButton()
                    .accessibilityIdentifier("\(identifier).card.watch")
                case .remind:
                    Button { app.watchWhenStarts(event, now: Date()) } label: {
                        Label(SportPhoneCardButtons.primary(.remind) ?? "", systemImage: "bell").frame(maxWidth: .infinity)
                    }
                    .pigPrimaryButton()
                    .accessibilityIdentifier("\(identifier).card.remind")
                case .details, .none:
                    EmptyView()
                }
                // #49: the record page's rule is the card's own follow's team.
                Button { flow.record(event, game: game, team: team) } label: {
                    Label(SportPhoneCardButtons.record, systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(Color.pigText)
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
        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
            Button { dismiss() } label: {
                Text("‹ \(back)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.pigAccentText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(back)")
            .accessibilityIdentifier("sport.page.back")
            HStack(spacing: PigSpacing.m) {
                // #226: the tabs' title style (PigPageHeaderMetrics), under the back line
                Text(title).font(PigPageHeaderMetrics.title).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page.header.title")
                Spacer(minLength: 8)
                Text(SportPhoneLayout.scoresChip(hidden: hidden)).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
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
            VStack(alignment: .leading, spacing: PigSpacing.m) {
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
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, PigSpacing.empty)
                }
            }
            .padding(.bottom, PigSpacing.section)
        }
    }

    @ViewBuilder
    private func chips(_ front: SportFront, selected: String) -> some View {
        let leagues = SportPhonePageLayout.chips(sport, in: front)
        if !leagues.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: PigSpacing.s) {
                    ForEach(leagues, id: \.self) { league in
                        let on = league == selected
                        Button { chosen = league } label: {
                            Text(SportLabels.label(league, in: model.labels)).font(.subheadline.weight(.bold))
                                .foregroundStyle(on ? Color.pigAccentText : Color.secondary)
                                .padding(.horizontal, PigSpacing.l).frame(height: 34)
                                .background(on ? Color.pigAccent.opacity(0.14) : Color.pigRaised, in: Capsule())
                                .overlay(alignment: .bottom) {
                                    if on { Capsule().fill(Color.pigAccent).frame(width: 18, height: 2).padding(.bottom, PigSpacing.xs) }
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
                .padding(.horizontal, SportPhoneMetrics.edge).padding(.vertical, PigSpacing.s)
        }
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Text(group.title).font(.title3.weight(.heavy)).padding(.horizontal, PigSpacing.xs).accessibilityAddTraits(.isHeader)
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
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(title).font(.title3.weight(.heavy))
                    Text("›").font(.title3.weight(.heavy)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(SportLabels.label(league, in: model.labels)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, PigSpacing.xs).padding(.vertical, PigSpacing.s)
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
                VStack(alignment: .leading, spacing: PigSpacing.m) {
                    SportPhonePageHeader(back: sport, title: SportLabels.label(league, in: model.labels), hidden: hidden)
                    if let front = model.front {
                        SportLeagueContent(app: app, browse: browse, sport: sport, league: league, front: front,
                                           labels: model.labels, hidden: hidden, now: context.date, flow: flow)
                            .environment(\.sportNarrow, true)
                            .padding(.horizontal, SportPhoneMetrics.edge)
                    }
                }
                .padding(.bottom, PigSpacing.section)
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
