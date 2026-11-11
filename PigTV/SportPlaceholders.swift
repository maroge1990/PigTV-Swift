import SwiftUI

// #280 (L1): the Sport pages' loading layouts, one per page type, drawn from the shared placeholder parts
// (PageStateViews.swift) at the sizes of what they stand for (the banner, the game cards, the fixture grid and standings,
// the session tiles, the scoreboard), so nothing jumps when the content arrives. Neutral shapes only: no words, scores,
// clocks or names. Each is wrapped in `PigLoadingPage` by its page.

/// The Sport banner's shape: the hero's words and buttons on the left, the list on the right.
struct SportBannerPlaceholder: View {
    var list = true

    var body: some View {
        PigPlaceholderBlock(height: SportBannerMetrics.height, radius: SportBannerMetrics.radius) {
            HStack(alignment: .top, spacing: SportBannerMetrics.gap) {
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    PigPlaceholderBar(width: 420)
                    PigPlaceholderBar(width: 560, height: PigPlaceholderMetrics.title)
                    PigPlaceholderBar(width: 180)
                    HStack(spacing: PigSpacing.m) {
                        PigPlaceholderChip(width: 160)
                        PigPlaceholderChip(width: 300)
                    }
                    .padding(.top, PigSpacing.s)
                }
                if list {
                    VStack(alignment: .leading, spacing: PigSpacing.s) {
                        PigPlaceholderBar(width: 380)
                        PigPlaceholderRows(count: 3)
                    }
                    .frame(width: SportBannerMetrics.listWidth)
                }
            }
        }
    }
}

/// A sport's rail on the front page: its header, then a row of game cards.
struct SportRailPlaceholder: View {
    var cards: Int

    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            PigPlaceholderTitle()
            HStack(alignment: .top, spacing: SportCardMetrics.spacing) {
                ForEach(0..<cards, id: \.self) { _ in
                    PigPlaceholderCard(width: SportCardMetrics.width, height: SportCardMetrics.height)
                }
            }
        }
    }
}

/// The Sport front page on Apple TV and iPad (`SportFrontTVPage`): the banner, then two rails.
struct SportFrontPlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "sport.front.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                SportBannerPlaceholder()
                SportRailPlaceholder(cards: 3)
                SportRailPlaceholder(cards: 4)
            }
        }
    }
}

/// A sport's page on Apple TV and iPad (`SportPageView`): the banner with its leagues, then the league's games.
struct SportPagePlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "sport.page.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.l) {
                SportBannerPlaceholder()
                SportLeaguePlaceholder.Layout(kind: .games)
            }
        }
    }
}

/// What a league shows below the banner (or on the iPhone's league page), while its own page loads.
struct SportLeaguePlaceholder: View {
    enum Kind: Equatable {
        case games, fixture, events, motorsport, cricket

        /// The placeholder for what a league shows (`SportPageRules.content`).
        static func of(_ content: SportPageRules.LeagueContent) -> Kind {
            switch content {
            case .f1: .motorsport
            case .nfl, .league: .fixture
            case .cricket: .cricket
            case .events: .events
            case .motorCards, .games: .games
            }
        }
    }
    let kind: Kind

    var body: some View {
        PigLoadingPage(identifier: "sport.league.loading") { Layout(kind: kind) }
    }

    /// The layout alone (a page that draws more around it wraps it itself).
    struct Layout: View {
        let kind: Kind
        @Environment(\.sportNarrow) private var narrow

        var body: some View {
            switch kind {
            case .games: games
            case .fixture: fixture
            case .events: events
            case .motorsport: motorsport
            case .cricket: cricket
            }
        }

        private var games: some View {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                PigPlaceholderTitle(width: 220)
                PigPlaceholderGrid(count: 4, cardWidth: SportCardMetrics.width, cardHeight: SportCardMetrics.height,
                                   gap: SportCardMetrics.spacing)
            }
        }

        /// The round chips and the round's grid, the standings beside (stacked when narrow).
        private var fixture: some View {
            SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap + PigSpacing.s).callAsFunction {
                VStack(alignment: .leading, spacing: PigSpacing.m) {
                    HStack(spacing: PigSpacing.s) {
                        PigPlaceholderChip(width: 160)
                        PigPlaceholderChip(width: 160)
                    }
                    PigPlaceholderGrid(count: 6, cardWidth: narrow ? 300 : nil, cardHeight: SportFixtureMetrics.cardHeight,
                                       columns: narrow ? nil : SportFixtureMetrics.columns, gap: PigSpacing.m)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                PigPlaceholderBlock {
                    VStack(alignment: .leading, spacing: PigSpacing.m) {
                        PigPlaceholderTitle(width: 200)
                        PigPlaceholderRows(count: 8)
                    }
                }
                .sportSideWidth(SportFixtureMetrics.standingsWidth, narrow: narrow)
            }
        }

        /// The week's event cards, then a list.
        private var events: some View {
            VStack(alignment: .leading, spacing: SportPageMetrics.spacing) {
                PigPlaceholderGrid(count: narrow ? 2 : 3, cardWidth: SportCardMetrics.width, cardHeight: SportCardMetrics.height,
                                   gap: SportCardMetrics.spacing)
                PigPlaceholderBlock {
                    VStack(alignment: .leading, spacing: PigSpacing.m) {
                        PigPlaceholderTitle(width: 220)
                        PigPlaceholderRows(count: 5)
                    }
                }
            }
        }

