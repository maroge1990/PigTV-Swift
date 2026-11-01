import SwiftUI

// D-43 (1 Nov, DESIGN.md › Apple TV sport pages): a sport's page, reached from the front page's rail header ("Football ›"),
// its "Also in your sports" buttons or a follow. The banner: the hero (a follow live in this sport, else the sport's
// league live, else your next game in it, C-R's order within the sport; with nothing live or next, the league's next
// game with Remind me; never an empty banner) and the sport's followed leagues (C-R `sports[]` entries of that `sport`,
// in the order sent). Selecting a league shows its page below the banner: Formula 1, the NFL and cricket their existing
// pages (without their own header and hero, until D-43's per-sport layouts), any other league its games from C-R as
// cards. One league: the banner runs full width. Data: the front page's own answer (`SportFrontModel`); rules
// `SportPageRules` (tests `SportPageTests`).

/// A sport page in the front page's navigation stack.
struct SportRoute: Hashable, Sendable {
    let sport: String
}

/// The sport page's choices. Pure.
nonisolated enum SportPageRules {
    enum HeroReason: String, Equatable, Sendable { case followLive, leagueLive, followNext, leagueNext, none }

    struct Hero: Equatable, Sendable {
        let gameId: String?
        let reason: HeroReason
        /// The follow the hero belongs to (its index in `follows`), for the badge behind it.
        var followIndex: Int? = nil
    }

    /// What a league shows below the banner.
    enum LeagueContent: Equatable, Sendable { case f1, nfl, cricket, games }

    /// The sport's followed leagues in the order sent (C-R since 0427: playing now first). Without `sports[]` entries
    /// (an older server), the leagues its rails name.
    static func leagues(_ sport: String, in front: SportFront) -> [SportFront.Sport] {
        let entries = front.sports.filter { $0.sportName == sport }
        if !entries.isEmpty { return entries }
        var seen = Set<String>()
        return front.rails.filter { SportFrontLayout.sport(of: $0.league, railSport: $0.sport, in: front) == sport }
            .filter { seen.insert($0.league).inserted }
            .map { SportFront.Sport(league: $0.league, live: 0, next: nil, line: "quiet", sport: sport) }
    }

    /// The sport's games: its rails' cards in the server's order (live first, then results, then upcoming), each once.
    static func games(_ sport: String, in front: SportFront) -> [SportsGame] {
        var seen = Set<String>()
        return front.rails.filter { SportFrontLayout.sport(of: $0.league, railSport: $0.sport, in: front) == sport }
            .flatMap { front.games(in: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// A league's games (its rails), in the server's order.
    static func games(league: String, in front: SportFront) -> [SportsGame] {
        var seen = Set<String>()
        return front.rails.filter { $0.league == league }.flatMap { front.games(in: $0) }.filter { seen.insert($0.id).inserted }
    }

    /// The hero: a follow of this sport live (the server's own pick when it is one, else the first in the order sent),
    /// else a live game in the sport's leagues, else a follow's next game (the soonest), else the league's next game
    /// (the soonest scheduled one), else none.
    static func hero(_ sport: String, in front: SportFront) -> Hero {
        let follows = front.follows.indices.filter { front.follows[$0].sportName == sport && front.game(front.follows[$0].gameId) != nil }
        let live = follows.filter { front.follows[$0].state == "live" }
        if let index = front.hero.followIndex, live.contains(index) {
            return Hero(gameId: front.follows[index].gameId, reason: .followLive, followIndex: index)
        }
        if let index = live.first { return Hero(gameId: front.follows[index].gameId, reason: .followLive, followIndex: index) }
        let games = games(sport, in: front)
        if let game = games.first(where: { SportFrontHero.ongoing.contains($0.status) }) {
            return Hero(gameId: game.id, reason: .leagueLive)
        }
        let next = follows.filter { front.follows[$0].state == "next" }
        func start(_ index: Int) -> Double { front.follows[index].start ?? front.game(front.follows[index].gameId)?.start ?? .infinity }
        if let index = next.min(by: { start($0) < start($1) }) {
            return Hero(gameId: front.follows[index].gameId, reason: .followNext, followIndex: index)
        }
        if let game = games.filter({ $0.status == "scheduled" }).min(by: { $0.start < $1.start }) {
            return Hero(gameId: game.id, reason: .leagueNext)
        }
        return Hero(gameId: nil, reason: .none)
    }

    /// The league the page opens on: the hero's, when it is one of the sport's, else the first.
    static func openingLeague(_ sport: String, in front: SportFront, hero: Hero) -> String? {
        let leagues = leagues(sport, in: front).map(\.league)
        if let league = front.game(hero.gameId)?.league, leagues.contains(league) { return league }
        return leagues.first
    }

    /// The banner's list: the sport's leagues, each "2 live", its next start, or "Nothing scheduled".
    static func leagueItems(_ sport: String, in front: SportFront, now: Date, calendar: Calendar = .current) -> [SportBannerItem] {
        leagues(sport, in: front).map { entry in
            let live = entry.live > 0 || entry.line == "live"
            let trailing = live ? "\(max(entry.live, 1)) live"
                : entry.next.map { SportFrontText.when(SportFrontText.date($0.start), now: now, calendar: calendar) }
                ?? "Nothing scheduled"
            return SportBannerItem(id: entry.league, title: entry.league, trailing: trailing, live: live)
        }
    }

    /// Formula 1, the NFL and cricket have pages of their own (with the server's flags); any other league shows its games.
    static func content(league: String, sport: String, f1: Bool, nfl: Bool, cricket: Bool) -> LeagueContent {
        if league == "F1" && f1 { return .f1 }
        if league == "NFL" && nfl { return .nfl }
        if (league == "Cricket" || sport == "Cricket") && cricket { return .cricket }
        return .games
    }

    /// The banner when the sport has nothing at all in the answer (no game in the next 72 hours).
    static func quietHero(_ sport: String) -> SportBannerHero {
        SportBannerHero(kicker: sport.uppercased(), live: false, title: sport, line: "Nothing in the next three days")
    }
}

struct SportPageView: View {
    let app: AppModel
    let browse: BrowseModel
    let sport: String
    @ObservedObject private var model: SportFrontModel
    @ObservedObject private var f1: F1PageModel
    @StateObject private var flow = SportRecordFlow()
    @Environment(\.sportPresenter) private var presenter
    /// The league shown below the banner (nil: the opening league).
    @State private var league: String?
    /// The page opens with focus on the hero's first button (else the back button).
    @FocusState private var heroFocused: Bool

    init(app: AppModel, browse: BrowseModel, sport: String) {
        self.app = app
        self.browse = browse
        self.sport = sport
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .whileVisible { await model.keepFresh(preferences: f1) }
        .task(id: heroGame?.league == "F1") {
            // A race hero's backdrop is its circuit map: the F1 page's data, fetched once when such a hero shows.
            guard heroGame?.league == "F1", browse.sportPagesEnabled, f1.page == nil else { return }
            await f1.load()
        }
        .sportRecordFlow(flow, browse: browse)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.page.\(sport)")
    }

    private var heroGame: SportsGame? {
        guard let front = model.front else { return nil }
        return front.game(SportPageRules.hero(sport, in: front).gameId)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                if let front = model.front {
                    let hero = SportPageRules.hero(sport, in: front)
                    let leagues = SportPageRules.leagues(sport, in: front)
                    let shown = league.flatMap { l in leagues.contains { $0.league == l } ? l : nil }
                        ?? SportPageRules.openingLeague(sport, in: front, hero: hero)
                    banner(front, hero: hero, leagues: leagues, shown: shown, now: now)
                    if let shown { leagueContent(shown, front: front, now: now) }
                } else {
                    ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.bottom, 60)
            #if os(iOS)
            .padding(.horizontal, 20)
            #endif
        }
        .scrollClipDisabled()
        .defaultFocus($heroFocused, true, priority: .userInitiated)
    }

    private func banner(_ front: SportFront, hero: SportPageRules.Hero, leagues: [SportFront.Sport], shown: String?,
                        now: Date) -> some View {
        let game = front.game(hero.gameId)
        let words = game.map { SportFrontLayout.hero($0, in: front, hidden: f1.hidesSpoilers, now: now) }
            ?? SportPageRules.quietHero(sport)
        let items = SportPageRules.leagueItems(sport, in: front, now: now)
        return SportBanner(hero: words, items: items, listTitle: "\(sport.uppercased()) · YOUR LEAGUES",
                           selected: shown.flatMap { s in leagues.firstIndex { $0.league == s } },
                           backdrop: game.flatMap { backdrop($0, follow: hero.followIndex, front: front) },
                           client: browse.client, showsBack: true,
                           onSelect: { index in if leagues.indices.contains(index) { league = leagues[index].league } }) {
            SportHeroButtons(game: game, now: now, app: app, flow: flow, focus: $heroFocused)
        }
    }

    /// The circuit map for a race (dark when there is one), else the hero team's badge.
    private func backdrop(_ game: SportsGame, follow: Int?, front: SportFront) -> SportBannerBackdrop? {
        if game.league == "F1" {
            guard let map = f1.page?.weekend?.info?.map else { return nil }
            return .map(light: map, dark: f1.page?.weekend?.info?.mapDark)
        }
        if let follow, front.follows.indices.contains(follow), let logo = front.follows[follow].cachedLogo { return .badge(logo) }
        return game.competitors.lazy.compactMap(\.cachedLogo).first.map { .badge($0) }
    }

    @ViewBuilder
    private func leagueContent(_ league: String, front: SportFront, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch SportPageRules.content(league: league, sport: sport, f1: browse.sportPagesEnabled,
                                          nfl: browse.nflPageEnabled, cricket: browse.cricketPageEnabled) {
            case .f1: F1PageView(app: app, browse: browse, model: browse.f1Page, embedded: true)
            case .nfl: NFLPageView(app: app, browse: browse, embedded: true)
            case .cricket: CricketPageView(app: app, browse: browse, embedded: true)
            case .games: games(league, front: front, now: now)
            }
        }
        .id(league)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.page.league.\(league)")
    }

    @ViewBuilder
    private func games(_ league: String, front: SportFront, now: Date) -> some View {
        let games = SportPageRules.games(league: league, in: front)
        VStack(alignment: .leading, spacing: 12) {
            Text(league).font(SportSectionMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
            if games.isEmpty {
                Text("Nothing in the next three days").font(SportCardMetrics.detail).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: SportCardMetrics.width, maximum: SportCardMetrics.width),
                                             spacing: SportCardMetrics.spacing, alignment: .topLeading)],
                          alignment: .leading, spacing: SportCardMetrics.spacing) {
                    ForEach(games) { game in
                        SportGameCard(game: game, front: front, hidden: f1.hidesSpoilers, now: now, client: browse.client) {
                            SportGamePress.select(game, app: app, presenter: presenter)
                        }
                    }
                }
            }
        }
        .tvFocusSection()
    }
}
