import SwiftUI

// D-43 (1 Nov): the C-V leagues under their sport page's banner (rules: SportEventsModels.swift). UFC (V2-UFC-1): the
// main card and the prelims as two lists, each finished bout with its winner, round and clock. Tennis (V2-Tennis-4,
// V3-Tennis-4-none): rails, Your players (only when someone followed plays this week), Live now, Tonight, Results today,
// then the draws. Golf (V3-Golf-final, -none): the leaderboard's top 11 on the left; on the right the followed players'
// cards with Also this week below as slim rows (Also this week only with nobody followed). IndyCar and NASCAR: the race
// (SportRaceContent). Spoiler-free hides set scores, winners, results and the leaderboard. Each event's C-R card sits
// above it: Watch and Record go through it (C-V has no channels).

enum SportEventsMetrics {
    #if os(tvOS)
    static let matchWidth: CGFloat = 420
    static let golfSide: CGFloat = 640
    static let setWidth: CGFloat = 30
    #else
    static let matchWidth: CGFloat = 300
    static let golfSide: CGFloat = 420
    static let setWidth: CGFloat = 22
    #endif
}

struct SportEventsContent: View {
    let app: AppModel
    let browse: BrowseModel
    let league: String
    /// The sport page's leagues (golf's Also this week reads the other followed golf leagues).
    let leagues: [String]
    let front: SportFront
    let labels: [String: String]
    let flow: SportRecordFlow
    @ObservedObject private var model: SportEventsPageModel
    @ObservedObject private var preferences: F1PageModel
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.sportNarrow) private var narrow
    @Environment(\.sportHidesSpoilers) private var pageHidesSpoilers
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone (R5-Golf-iPhone): the leaderboard's position, player and to par, without the rounds.
    private var compact: Bool { sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    init(app: AppModel, browse: BrowseModel, league: String, leagues: [String], front: SportFront, labels: [String: String],
         flow: SportRecordFlow) {
        self.app = app
        self.browse = browse
        self.league = league
        self.leagues = leagues
        self.front = front
        self.labels = labels
        self.flow = flow
        _model = ObservedObject(wrappedValue: browse.eventPages)
        _preferences = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var label: String { SportLabels.label(league, in: labels) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh(league, preferences: preferences) }
        .task(id: model.pages[league]?.kind ?? "") {
            // Golf's Also this week: the sport's other followed leagues, once each.
            guard model.pages[league]?.kind == "golf" else { return }
            for other in leagues where other != league && SportEventLeagues.all.contains(other) && model.pages[other] == nil {
                await model.load(other)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.events.\(league)")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let hidden = preferences.hidesSpoilers || pageHidesSpoilers
        // #280: the league page's state; `available: false` is "not available right now" (before, it spun for ever). An
        // empty week is drawn by each kind (golf's other tours, a race's last winner and next race still show).
        let state = model.state(league, label: label)
        switch state {
        case .loading:
            SportLeaguePlaceholder(kind: .events)
        case .failed(let failure):
            PigErrorState(failure: failure, retry: retry, identifier: "sport.events.error",
                           schedule: model.schedules[league])
        case .content, .stale, .empty:
            if let page = model.pages[league] {
                VStack(alignment: .leading, spacing: SportPageMetrics.spacing) {
                    if case .stale(let since) = state {
                        PigStaleNotice(since: since, retry: retry, identifier: "sport.events.stale")
                    }
                    switch page.kind {
                    case "race":
                        SportRaceContent(app: app, page: page, label: label, front: front, hidden: hidden)
                    case "fight":
                        fight(page, now: now, hidden: hidden)
                    case "golf":
                        golf(page, now: now, hidden: hidden)
                    default:
                        tennis(page, now: now, hidden: hidden)
                    }
                }
            }
        }
    }

    /// Asks again (the preferences first, as every refresh).
    private func retry() async { await model.refresh(league, preferences: preferences) }

    // MARK: The event's card (Watch, Record)

    @ViewBuilder
    private func eventHeader(_ event: SportEventsEvent, now: Date, hidden: Bool, detail: String? = nil) -> some View {
        HStack(alignment: .center, spacing: PigSpacing.m) {
            if let card = front.game(event.id) {
                SportGameCard(game: card, front: front, hidden: hidden, now: now, client: browse.client,
                              onSelect: { SportGamePress.select(card, app: app, presenter: presenter) }, flow: flow)
            }
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                Text(event.name).font(SportPageMetrics.cardTitle).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text([detail, [event.venue?.name, event.venue?.city].compactMap { $0 }.first,
                      event.breakLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .tvFocusSection()
    }

    /// Several events (a tennis week's tournaments): their C-R cards in one row, each with its place.
    private func eventCards(_ events: [SportEventsEvent], now: Date, hidden: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: PigSpacing.m) {
                ForEach(events) { event in
                    if let card = front.game(event.id) {
                        SportGameCard(game: card, front: front, hidden: hidden, now: now, client: browse.client,
                                      onSelect: { SportGamePress.select(card, app: app, presenter: presenter) }, flow: flow)
                    }
                }
            }
            .padding(.vertical, PigSpacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .tvFocusSection()
    }

    // MARK: UFC

    @ViewBuilder
    private func fight(_ page: SportEventsPage, now: Date, hidden: Bool) -> some View {
        if let event = SportEventsText.focus(page.events) {
            let card = SportEventsText.card(event)
            eventHeader(event, now: now, hidden: hidden)
            SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
                boutList("Main card", card.main, event: event, mainEvent: card.main.last?.id, now: now, hidden: hidden)
                boutList("Prelims", card.prelims, event: event, mainEvent: nil, now: now, hidden: hidden)
            }
            .fixedSize(horizontal: false, vertical: true)
            .tvFocusSection()
            let others = page.events.filter { $0.id != event.id }
            if !others.isEmpty { alsoThisWeek(others, now: now, hidden: hidden) }
        } else {
            emptyWeek
        }
    }

    private func boutList(_ title: String, _ bouts: [FightBout], event: SportEventsEvent, mainEvent: String?, now: Date,
                          hidden: Bool) -> some View {
        let from = bouts.compactMap(\.start).min().map { "From \(SportFrontText.when(SportFrontText.date($0), now: now))" }
        return SportListCard(title: title, note: from, identifier: "sport.fight.\(title == "Main card" ? "main" : "prelims")") {
            if bouts.isEmpty {
                Text("No bouts listed.").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                ForEach(bouts) { bout in
                    let winner = SportEventsText.winner(bout, spoilerFree: hidden)
                    let followed = bout.fighters.contains { SportEventsText.followed($0.name, in: event) }
                    HStack(spacing: PigSpacing.s) {
                        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                            if let weight = bout.weightClass {
                                Text(weight.uppercased()).font(SportPageMetrics.kicker).tracking(1.2).foregroundStyle(.secondary)
                            }
                            HStack(spacing: PigSpacing.xs) {
                                ForEach(Array(bout.fighters.enumerated()), id: \.offset) { index, fighter in
                                    if index > 0 { Text("v").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary) }
                                    SportFollowStar(followed: SportEventsText.followed(fighter.name, in: event))
                                    Text(fighter.name).font(SportPageMetrics.rowName.weight(winner == index ? .heavy : .semibold))
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        let line = SportEventsText.boutLine(bout, isMainEvent: bout.id == mainEvent, spoilerFree: hidden)
                        Text(line).font(SportPageMetrics.rowDetail.weight(.bold))
                            .foregroundStyle(SportEventsText.ongoing.contains(bout.status) ? Color.pigDanger : Color.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("sport.bout.\(bout.id).line")
                    }
                    .frame(minHeight: SportPageMetrics.row + 8)
                    .sportFollowedRow(followed)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sport.bout.\(bout.id)")
                }
            }
        }
    }

    // MARK: Tennis

    @ViewBuilder
    private func tennis(_ page: SportEventsPage, now: Date, hidden: Bool) -> some View {
        if page.events.isEmpty {
            emptyWeek
        } else {
            let rails = SportEventsText.rails(page.events, now: now)
            eventCards(page.events, now: now, hidden: hidden)
            if !rails.yourPlayers.isEmpty {
                matchRail("Your players", rails.yourPlayers, events: page.events, now: now, hidden: hidden, id: "yours")
            }
            matchRail("Live now", rails.liveNow, events: page.events, now: now, hidden: hidden, id: "live",
                      empty: "No match in play right now.")
            matchRail("Tonight", rails.tonight, events: page.events, now: now, hidden: hidden, id: "tonight",
                      empty: "Nothing more today.")
            matchRail("Results today", rails.resultsToday, events: page.events, now: now, hidden: hidden, id: "results",
                      note: hidden ? "Hidden while Hide scores is on" : nil, empty: "No results yet today.")
            draws(page.events, now: now, hidden: hidden)
        }
    }

    private func matchRail(_ title: String, _ matches: [TennisMatch], events: [SportEventsEvent], now: Date, hidden: Bool,
                           id: String, note: String? = nil, empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                Text(title).font(SportSectionMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
                if let note { Text(note).font(SportPageMetrics.note).foregroundStyle(.secondary) }
            }
            if matches.isEmpty, let empty {
                Text(empty).font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PigSpacing.m) {
                        ForEach(matches) { match in
                            matchCard(match, event: events.first { $0.matches.contains(match) }, now: now, hidden: hidden)
                        }
                    }
                    .padding(.vertical, PigSpacing.xs)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .tvFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.tennis.rail.\(id)")
    }

    private func matchCard(_ match: TennisMatch, event: SportEventsEvent?, now: Date, hidden: Bool) -> some View {
        let followed = event.map { e in match.players.contains { SportEventsText.followed($0.name, in: e) } } ?? false
        let live = SportEventsText.ongoing.contains(match.status)
        let card = event.flatMap { front.game($0.id) }
        return Button {
            if let card { SportGamePress.select(card, app: app, presenter: presenter) }
        } label: {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack {
                    Text(SportEventsText.kicker(match)).font(SportPageMetrics.kicker).tracking(1.2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(SportEventsText.state(match, now: now, spoilerFree: hidden)).font(SportPageMetrics.kicker)
                        .foregroundStyle(live ? Color.pigDanger : Color.secondary)
                }
                ForEach(Array(match.players.enumerated()), id: \.offset) { index, player in
                    HStack(spacing: PigSpacing.s) {
                        SportFollowStar(followed: event.map { SportEventsText.followed(player.name, in: $0) } ?? false)
                        Text(SportEventsText.playerName(player))
                            .font(SportPageMetrics.rowName.weight(!hidden && player.winner == true ? .heavy : .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        ForEach(Array(SportEventsText.sets(match, player: index, spoilerFree: hidden).enumerated()), id: \.offset) { _, games in
                            Text(games).font(SportPageMetrics.score).pigFigures()
                                .frame(width: SportEventsMetrics.setWidth, alignment: .trailing)
                        }
                    }
                }
                if let court = match.court {
                    Text(court).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(SportPageMetrics.padding)
            .frame(width: SportEventsMetrics.matchWidth, alignment: .topLeading)
            .sportFollowedCard(followed)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportPageMetrics.radius))
        .accessibilityIdentifier("sport.tennis.match.\(match.id)")
    }

    @ViewBuilder
    private func draws(_ events: [SportEventsEvent], now: Date, hidden: Bool) -> some View {
        let draws = events.flatMap { event in event.draws.map { (event, $0) } }
        if !draws.isEmpty {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Text("Draws").font(SportSectionMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
                ForEach(Array(draws.enumerated()), id: \.offset) { _, pair in
                    let (event, draw) = pair
                    Text("\(event.name) · \(draw.name)".uppercased()).font(SportPageMetrics.kicker).tracking(1.2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: PigSpacing.m) {
                            ForEach(Array(draw.rounds.enumerated()), id: \.offset) { _, round in
                                SportListCard(title: round.name, identifier: "sport.tennis.draw.\(draw.name).\(round.name)") {
                                    VStack(alignment: .leading, spacing: PigSpacing.xs) {
                                        ForEach(round.matchIds, id: \.self) { id in
                                            if let match = event.matches.first(where: { $0.id == id }) {
                                                drawLine(match, event: event, hidden: hidden)
                                            }
                                        }
                                    }
                                }
                                .frame(width: SportEventsMetrics.matchWidth)
                            }
                        }
                        .padding(.vertical, PigSpacing.xs)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            }
            .tvFocusSection()
        }
    }

    private func drawLine(_ match: TennisMatch, event: SportEventsEvent, hidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(match.players.enumerated()), id: \.offset) { index, player in
                let followed = SportEventsText.followed(player.name, in: event)
                HStack(spacing: PigSpacing.xs) {
                    SportFollowStar(followed: followed)
                    Text(SportEventsText.playerName(player))
                        .font(SportPageMetrics.rowDetail.weight(!hidden && player.winner == true ? .heavy : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SportEventsText.sets(match, player: index, spoilerFree: hidden).joined(separator: " "))
                        .font(SportPageMetrics.rowDetail).pigFigures().foregroundStyle(.secondary)
                }
                .sportFollowedRow(followed)
            }
        }
        .padding(.vertical, PigSpacing.xs)
    }

    // MARK: Golf

    @ViewBuilder
    private func golf(_ page: SportEventsPage, now: Date, hidden: Bool) -> some View {
        if let event = SportEventsText.focus(page.events) {
            let layout = SportEventsText.golf(event, spoilerFree: hidden)
            let others = page.events.filter { $0.id != event.id } + leagues.filter { $0 != league }
                .compactMap { model.pages[$0] }.filter { $0.kind == "golf" }.flatMap(\.events)
            eventHeader(event, now: now, hidden: hidden, detail: event.round.map { "Round \($0)" })
            SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
                leaderboard(layout, event: event, hidden: hidden).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: SportPageMetrics.gap) {
                    if !layout.yourPlayers.isEmpty {
                        VStack(alignment: .leading, spacing: PigSpacing.s) {
                            Text("Your players").font(SportPageMetrics.cardTitle).accessibilityAddTraits(.isHeader)
                            ForEach(layout.yourPlayers, id: \.name) { player in playerCard(player, event: event, hidden: hidden) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("sport.golf.yours")
                    }
                    alsoThisWeek(others, now: now, hidden: hidden)
                }
                .sportSideWidth(SportEventsMetrics.golfSide, narrow: narrow)
            }
            .tvFocusSection()
        } else {
            emptyWeek
        }
    }

    private func leaderboard(_ layout: SportEventsText.GolfLayout, event: SportEventsEvent, hidden: Bool) -> some View {
        SportListCard(title: "Leaderboard", note: hidden ? nil : "Top 11", identifier: "sport.golf.leaderboard") {
            if hidden {
                SportHiddenNote(title: "Leaderboard hidden",
                                text: "Hide scores is on. Positions and scores reveal the result; the field and its round stay visible.")
            } else {
                VStack(spacing: PigSpacing.xxs) {
                    HStack(spacing: PigSpacing.s) {
                        Text("POS").frame(width: 50, alignment: .leading)
                        Text("PLAYER")
                        Spacer(minLength: 6)
                        Text("TO PAR").frame(width: 80, alignment: .trailing)
                        // The iPhone (R5-Golf-iPhone): position, player and to par; the rounds stay on wider pages.
                        if !compact { ForEach(1...3, id: \.self) { Text("R\($0)").frame(width: 56, alignment: .trailing) } }
                    }
                    .font(SportPageMetrics.kicker).tracking(1).foregroundStyle(.secondary)
                    ForEach(Array(layout.leaderboard.enumerated()), id: \.offset) { _, row in
                        let followed = SportEventsText.followed(row.name, in: event)
                        HStack(spacing: PigSpacing.s) {
                            Text(row.pos ?? row.status?.uppercased() ?? "–").font(SportPageMetrics.rowPos).foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            SportFollowStar(followed: followed)
                            Text(row.name).font(SportPageMetrics.rowName).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(row.toPar ?? "–").font(SportPageMetrics.rowPos).pigFigures().frame(width: 80, alignment: .trailing)
                            if !compact {
                                ForEach(Array(SportEventsText.firstRounds(row).enumerated()), id: \.offset) { _, strokes in
                                    Text(strokes.map(String.init) ?? "–").font(SportPageMetrics.rowDetail).pigFigures()
                                        .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                }
                            }
                        }
                        .frame(minHeight: SportPageMetrics.row)
                        .sportFollowedRow(followed)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func playerCard(_ player: SportEventsText.GolfCard, event: SportEventsEvent, hidden: Bool) -> some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                HStack(spacing: PigSpacing.s) {
                    SportFollowStar(followed: true)
                    Text(player.name).font(SportPageMetrics.tileTitle).lineLimit(1)
                    Spacer(minLength: 6)
                    if let pos = player.pos { Text(pos).font(SportPageMetrics.rowPos).foregroundStyle(.secondary) }
                    if let toPar = player.toPar { Text(toPar).font(SportPageMetrics.score).pigFigures() }
                }
                if hidden {
                    Text(["In the field", event.round.map { "round \($0) in play" }].compactMap { $0 }.joined(separator: " · "))
                        .font(SportPageMetrics.note).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: PigSpacing.m) {
                        ForEach(Array(player.rounds.enumerated()), id: \.offset) { index, strokes in
                            Text("R\(index + 1) \(strokes.map(String.init) ?? "–")").font(SportPageMetrics.note).pigFigures()
                        }
                        Spacer(minLength: 6)
                        if let gap = player.gap {
                            Text("TO THE LEAD").font(SportPageMetrics.kicker).tracking(1).foregroundStyle(.secondary)
                            Text(gap).font(SportPageMetrics.note.weight(.bold))
                        }
                    }
                }
            }
            .padding(SportPageMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: SportPageMetrics.radius, style: .continuous))
            .sportFollowedCard(true)
        }
        .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: SportPageMetrics.radius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sport.golf.player.\(player.name)")
    }

    // MARK: Also this week

    private func alsoThisWeek(_ events: [SportEventsEvent], now: Date, hidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            Text("Also this week").font(SportPageMetrics.cardTitle).accessibilityAddTraits(.isHeader)
            if events.isEmpty {
                Text("Nothing else this week.").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                let card = front.game(event.id)
                Button { if let card { SportGamePress.select(card, app: app, presenter: presenter) } } label: {
                    HStack(spacing: PigSpacing.s) {
                        Text(event.name).font(SportPageMetrics.rowName).lineLimit(1)
                        if let league = card?.league {
                            Text(SportLabels.label(league, in: labels).uppercased()).font(SportPageMetrics.kicker).tracking(1)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(SportEventsText.alsoLine(event, now: now, spoilerFree: hidden)).font(SportPageMetrics.rowDetail.weight(.semibold))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, PigSpacing.m).frame(minHeight: max(SportPageMetrics.row + 14, PigFocus.minTarget))
                    .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: 14))
                .accessibilityIdentifier("sport.also.event.\(event.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.alsoThisWeek")
    }

    /// #280 (E1): the league's one action, Open the TV Guide (SportLeagueEmpty).
    private var emptyWeek: some View {
        SportLeagueEmpty(app: app, title: PageWords.emptyWeekTitle(label), text: PageWords.emptyWeekText, identifier: "sport.events.empty")
    }
}
