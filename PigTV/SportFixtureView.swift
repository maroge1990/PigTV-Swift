import SwiftUI

// D-43 (1 Nov, mock-up V2-League-1): a fixture league under its sport page's banner, the NFL (C-Q) and any C-T league:
// the rounds to switch between (the last and the current; the next once C-T sends it), the round as a three-column
// grid of game cards, and the standings on the right (Division / Conference / Overall where the league has them, else
// one table). A followed team has the star and, on touch, its card the pink outline (the star alone on the
// television, #279); its row the pink tint. Spoiler-free hides
// scores, records, the live situation and the standings (rules: SportFixtureModels.swift).

nonisolated enum SportFixtureMetrics {
    /// A standings table's sizes on one platform.
    struct Table: Equatable, Sendable {
        var width: CGFloat
        var valueWidth: CGFloat
        var rankWidth: CGFloat
        var badge: CGFloat
        var spacing: CGFloat
        /// A followed row's star.
        var star: CGFloat = 14
        /// The list card's and a followed row's padding, both sides.
        var inset: CGFloat
    }

    static let tvTable = Table(width: 680, valueWidth: 42, rankWidth: 28, badge: 24, spacing: PigSpacing.m, inset: 2 * 22 + 2 * 8)
    // #228 (Mark, 4 Nov 2026: "a lot of dead space in the standings table"): on iPad the values were held 44 pt wide with
    // 10 pt gaps, wider together than the 380 pt table, so a row overflowed onto the games' scores and the team name was
    // cut to a few letters. The values now take what two or three digits need (a wider one, "137.2", is still drawn
    // whole), the table is 80 pt wider and the game cards give that up.
    static let touchTable = Table(width: 460, valueWidth: 28, rankWidth: 22, badge: 24, spacing: PigSpacing.xs, inset: 2 * 16 + 2 * 8)

    #if os(tvOS)
    static let table = tvTable
    static let columns = 3
    static let cardHeight: CGFloat = 156
    #else
    static let table = touchTable
    static let columns = 2
    static let cardHeight: CGFloat = 130
    #endif
    static var standingsWidth: CGFloat { table.width }
}

struct SportFixtureContent: View {
    enum Source: Equatable { case nfl, league(String) }

