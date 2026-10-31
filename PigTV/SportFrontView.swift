import SwiftUI

// C-R (#21, D-39, Apple 89): the Sport front page, mock-up "Blend 1 · hero band" (DESIGN.md › Sport pages). Under the
// tab bar: the followed sports as tiles (live dot, one line; press for the sport's page); the hero band (left the hero
// card with Watch / Record or Remind me / Record over the circuit map or the hero team's badge, faded; right the
// followed teams and drivers, a list that flips the hero, compact beyond three); then one rail per followed sport (live
// cards first, then results and next starts). Spoiler-free hides scores, situations and results (neutral progress
// stays); without the scores feed the page says so once and shows the guide's channels and times. Data:
// `SportFrontModel`; words and the hero rule: `SportFrontText`, `SportFrontHero`. Every play started here is recorded
// with origin "sport-front".

private enum FrontMetrics {
    #if os(tvOS)
    static let section: CGFloat = 30
    static let tileWidth: CGFloat = 300
    static let tileSpacing: CGFloat = 24
    static let heroHeight: CGFloat = 400
    static let sideWidth: CGFloat = 600
    static let columnGap: CGFloat = 40
    static let cardWidth: CGFloat = 420
    static let cardSpacing: CGFloat = 30
    static let radius: CGFloat = 22
    static let badge: CGFloat = 56
    static let smallBadge: CGFloat = 36
    static let heroBadge: CGFloat = 48
    static let backdrop = CGSize(width: 420, height: 360)
    static let padding = EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
    static let heroPadding = EdgeInsets(top: 28, leading: 34, bottom: 28, trailing: 34)
    static let kicker: Font = .system(size: 20, weight: .heavy)
    static let heroTitle: Font = .system(size: 38, weight: .bold)
    static let heroTeam: Font = .system(size: 28, weight: .semibold)
    static let heroScore: Font = .system(size: 34, weight: .heavy)
    static let tileTitle: Font = .system(size: 26, weight: .bold)
    static let name: Font = .system(size: 24, weight: .semibold)
    static let team: Font = .system(size: 22, weight: .semibold)
    static let score: Font = .system(size: 24, weight: .heavy)
    static let detail: Font = .system(size: 19)
    static let sectionTitle: Font = .system(size: 26, weight: .bold)
    #else
    static let section: CGFloat = 22
    static let tileWidth: CGFloat = 200
    static let tileSpacing: CGFloat = 14
    static let heroHeight: CGFloat = 260
    static let sideWidth: CGFloat = 380
    static let columnGap: CGFloat = 24
    static let cardWidth: CGFloat = 280
    static let cardSpacing: CGFloat = 14
    static let radius: CGFloat = 16
    static let badge: CGFloat = 40
    static let smallBadge: CGFloat = 28
    static let heroBadge: CGFloat = 34
    static let backdrop = CGSize(width: 240, height: 200)
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    static let heroPadding = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
    static let kicker: Font = .caption.weight(.heavy)
    static let heroTitle: Font = .title2.bold()
    static let heroTeam: Font = .headline
    static let heroScore: Font = .title2.weight(.heavy)
    static let tileTitle: Font = .headline
    static let name: Font = .subheadline.weight(.semibold)
    static let team: Font = .subheadline.weight(.semibold)
    static let score: Font = .headline.weight(.heavy)
    static let detail: Font = .caption
    static let sectionTitle: Font = .title3.bold()
    #endif
}

struct SportFrontView: View {
    static let origin = "sport-front"
    let app: AppModel
    let browse: BrowseModel

    var body: some View {
        NavigationStack {
            SportFrontPage(app: app, browse: browse)
                .pigPageBackdrop()
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        // The event page and channel picker belong to the screen (SportPresenter), with the plays' origin.
        .sportPages(app: app, browse: browse, clock: Date(), origin: Self.origin)
    }
}

private struct SportFrontPage: View {
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject private var model: SportFrontModel
    /// The F1 page's data: the circuit map behind a race hero (C-P `info.map`), and the household's preferences shared
    /// by every sport page: spoiler-free as this device last read it hides scores even before the next answer.
    @ObservedObject private var f1: F1PageModel
    @Environment(\.sportPresenter) private var presenter
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var recording: SportEvent?
    @State private var followHelp = false
    @State private var allFollows = false