        /// Formula 1: the session tiles and the circuit, then the two standings tables.
        private var motorsport: some View {
            VStack(alignment: .leading, spacing: SportPageMetrics.spacing) {
                let tiles = HStack(alignment: .top, spacing: PigSpacing.m) {
                    ForEach(0..<5, id: \.self) { _ in
                        PigPlaceholderCard(width: SportMotorMetrics.tileWidth, height: SportPageMetrics.tileHeight)
                    }
                    PigPlaceholderCard(width: SportMotorMetrics.circuitWidth, height: SportPageMetrics.tileHeight)
                }
                if narrow {
                    ScrollView(.horizontal) { tiles }.scrollIndicators(.hidden).scrollDisabled(true)
                } else {
                    tiles
                }
                SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
                    ForEach(0..<2, id: \.self) { _ in
                        PigPlaceholderBlock {
                            VStack(alignment: .leading, spacing: PigSpacing.m) {
                                PigPlaceholderTitle(width: 220)
                                PigPlaceholderRows(count: narrow ? 5 : 10)
                            }
                        }
                    }
                }
            }
        }

        /// Cricket: the lead match's scoreboard and days, the series beside.
        private var cricket: some View {
            SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
                VStack(alignment: .leading, spacing: PigSpacing.m) {
                    PigPlaceholderBar(width: 520, height: PigPlaceholderMetrics.title)
                    PigPlaceholderBlock {
                        VStack(alignment: .leading, spacing: PigSpacing.m) {
                            ForEach(0..<2, id: \.self) { _ in
                                HStack(spacing: PigSpacing.m) {
                                    PigPlaceholderDisc(size: PigPlaceholderMetrics.chip)
                                    PigPlaceholderBar(width: 220, height: PigPlaceholderMetrics.title)
                                    Spacer(minLength: 0)
                                    PigPlaceholderBar(width: 120, height: PigPlaceholderMetrics.title)
                                }
                            }
                        }
                    }
                    HStack(spacing: PigSpacing.s) {
                        ForEach(0..<(narrow ? 2 : 5), id: \.self) { _ in
                            PigPlaceholderChip(width: 120)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                PigPlaceholderBlock {
                    VStack(alignment: .leading, spacing: PigSpacing.m) {
                        PigPlaceholderTitle(width: 220)
                        PigPlaceholderRows(count: 5, badge: false)
                    }
                }
                .sportSideWidth(SportCricketMetrics.sideWidth, narrow: narrow)
            }
        }
    }
}

/// The cricket page's series column, for its placeholder (`CricketPageView` keeps its own metrics private).
nonisolated enum SportCricketMetrics {
    #if os(tvOS)
    static let sideWidth: CGFloat = 560
    #else
    static let sideWidth: CGFloat = 400
    #endif
}

#if os(iOS)
/// The iPhone's Sport front page (`SportFrontPhonePage`): the follow card, its dots, then two sports' cards of rows.
struct SportFrontPhonePlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "sport.front.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                SportPhoneHeroPlaceholder()
                ForEach(0..<2, id: \.self) { _ in SportPhoneRowsPlaceholder() }
            }
        }
    }
}

/// A sport's page on the iPhone (`SportPhonePage`): the league chips, the carousel's card, then a card of rows.
struct SportPhonePagePlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "sport.page.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                HStack(spacing: PigSpacing.s) {
                    ForEach(0..<3, id: \.self) { _ in PigPlaceholderChip(width: 90) }
                }
                .padding(.horizontal, SportPhoneMetrics.edge)
                SportPhoneHeroPlaceholder()
                SportPhoneRowsPlaceholder()
            }
        }
    }
}

/// The carousel's card: a kicker, two badges with names, a line and the two buttons.
struct SportPhoneHeroPlaceholder: View {
    var body: some View {
        PigPlaceholderBlock(height: SportPhoneMetrics.cardHeight) {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                PigPlaceholderBar(width: 80)
                HStack(spacing: PigSpacing.l) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(spacing: PigSpacing.s) {
                            PigPlaceholderDisc(size: SportPhoneMetrics.heroBadge)
                            PigPlaceholderBar(width: 90)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: PigSpacing.m) {
                    PigPlaceholderBar(height: PigPlaceholderMetrics.chip + PigSpacing.s)
                    PigPlaceholderBar(height: PigPlaceholderMetrics.chip + PigSpacing.s)
                }
            }
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
    }
}

/// A sport's header and its card of fixture rows.
struct SportPhoneRowsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            PigPlaceholderTitle(width: 170)
            PigPlaceholderBlock {
                VStack(alignment: .leading, spacing: PigSpacing.l) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: PigSpacing.m) {
                            PigPlaceholderDisc(size: PigPlaceholderMetrics.disc + PigSpacing.s)
                            VStack(alignment: .leading, spacing: PigSpacing.s) {
                                PigPlaceholderBar(width: 150, height: PigPlaceholderMetrics.line + PigSpacing.xs)
                                PigPlaceholderBar(width: 200)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
    }
}
#endif
