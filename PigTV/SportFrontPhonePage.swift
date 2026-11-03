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
    @Environment(\.sportPresenter) private var presenter
    @State private var shown: String?

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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
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
                        ForEach(SportPhoneLayout.groups(front, hidden: hidden, now: now, labels: model.labels)) { group in
                            groupView(group, front: front, now: now)
                        }
                        also(front, now: now)
                    }
                } else if !model.loaded {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    VStack(spacing: 14) {
                        SportPhoneEmpty(icon: "sportscourt", title: "Sport is unavailable right now",
                                        text: model.error ?? "The sport data could not be reached. The guide and playback are not affected.")
                        Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 40)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PigBrandMark(width: 34, height: 28)
            Text("Sport").font(.largeTitle.weight(.heavy)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("page.header.title")
            Spacer(minLength: 8)
            Text(SportPhoneLayout.scoresChip(hidden: hidden)).font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.pigRaised, in: Capsule())
                .accessibilityIdentifier("sport.front.scores")
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
    }

    // MARK: The carousel

    @ViewBuilder
    private func carousel(_ front: SportFront, now: Date) -> some View {
        let cards = SportPhoneLayout.cards(front, hidden: hidden, now: now, labels: model.labels)
        if !cards.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        followCard(card, front: front, now: now)
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
            .accessibilityIdentifier("sport.front.carousel")
            let index = cards.firstIndex { $0.id == shown } ?? 0
            HStack(spacing: 6) {
                ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { offset, _ in
                    Capsule().fill(offset == index ? Color.pigAccent : Color.secondary.opacity(0.6))
                        .frame(width: offset == index ? 18 : 6, height: 6)
                }
                Text(SportPhoneLayout.position(index, of: cards.count)).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SportPhoneLayout.position(index, of: cards.count))
            .frame(maxWidth: .infinity)
        }
    }

    private func followCard(_ card: SportPhoneCard, front: SportFront, now: Date) -> some View {
        let game = front.game(card.gameId)
        let league = front.follows[card.index].league
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if card.live { Circle().fill(Color.pigDanger).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(card.kicker).font(.caption2.weight(.bold)).tracking(1).lineLimit(1)
                    .foregroundStyle(card.live ? Color.pigDanger : Color.secondary)
            }
            Button {
                if let game { SportGamePress.select(game, app: app, presenter: presenter) } else { open(front.follows[card.index].sportName) }
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
            .accessibilityIdentifier("sport.front.follow.\(card.index)")
            Spacer(minLength: 0)
            if let game { actions(game, team: card.team, now: now) }
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
                    .accessibilityIdentifier("sport.front.card.watch")
                case .remind:
                    Button { app.watchWhenStarts(event, now: Date()) } label: {
                        Label("Remind me", systemImage: "bell").frame(maxWidth: .infinity)
                    }
                    .pigPrimaryButton()
                    .accessibilityIdentifier("sport.front.card.remind")
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
                .accessibilityIdentifier("sport.front.card.record")
            }
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: A sport's card

    private func groupView(_ group: SportPhoneGroup, front: SportFront, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open(group.sport) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.sport).font(.title3.weight(.heavy))
                    Text("›").font(.title3.weight(.heavy)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(group.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.sport), \(group.note), open its page")
            .accessibilityIdentifier("sport.rail.header.\(group.sport)")
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { offset, row in
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
                        .accessibilityIdentifier("sport.front.game.\(game.id)")
                    }
                }
            }
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Also in your sports").font(.footnote).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(sports, id: \.self) { sport in
                            Button { open(sport) } label: {
                                HStack(spacing: 6) {
                                    Text(sport).font(.subheadline.weight(.bold))
                                    if let line = SportFrontLayout.alsoLine(sport, in: front, now: now) {
                                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14).frame(minHeight: 36)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if row.sides.count == 2 {
                    SportBadge(name: row.sides[0].name, logo: row.sides[0].logo, league: row.league, client: client,
                               size: SportPhoneMetrics.rowBadge)
                    title.font(.subheadline.weight(.bold)).lineLimit(1)
                    SportBadge(name: row.sides[1].name, logo: row.sides[1].logo, league: row.league, client: client,
                               size: SportPhoneMetrics.rowBadge)
                } else {
                    Text(row.badge ?? "").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.pigOnStatus)
                        .frame(width: SportPhoneMetrics.rowBadge, height: SportPhoneMetrics.rowBadge)
                        .background(Color(teamHex: SportFrontText.leagueColor(row.league)) ?? Color.pigDanger,
                                    in: RoundedRectangle(cornerRadius: PigRadius.inner, style: .continuous))
                        .accessibilityHidden(true)
                    Text(row.title).font(.subheadline.weight(.bold)).lineLimit(1)
                }
                Spacer(minLength: 10)
                if let score = row.score {
                    Text(score).font(.system(.subheadline, design: .rounded).weight(.heavy)).monospacedDigit().lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: 6) {
                if let live = row.live {
                    Text("● \(live)").font(.caption.weight(.bold)).foregroundStyle(Color.pigDanger).monospacedDigit()
                        .fixedSize()
                    if !row.sub.isEmpty { Text("·") }
                }
                Text(row.sub).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .padding(.leading, 30)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, 48).padding(.horizontal, 24).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
#endif