    init(app: AppModel, browse: BrowseModel) {
        self.app = app
        self.browse = browse
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var wide: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh(preferences: f1) }
        // Spoiler-free switched on or off (here, on a sport page or another device): hidden at once by `hidden`, and a
        // fresh answer so turning it off brings the scores back.
        .onChange(of: f1.hidesSpoilers) { Task { await model.load() } }
        .task(id: model.heroGame?.league == "F1") {
            // A race hero's backdrop is its circuit map: the F1 page's data, fetched once when such a hero shows.
            guard model.heroGame?.league == "F1", browse.sportPagesEnabled, f1.page == nil else { return }
            await f1.load()
        }
        .detailCover(item: $recording) { event in
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme(on: best)) { _ in
                    recording = nil
                }
            }
        }
        .alert("Follow a sport", isPresented: $followHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose the sports, teams and drivers you follow in the PigTV web app, under Settings → Sports. They appear here on every device.")
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: FrontMetrics.section) {
                PigPageHeader(title: "Sport", subtitle: Text(now, format: .dateTime.weekday(.wide).day().month(.wide)))
                if let front = model.front {
                    if model.stale, let updated = model.updatedAt {
                        Text("Couldn't refresh. Last updated \(updated.formatted(date: .omitted, time: .shortened)).")
                            .font(FrontMetrics.detail).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sport.front.stale")
                    }
                    if front.scoresUnavailable { scoresBanner }
                    tiles(front, now: now)
                    if front.isEmpty {
                        emptyState
                    } else {
                        heroBand(front, now: now)
                        ForEach(front.rails, id: \.league) { rail in railView(rail, front: front, now: now) }
                    }
                } else if !model.loaded {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    unavailable
                }
            }
            .padding(.bottom, 60)
            #if os(iOS)
            .padding(.horizontal, 20)
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
        }
        .scrollClipDisabled()
    }

    /// Scores, situations and results are hidden when either the answer or the household's preference says so.
    private var hidden: Bool { f1.hidesSpoilers }

    // MARK: Tiles

    private func tiles(_ front: SportFront, now: Date) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: FrontMetrics.tileSpacing) {
                ForEach(front.sports, id: \.league) { sport in
                    NavigationLink { destination(sport.league) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(sport.league).font(FrontMetrics.tileTitle).lineLimit(1)
                                if sport.live > 0 || sport.line == "live" {
                                    Circle().fill(Color.pigDanger).frame(width: 12, height: 12).accessibilityHidden(true)
                                }
                            }
                            Text(SportFrontText.tileLine(sport, in: front, now: now)).font(FrontMetrics.detail)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(FrontMetrics.padding)
                        .frame(width: FrontMetrics.tileWidth, alignment: .leading)
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: FrontMetrics.radius))
                    .accessibilityIdentifier("sport.front.tile.\(sport.league)")
                }
                addSportTile
            }
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .tvFocusSection()
    }

    private var addSportTile: some View {
        Button { followHelp = true } label: {
            Label("Follow a sport", systemImage: "plus").font(FrontMetrics.name).lineLimit(1)
                .padding(FrontMetrics.padding)
                .frame(width: FrontMetrics.tileWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: FrontMetrics.radius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: FrontMetrics.radius))
        .accessibilityIdentifier("sport.front.addSport")
    }

    /// A tile's page: Formula 1 and the NFL have their own; any other sport opens the Sport tab's list on that league.
    @ViewBuilder
    private func destination(_ league: String) -> some View {
        if league == "F1" && browse.sportPagesEnabled {
            F1PageView(app: app, browse: browse, model: browse.f1Page)
        } else if league == "NFL" && browse.nflPageEnabled {
            NFLPageView(app: app, browse: browse)
        } else {
            SportView(app: app, browse: browse, sport: browse.sport, initialLeague: league, embedded: true,
                      origin: SportFrontView.origin)
        }
    }

    // MARK: The hero band

    @ViewBuilder
    private func heroBand(_ front: SportFront, now: Date) -> some View {
        if wide {
            HStack(alignment: .top, spacing: FrontMetrics.columnGap) {
                heroCard(front, now: now).frame(maxWidth: .infinity)
                if !front.follows.isEmpty { follows(front, now: now).frame(width: FrontMetrics.sideWidth) }
            }
        } else {
            heroCard(front, now: now)
            if !front.follows.isEmpty { follows(front, now: now) }
        }
    }

    @ViewBuilder
    private func heroCard(_ front: SportFront, now: Date) -> some View {
        Group {
            if let game = model.heroGame {
                heroContent(game, front: front, now: now)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing on right now").font(FrontMetrics.heroTitle)
                        .accessibilityIdentifier("sport.front.hero.title")
                    Text("Your sports' next games are below.").font(FrontMetrics.detail).foregroundStyle(.secondary)
                }
            }
        }
        .padding(FrontMetrics.heroPadding)
        .frame(maxWidth: .infinity, minHeight: FrontMetrics.heroHeight, alignment: .topLeading)
        .background {
            ZStack(alignment: .trailing) {
                Color.pigRaised
                if let game = model.heroGame, let backdrop = backdrop(game, front: front) {
                    ChannelArtwork(logo: backdrop, client: browse.client, fill: true)
                        .frame(width: FrontMetrics.backdrop.width, height: FrontMetrics.backdrop.height)
                        .opacity(0.22)
                        .padding(.trailing, 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FrontMetrics.radius, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.front.hero")
    }

    /// The circuit map for a race, else the hero team's badge.
    private func backdrop(_ game: SportsGame, front: SportFront) -> String? {
        if game.league == "F1" { return f1.page?.weekend?.info?.map }
        if let index = model.heroFollowIndex, let logo = front.follows[index].cachedLogo { return logo }
        return game.competitors.lazy.compactMap(\.cachedLogo).first
    }

    @ViewBuilder
    private func heroContent(_ game: SportsGame, front: SportFront, now: Date) -> some View {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let scores = drawn.scores
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                let kicker = drawn.kicker
                Text(kicker).font(FrontMetrics.kicker).padding(.horizontal, 10).padding(.vertical, 3)
                    .background(kicker == "LIVE" ? Color.pigDanger : Color.pigAccent.opacity(0.25), in: Capsule())
                    .foregroundStyle(kicker == "LIVE" ? Color.white : Color.pigAccentText)
                Text(game.league).font(FrontMetrics.kicker).foregroundStyle(.secondary)
            }
            Text(game.title).font(FrontMetrics.heroTitle).lineLimit(2)
                .accessibilityIdentifier("sport.front.hero.title")
            if game.competitors.count >= 2 {
                ForEach(Array(game.competitors.prefix(2).enumerated()), id: \.offset) { index, team in
                    HStack(spacing: 14) {
                        SportBadge(name: team.name, logo: team.cachedLogo, league: game.league, client: browse.client,
                                   size: FrontMetrics.heroBadge)
                        Text(team.name).font(FrontMetrics.heroTeam).lineLimit(1)
                        if let scores {
                            Text(scores[index]).font(FrontMetrics.heroScore).monospacedDigit()
                        }
                    }
                }
            }
            if let line = drawn.situation {
                Text(line).font(FrontMetrics.detail).foregroundStyle(.secondary)
            }
            if drawn.kicker == "NEXT" {
                Text(SportFrontText.when(SportFrontText.date(game.start), now: now)).font(FrontMetrics.detail)
            }
            Text(game.channels.first?.name ?? game.availabilityLabel).font(FrontMetrics.detail).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            heroActions(game, now: now)
        }
    }

    @ViewBuilder
    private func heroActions(_ game: SportsGame, now: Date) -> some View {
        if let event = SportFrontText.event(game), !game.terminal {
            HStack(spacing: 18) {
                switch SportFrontText.action(game, now: now) {
                case .watch:
                    Button("Watch", systemImage: "play.fill") { watch(game, event: event) }
                        .pigPrimaryButton()
                        .accessibilityIdentifier("sport.front.hero.watch")
                case .remind:
                    Button("Remind me", systemImage: "bell") { app.watchWhenStarts(event, now: Date()) }
                        .pigPrimaryButton()
                        .accessibilityIdentifier("sport.front.hero.remind")
                case .details, .none:
                    EmptyView()
                }
                Button("Record", systemImage: "record.circle") { recording = event }
                    .accessibilityIdentifier("sport.front.hero.record")
            }
            .tvFocusSection()
        }
    }

    // MARK: The follows

    private func follows(_ front: SportFront, now: Date) -> some View {
        let compact = front.follows.count > 3
        let order = compact ? SportFrontText.compactOrder(front.follows) : Array(front.follows.indices)
        let shown = compact && !allFollows ? Array(order.prefix(4)) : order
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(shown, id: \.self) { index in followRow(index, front: front, compact: compact, now: now) }
                if compact && !allFollows && order.count > 4 {
                    Button { allFollows = true } label: {
                        Text("\(order.count - 4) more").font(FrontMetrics.detail.weight(.semibold))
                            .padding(FrontMetrics.padding).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 16))
                    .accessibilityIdentifier("sport.front.follows.more")
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(maxHeight: wide ? FrontMetrics.heroHeight : nil)
        .tvFocusSection()
    }

    private func followRow(_ index: Int, front: SportFront, compact: Bool, now: Date) -> some View {
        let follow = front.follows[index]
        let selected = model.heroFollowIndex == index
        return Button { model.select(follow: index) } label: {
            HStack(spacing: 14) {
                SportBadge(name: follow.name, logo: follow.cachedLogo, league: follow.league, client: browse.client,
                           size: compact ? FrontMetrics.smallBadge : FrontMetrics.badge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(follow.name).font(FrontMetrics.name).lineLimit(1)
                    if !compact {
                        Text(SportFrontText.followLine(follow, in: front, now: now)).font(FrontMetrics.detail)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if compact {
                    Text(SportFrontText.shortWhen(follow, now: now)).font(FrontMetrics.detail).foregroundStyle(.secondary)
                } else if follow.state == "live" {
                    pill("LIVE", live: true)
                } else if follow.state == "next" {
                    pill("Next", live: false)
                }
            }
            .padding(compact ? EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18) : FrontMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.pigAccent).frame(width: 4).padding(.vertical, 10).padding(.leading, 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 16))
        .accessibilityIdentifier("sport.front.follow.\(index)")
        .accessibilityValue(selected ? "In the hero" : "")
    }

    private func pill(_ text: String, live: Bool) -> some View {
        Text(text).font(FrontMetrics.detail.weight(.heavy)).padding(.horizontal, 10).padding(.vertical, 2)
            .background(live ? Color.pigDanger : Color.pigAccent.opacity(0.2), in: Capsule())
            .foregroundStyle(live ? Color.white : Color.pigAccentText)
    }

    // MARK: Rails

    private func railView(_ rail: SportFront.Rail, front: SportFront, now: Date) -> some View {
        let games = front.games(in: rail)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(rail.league).font(FrontMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
                if let sport = front.sports.first(where: { $0.league == rail.league }) {
                    Text(SportFrontText.tileLine(sport, in: front, now: now)).font(FrontMetrics.detail).foregroundStyle(.secondary)
                }
            }
            if games.isEmpty {
                Text("Nothing scheduled").font(FrontMetrics.detail).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: FrontMetrics.cardSpacing) {
                        ForEach(games) { game in card(game, front: front, now: now) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .tvFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.front.rail.\(rail.league)")
    }

    private func card(_ game: SportsGame, front: SportFront, now: Date) -> some View {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let scores = drawn.scores
        return Button { select(game, now: Date()) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(drawn.status).font(FrontMetrics.detail.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(drawn.status == "LIVE" ? Color.pigDanger : Color.pigAccent.opacity(0.2), in: Capsule())
                        .foregroundStyle(drawn.status == "LIVE" ? Color.white : Color.pigAccentText)
                    Spacer(minLength: 6)
                    if game.followed == true {
                        Image(systemName: "star.fill").foregroundStyle(Color.pigAccentText).accessibilityLabel("Followed")
                    }
                }
                if game.competitors.count >= 2 {
                    ForEach(Array(game.competitors.prefix(2).enumerated()), id: \.offset) { index, team in
                        HStack(spacing: 10) {
                            SportBadge(name: team.name, logo: team.cachedLogo, league: game.league, client: browse.client,
                                       size: FrontMetrics.smallBadge)
                            Text(team.name).font(FrontMetrics.team).lineLimit(1)
                            Spacer(minLength: 6)
                            if let scores { Text(scores[index]).font(FrontMetrics.score).monospacedDigit() }
                        }
                    }
                } else {
                    Text(game.title).font(FrontMetrics.team).lineLimit(2)
                    if let session = game.session { Text(session).font(FrontMetrics.detail).foregroundStyle(.secondary) }
                }
                if let line = drawn.situation {
                    Text(line).font(FrontMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                } else if game.status == "scheduled" {
                    Text(SportFrontText.when(SportFrontText.date(game.start), now: now)).font(FrontMetrics.detail)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(game.channels.first?.name ?? game.availabilityLabel).font(FrontMetrics.detail)
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(SportFrontText.actionLabel(game, now: now)).font(FrontMetrics.detail.weight(.bold))
                        .foregroundStyle(Color.pigAccentText).lineLimit(1)
                }
            }
            .padding(FrontMetrics.padding)
            .frame(width: FrontMetrics.cardWidth, alignment: .leading)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: FrontMetrics.radius))
        .contextMenu {
            Button("Make this the hero", systemImage: "star") { model.pin(game.id) }
        }
        .accessibilityIdentifier("sport.front.game.\(game.id)")
    }

    // MARK: Actions

    private func select(_ game: SportsGame, now: Date) {
        guard let event = SportFrontText.event(game) else { return }
        switch SportFrontText.action(game, now: now) {
        case .watch: watch(game, event: event)
        case .remind, .details: presenter?.open(event, .details)
        case .none: break
        }
    }

    /// Watch, revalidated at the press: an answer drawn earlier (or kept after a failed refresh) may describe an
    /// airing that has ended, and the player would tune the channel whatever it shows now. Then the details instead.
    private func watch(_ game: SportsGame, event: SportEvent) {
        if let live = SportFrontText.playable(game, at: Date()) { play(live) } else { presenter?.open(event, .details) }
    }

    private func play(_ event: SportEvent) {
        if let presenter { presenter.play(event) } else { app.playSportEvent(event, origin: SportFrontView.origin) }
    }

    // MARK: States

    private var scoresBanner: some View {
        Label(SportFrontText.scoresUnavailable, systemImage: "info.circle")
            .font(FrontMetrics.detail).foregroundStyle(.secondary)
            .padding(FrontMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: FrontMetrics.radius, style: .continuous))
            .accessibilityIdentifier("sport.front.scoresUnavailable")
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sportscourt").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("Follow a sport to start").font(DetailType.title).multilineTextAlignment(.center)
            Text("Choose the sports, teams and drivers you follow in the PigTV web app, under Settings → Sports.")
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

/// A team's badge: its logo (a logo-cache path, as channel logos, through the same cache) or a monogram disc in the
/// league's colour: without a logo, while it loads, and when it fails (C-R, D-39), never an empty disc.
struct SportBadge: View {
    let name: String
    let logo: String?
    let league: String
    let client: APIClient?
    var size: CGFloat
    @State private var decoded: DecodedLogo?

    var body: some View {
        Group {
            if SportFrontText.badgeShowsLogo(logo: logo, decoded: decoded != nil), let decoded {
                Image(uiImage: decoded.image).resizable().scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Text(SportFrontText.monogram(name)).font(.system(size: size * 0.38, weight: .heavy)).foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .frame(width: size, height: size)
                    .background(Color(teamHex: SportFrontText.leagueColor(league)) ?? .gray, in: Circle())
            }
        }
        .accessibilityHidden(true)
        .task(id: logo) {
            decoded = nil
            guard let logo, let client, let key = client.artworkKey(logo) else { return }
            let result = await ChannelArtwork.decodedLogo(key: key, logo: logo, client: client)
            guard !Task.isCancelled else { return }
            decoded = result
        }
    }
}