    let app: AppModel
    let browse: BrowseModel
    let source: Source
    /// nil on the legacy Sport tab (no front page to match games against).
    let front: SportFront?
    let label: String
    let flow: SportRecordFlow
    @ObservedObject private var nfl: NFLPageModel
    @ObservedObject private var leagues: LeaguePageModel
    @ObservedObject private var preferences: F1PageModel
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.sportNarrow) private var narrow
    @Environment(\.sportHidesSpoilers) private var pageHidesSpoilers
    private var hidesSpoilers: Bool { preferences.hidesSpoilers || pageHidesSpoilers }
    @State private var round: String?
    @State private var view: String?
    @State private var tableGroup: String?

    init(app: AppModel, browse: BrowseModel, source: Source, front: SportFront?, label: String, flow: SportRecordFlow) {
        self.app = app
        self.browse = browse
        self.source = source
        self.front = front
        self.label = label
        self.flow = flow
        _nfl = ObservedObject(wrappedValue: browse.nflPage)
        _leagues = ObservedObject(wrappedValue: browse.leaguePages)
        _preferences = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var leagueName: String {
        switch source {
        case .nfl: return "NFL"
        case .league(let league): return league
        }
    }

    /// The account's followed names in this league's sport (C-U), the older NFL follow too.
    private var following: [String] {
        var names = preferences.preferences.teams[leagueName] ?? []
        if source == .nfl, let one = preferences.preferences.nflFollowing { names.append(one) }
        return names
    }

    private var fixture: FixtureLeague? {
        let hidden = hidesSpoilers
        switch source {
        case .nfl:
            guard let page = nfl.page, page.available else { return nil }
            return FixtureText.nfl(page, following: following, spoilerFree: hidden)
        case .league(let league):
            guard let page = leagues.pages[league], page.available else { return nil }
            return FixtureText.league(page, league: league, following: following, spoilerFree: hidden)
        }
    }

    /// #280: the league page's state; `available: false` is "not available right now" (before, it spun for ever).
    private var state: PageState {
        switch source {
        case .nfl: return nfl.state(label: label)
        case .league(let league): return leagues.state(league, label: label)
        }
    }

    /// The polling's next request (one retry clock).
    private var schedule: RefreshSchedule? {
        switch source {
        case .nfl: return nfl.schedule
        case .league(let league): return leagues.schedules[league]
        }
    }

    /// Asks again (the preferences first, as every refresh).
    private func retry() async {
        switch source {
        case .nfl: await nfl.refresh(preferences: preferences)
        case .league(let league): await leagues.refresh(league, preferences: preferences)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible {
            switch source {
            case .nfl: await nfl.keepFresh(preferences: preferences)
            case .league(let league): await leagues.keepFresh(league, preferences: preferences)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.fixture.\(leagueName)")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch state {
        case .loading:
            SportLeaguePlaceholder(kind: .fixture)
        case .failed(let failure):
            PigErrorState(failure: failure, retry: retry, identifier: "sport.fixture.error", schedule: schedule)
        case .empty:
            SportLeagueEmpty(app: app, title: PageWords.noRoundsTitle(label), text: PageWords.noRoundsText(label),
                             identifier: "sport.fixture.empty")
        case .content, .stale:
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                if case .stale(let since) = state {
                    PigStaleNotice(since: since, retry: retry, identifier: "sport.fixture.stale")
                }
                if let fixture { page(fixture, now: now) }
            }
        }
    }

    private func page(_ fixture: FixtureLeague, now: Date) -> some View {
        SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap + PigSpacing.s).callAsFunction {
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                roundPicker(fixture)
                if let shown = FixtureText.round(round, in: fixture) {
                    grid(shown, fixture: fixture, now: now)
                } else {
                    Text("No games in this round.").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if !fixture.views.isEmpty || hidesSpoilers {
                standings(fixture).sportSideWidth(SportFixtureMetrics.standingsWidth, narrow: narrow)
            }
        }
    }

    // MARK: Rounds

    private func roundPicker(_ fixture: FixtureLeague) -> some View {
        let shown = FixtureText.round(round, in: fixture)
        return ScrollView(.horizontal) { HStack(spacing: PigSpacing.s) {
            ForEach(fixture.rounds) { item in
                Button { round = item.key } label: {
                    Text(item.label).font(SportPageMetrics.rowName).lineLimit(1)
                }
                .buttonStyle(GuideFilterStyle(selected: shown?.key == item.key))
                .accessibilityAddTraits(shown?.key == item.key ? .isSelected : [])
                .accessibilityIdentifier("sport.fixture.round.\(item.key)")
            }
            if let note = shown?.note {
                Text(note).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1).padding(.leading, PigSpacing.s)
            }
        } }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .tvFocusSection()
    }

    private func grid(_ round: FixtureLeague.Round, fixture: FixtureLeague, now: Date) -> some View {
        LazyVGrid(columns: narrow ? [GridItem(.adaptive(minimum: 300), spacing: PigSpacing.m, alignment: .top)]
                    : Array(repeating: GridItem(.flexible(), spacing: PigSpacing.m, alignment: .top), count: SportFixtureMetrics.columns),
                  alignment: .leading, spacing: PigSpacing.m) {
            ForEach(round.games) { game in gameCard(game, fixture: fixture, now: now) }
        }
        .tvFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.fixture.grid.\(round.key)")
    }

    private func gameCard(_ game: FixtureLeague.Game, fixture: FixtureLeague, now: Date) -> some View {
        let card = FixtureText.card(for: game, league: fixture.league, in: front)
        let event = FixtureText.event(game, league: fixture.league)
        let sides = fixture.awayFirst ? [game.away, game.home] : [game.home, game.away]
        let channel = card?.channels.first?.name ?? game.channels.first?.name
        return Button {
            SportCardActions.select(card: card, event: event, app: app, presenter: presenter)
        } label: {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                    HStack(spacing: PigSpacing.s) {
                        SportBadge(name: side.name, logo: side.logo, league: fixture.league, client: browse.client,
                                   size: SportPageMetrics.badge, disc: side.logo == nil ? (side.abbr, side.color) : nil)
                        SportFollowStar(followed: side.followed)
                        Text(side.name).font(SportPageMetrics.rowName).lineLimit(1).pigMinimumScale(0.85, size: PigType.secondary)
                        if let record = side.record {
                            Text(record).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                        }
                        Spacer(minLength: 6)
                        // #228: a score is always drawn whole; the name and record give way
                        if let score = side.score { Text(score).font(SportPageMetrics.score).pigFigures().fixedSize().layoutPriority(1) }
                    }
                }
                if let situation = game.situation {
                    Text(situation).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: PigSpacing.s) {
                    if game.ongoing {
                        Circle().fill(Color.pigDanger).frame(width: 10, height: 10).accessibilityHidden(true)
                        Text(game.detail ?? "Live").font(SportPageMetrics.note.weight(.bold)).foregroundStyle(Color.pigDanger).lineLimit(1)
                    } else if let detail = game.detail {
                        Text("\(detail) · \(CricketPageText.dayDate(game.start))").font(SportPageMetrics.note.weight(.semibold))
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(SportFrontText.when(SportFrontText.date(game.start), now: now)).font(SportPageMetrics.note.weight(.bold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if game.status != "done" {
                        Text(channel ?? "Not in guide yet").font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(SportPageMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: SportFixtureMetrics.cardHeight, alignment: .topLeading)
            .sportFollowedCard(game.followed)
            .overlay {
                if game.ongoing && !game.followed {
                    RoundedRectangle(cornerRadius: SportPageMetrics.radius, style: .continuous)
                        .strokeBorder(Color.pigDanger.opacity(0.8), lineWidth: 2)
                }
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportPageMetrics.radius))
        .contextMenu {
            // Apple 115: the one menu's RECORD section (this game, every <team> game, More options…).
            if let record = SportCardActions.recordEvent(card: card, event: event), record.best != nil, game.status != "done" {
                SportRecordMenu(flow: flow, event: record, game: card.flatMap { $0.terminal ? nil : $0 })
            }
        }
        .accessibilityIdentifier("sport.fixture.game.\(game.id)")
    }

    // MARK: Standings

    @ViewBuilder
    private func standings(_ fixture: FixtureLeague) -> some View {
        let shown = FixtureText.view(view, in: fixture)
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(spacing: PigSpacing.s) {
                Text("Standings").font(SportPageMetrics.cardTitle)
                Spacer(minLength: 8)
                if fixture.views.count > 1 {
                    ForEach(fixture.views, id: \.name) { item in
                        Button { view = item.name } label: { Text(item.name).font(SportPageMetrics.rowDetail).lineLimit(1) }
                            .buttonStyle(GuideFilterStyle(selected: shown?.name == item.name))
                            .accessibilityIdentifier("sport.fixture.standings.\(item.name)")
                    }
                }
            }
            if hidesSpoilers {
                SportListCard(title: "Standings hidden", identifier: "sport.fixture.standings.hidden") {
                    SportHiddenNote(title: "", text: "Records, positions and points reveal results while Hide scores is on.", minHeight: 160)
                }
            } else if let shown {
                let groups = FixtureText.groups(shown)
                let group = groups.first { $0.name == tableGroup } ?? groups[0]
                if groups.count > 1 {
                    HStack(spacing: PigSpacing.s) {
                        ForEach(groups, id: \.name) { item in
                            Button { tableGroup = item.name } label: { Text(item.name).font(SportPageMetrics.rowDetail).lineLimit(1) }
                                .buttonStyle(GuideFilterStyle(selected: group.name == item.name))
                                .accessibilityIdentifier("sport.fixture.group.\(item.name)")
                        }
                    }
                }
                ForEach(Array(group.tables.enumerated()), id: \.offset) { _, table in
                    SportListCard(title: table.title ?? label, note: table.columns.joined(separator: " · "),
                                  identifier: "sport.fixture.table.\(table.title ?? "all")") {
                        tableRows(table)
                    }
                }
            }
        }
        .tvFocusSection()
    }

    private func tableRows(_ table: FixtureLeague.Table) -> some View {
        VStack(spacing: PigSpacing.xxs) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: narrow ? PigSpacing.xs : SportFixtureMetrics.table.spacing) {
                    Text(String(row.rank ?? index + 1)).font(SportPageMetrics.rowPos).foregroundStyle(.secondary).pigFigures()
                        .frame(minWidth: narrow ? 20 : SportFixtureMetrics.table.rankWidth, alignment: .trailing)
                    SportBadge(name: row.name, logo: row.logo, league: leagueName, client: browse.client,
                               size: narrow ? 20 : SportFixtureMetrics.table.badge)
                        .fixedSize()
                    SportFollowStar(followed: row.followed)
                    Text(row.name).font(SportPageMetrics.rowName).lineLimit(1).pigMinimumScale(0.8, size: PigType.secondary).layoutPriority(1)
                    Spacer(minLength: 4)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                        // #211: a value is drawn whole ("4-2-1", "137.2"); the team's name gives way.
                        Text(value ?? "–").font(SportPageMetrics.rowDetail).pigFigures().lineLimit(1).fixedSize()
                            .frame(minWidth: narrow ? 26 : SportFixtureMetrics.table.valueWidth, alignment: .trailing)
                    }
                }
                .frame(minHeight: SportPageMetrics.row - 4)
                .sportFollowedRow(row.followed)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
