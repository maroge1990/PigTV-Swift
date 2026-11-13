import SwiftUI
import ImageIO

// D-43 (1 Nov, mock-ups V2-Motor-1, V2-Motor-4): the Motorsport page's content under the banner (rules in
// SportMotorModels.swift). Formula 1: five session tiles and a circuit-stats tile with the map, then the starting grid
// (or the last race), the drivers' and the constructors' standings side by side, ten each. MotoGP and Supercars: their
// C-R cards in the tile row. IndyCar and NASCAR: the entry list, the last winner and the next race (C-V `race`).

enum SportMotorMetrics {
    #if os(tvOS)
    static let tileWidth: CGFloat = 262
    /// #298: a session tile gives way to this when the row has less room (the Apple TV's page is narrower than five
    /// 262 pt tiles and the circuit).
    static let tileMinWidth: CGFloat = 220
    static let circuitWidth: CGFloat = 400
    static let map = CGSize(width: 150, height: 96)
    #else
    static let tileWidth: CGFloat = 190
    /// #298: an 11-inch iPad in landscape gives the row about 1,146 pt, where five 190 pt tiles and the circuit need 1,330.
    static let tileMinWidth: CGFloat = 150
    static let circuitWidth: CGFloat = 300
    static let map = CGSize(width: 110, height: 70)
    #endif
    static var tileSpacing: CGFloat { PigSpacing.m }
}

/// Formula 1 under the banner.
struct SportF1Content: View {
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject private var model: F1PageModel
    /// Observed for a pending "watch when it starts".
    @ObservedObject private var appState: AppModel
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sportNarrow) private var narrow
    @Environment(\.sportHidesSpoilers) private var pageHidesSpoilers

    init(app: AppModel, browse: BrowseModel) {
        self.app = app
        self.browse = browse
        _model = ObservedObject(wrappedValue: browse.f1Page)
        _appState = ObservedObject(wrappedValue: app)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("f1.page")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let spoilerFree = SportSpoilers.hidden(preference: model.hidesSpoilers, answer: nil, page: pageHidesSpoilers)
        // #280: the page's state; `available: false` is "not available right now" (before, it spun for ever).
        let state = model.state()
        switch state {
        case .loading:
            SportLeaguePlaceholder(kind: .motorsport)
        case .failed(let failure):
            PigErrorState(failure: failure, retry: { await model.load() }, identifier: "f1.error", schedule: model.schedule)
        case .empty, .emptyStale:
            VStack(alignment: .leading, spacing: SportPageMetrics.spacing) {
                if state.isStale {
                    PigStaleNotice(since: state.staleSince, retry: { await model.load() }, identifier: "f1.stale")
                }
                SportLeagueEmpty(app: app, title: PageWords.noRaceTitle, text: PageWords.noRaceText, identifier: "f1.empty")
            }
        case .content, .stale:
            if let page = model.page, let weekend = page.weekend {
                VStack(alignment: .leading, spacing: SportPageMetrics.spacing) {
                    if case .stale(let since) = state {
                        PigStaleNotice(since: since, retry: { await model.load() }, identifier: "f1.stale")
                    }
                    F1TileRow(tiles: SportMotorText.tiles(weekend, now: now, spoilerFree: spoilerFree), weekend: weekend,
                              client: browse.client) { event in
                        if F1PageText.watchesNow(event, now: Date()) {
                            if let presenter { presenter.play(event) } else { app.playSportEvent(event) }
                        } else {
                            presenter?.open(event, .details)
                        }
                    }
                    lists(page, spoilerFree: spoilerFree)
                }
            }
        }
    }

    private func lists(_ page: F1Page, spoilerFree: Bool) -> some View {
        let lists = SportMotorText.lists(page, followed: SportMotorText.followedDrivers(model.preferences), spoilerFree: spoilerFree)
        let hiddenText = "Hide scores is on. Grids, finishing orders and points stay hidden until it is turned off in Settings."
        return SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
            SportListCard(title: lists.gridTitle ?? "Last race", identifier: "f1.results") {
                if lists.hidden { SportHiddenNote(title: "Results hidden", text: hiddenText) }
                else if lists.grid.isEmpty { emptyNote("No results yet.") }
                else { rows(lists.grid) }
            }
            SportListCard(title: "Drivers", note: lists.standingsNote, identifier: "f1.standings.drivers") {
                if lists.hidden { SportHiddenNote(title: "Results hidden", text: hiddenText) }
                else if lists.drivers.isEmpty { emptyNote("No standings yet.") }
                else { rows(lists.drivers) }
            }
            SportListCard(title: "Constructors", note: lists.standingsNote, identifier: "f1.standings.constructors") {
                if lists.hidden { SportHiddenNote(title: "Results hidden", text: hiddenText) }
                else if lists.constructors.isEmpty { emptyNote("No standings yet.") }
                else { rows(lists.constructors) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .tvFocusSection()
    }

    private func rows(_ rows: [SportMotorText.ListRow]) -> some View {
        VStack(spacing: PigSpacing.xxs) {
            ForEach(rows, id: \.pos) { row in
                HStack(spacing: PigSpacing.s) {
                    Text(String(row.pos)).font(SportPageMetrics.rowPos).foregroundStyle(.secondary).pigFigures()
                        .frame(minWidth: 28, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 3).fill(Color(teamHex: row.teamColor) ?? Color.pigBorder).frame(width: 6, height: 22)
                        .accessibilityHidden(true)
                    SportFollowStar(followed: row.followed)
                    Text(row.name).font(SportPageMetrics.rowName).lineLimit(1)
                    Spacer(minLength: 6)
                    if let detail = row.detail, row.points == nil {
                        Text(detail).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let points = row.points, !points.isEmpty {
                        Text(points).font(SportPageMetrics.rowPos).pigFigures()
                    }
                }
                .frame(minHeight: SportPageMetrics.row)
                .sportFollowedRow(row.followed)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(SportPageMetrics.rowDetail).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// MotoGP and Supercars: their C-R cards (sessions, or the event weekend) in the session-tile row, nothing invented.
struct SportMotorCardsContent: View {
    let app: AppModel
    let league: String
    let front: SportFront
    let hidden: Bool
    let now: Date
    let client: APIClient?
    let label: String
    /// Apple 115: the cards' long-press RECORD section.
    var flow: SportRecordFlow? = nil
    @Environment(\.sportPresenter) private var presenter

    var body: some View {
        let games = SportMotorText.cardTiles(SportPageRules.games(league: league, in: front))
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            Text(label).font(SportSectionMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
            if games.isEmpty {
                // #280 (E1): the league's one action, Open the TV Guide (SportLeagueEmpty).
                SportLeagueEmpty(app: app, title: PageWords.nothingSoonTitle, text: PageWords.nothingSoonText(label),
                                 identifier: "sport.league.empty")
            } else {
                HStack(alignment: .top, spacing: SportCardMetrics.spacing) {
                    ForEach(games) { game in
                        SportGameCard(game: game, front: front, hidden: hidden, now: now, client: client,
                                      onSelect: { SportGamePress.select(game, app: app, presenter: presenter) }, flow: flow)
                    }
                }
            }
        }
        .tvFocusSection()
    }
}

/// IndyCar and NASCAR (C-V `race`, V2-Motor-4): the race's entry list (alphabetical, never a running order), the last
/// winner (hidden when spoiler-free) and the next race. No standings, practice or running order: the feed has none.
struct SportRaceContent: View {
    let app: AppModel
    let page: SportEventsPage
    let label: String
    let front: SportFront
    let hidden: Bool
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.sportNarrow) private var narrow

    var body: some View {
        let event = SportEventsText.focus(page.events)
        let race = SportEventsText.race(page, event: event, spoilerFree: hidden)
        let followed = Set(event?.followed ?? [])
        SportColumns.layout(narrow: narrow, spacing: SportPageMetrics.gap).callAsFunction {
            SportListCard(title: "Entry list",
                          note: race.entries.isEmpty ? nil : "\(race.entries.count) drivers · alphabetical, not a running order",
                          identifier: "sport.race.entries") {
                if race.entries.isEmpty {
                    Text("The entry list appears once the feed has it.").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PigSpacing.s, alignment: .leading), count: narrow ? 2 : 3),
                              alignment: .leading, spacing: PigSpacing.xs) {
                        ForEach(race.entries, id: \.self) { name in
                            HStack(spacing: PigSpacing.s) {
                                SportFollowStar(followed: followed.contains(name))
                                Text(name).font(SportPageMetrics.rowName).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: SportPageMetrics.row, alignment: .leading)
                            .sportFollowedRow(followed.contains(name))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: SportPageMetrics.gap) {
                SportListCard(title: "Last race", note: race.lastRace, identifier: "sport.race.last") {
                    if hidden {
                        Label("Winner hidden", systemImage: "eye.slash").font(SportPageMetrics.rowName).foregroundStyle(.secondary)
                    } else if let winner = race.lastWinner {
                        Text("Won by \(winner)").font(SportPageMetrics.tileTitle)
                        Text("The feed gives the winner, not the finishing order").font(SportPageMetrics.note).foregroundStyle(.secondary)
                    } else {
                        Text("No race yet this season.").font(SportPageMetrics.rowDetail).foregroundStyle(.secondary)
                    }
                }
                SportListCard(title: "Next race", note: SportMotorText.nextLine(race.next), identifier: "sport.race.next",
                              action: { open(race.next) }) {
                    Text(race.next?.name ?? "No race scheduled").font(SportPageMetrics.tileTitle).lineLimit(2)
                }
                SportListCard(title: "Standings", identifier: "sport.race.standings") {
                    Text("Not in ESPN's free \(label) feed, so the page leaves them out.").font(SportPageMetrics.note)
                        .foregroundStyle(.secondary)
                }
            }
            .sportSideWidth(560, narrow: narrow)
        }
        .fixedSize(horizontal: false, vertical: true)
        .tvFocusSection()
    }

    /// The next race's C-R card, when the front page has it: its details (Remind me, Record).
    private func open(_ next: SportEventsPage.Next?) {
        guard let next else { return }
        let card = front.games.first { $0.league == page.league && ($0.title == next.name || $0.start == next.start) }
        SportCardActions.select(card: card, event: nil, app: app, presenter: presenter)
    }
}

/// Formula 1's session tiles and the circuit, in one row. #298: the tiles were a fixed width copied from the Apple TV, so
/// the row ran 40 pt past the television's page and, on an 11-inch iPad in landscape, made the page wider than the screen
/// (the banner and its back button went off the left). The tiles now give way, down to `tileMinWidth`, to fit the width
/// they are given; with less room than that, or on a narrow page (an iPad in portrait, the iPhone's league page), the
/// row keeps its full tiles and scrolls sideways.
struct F1TileRow: View {
    let tiles: [SportMotorText.Tile]
    let weekend: F1Weekend
    let client: APIClient
    /// A session with a channel: plays it while on, else opens its details.
    var select: (SportEvent) -> Void = { _ in }
    @Environment(\.sportNarrow) private var narrow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if narrow {
            scrolling
        } else {
            ViewThatFits(in: .horizontal) {
                row(fill: true).tvFocusSection()
                scrolling
            }
        }
    }

    private var scrolling: some View {
        ScrollView(.horizontal) { row(fill: false) }.scrollIndicators(.hidden).scrollClipDisabled()
    }

    private func row(fill: Bool) -> some View {
        HStack(alignment: .top, spacing: SportMotorMetrics.tileSpacing) {
            ForEach(tiles) { tile in sessionTile(tile, fill: fill) }
            circuit
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionTile(_ tile: SportMotorText.Tile, fill: Bool) -> some View {
        let session = weekend.sessions.first { $0.id == tile.id }
        let event = session.map { F1PageText.event($0, in: weekend) }
        return Button {
            guard let event, event.best != nil else { return }
            select(event)
        } label: {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(spacing: PigSpacing.s) {
                    Text(tile.title).font(SportPageMetrics.tileTitle).lineLimit(1)
                    Spacer(minLength: 4)
                    if tile.state == .live {
                        Text(tile.liveWord).font(SportPageMetrics.kicker).foregroundStyle(Color.pigOnAccent)
                            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs).background(Color.pigDanger, in: Capsule())
                    } else if tile.state == .next {
                        Text("NEXT").font(SportPageMetrics.kicker).foregroundStyle(Color.pigAccentText)
                            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                            .overlay(Capsule().strokeBorder(Color.pigAccent, lineWidth: 2))
                    }
                }
                Text(F1PageText.when(tile.when)).font(SportPageMetrics.tileDetail).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let line = tile.line {
                    Text(line).font(SportPageMetrics.tileDetail.weight(.bold))
                        .foregroundStyle(tile.state == .live ? Color.pigDanger : Color.primary).lineLimit(1)
                }
                if let best = event?.best {
                    Text(best.name).font(SportPageMetrics.tileDetail).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(SportPageMetrics.padding)
            .frame(minWidth: fill ? SportMotorMetrics.tileMinWidth : SportMotorMetrics.tileWidth,
                   idealWidth: fill ? SportMotorMetrics.tileMinWidth : SportMotorMetrics.tileWidth,
                   maxWidth: SportMotorMetrics.tileWidth, alignment: .topLeading)
            .frame(minHeight: SportPageMetrics.tileHeight, alignment: .topLeading)
            .overlay {
                if tile.state == .live {
                    RoundedRectangle(cornerRadius: SportPageMetrics.radius, style: .continuous)
                        .strokeBorder(Color.pigDanger.opacity(0.8), lineWidth: 2)
                }
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportPageMetrics.radius))
        .accessibilityIdentifier("f1.session.\(tile.id)")
    }

    private var circuit: some View {
        let path = scheme == .dark ? (weekend.info?.mapDark ?? weekend.info?.map) : weekend.info?.map
        return HStack(alignment: .top, spacing: PigSpacing.m) {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                ForEach(Array(F1PageText.stats(weekend.info).enumerated()), id: \.offset) { _, stat in
                    HStack(spacing: PigSpacing.s) {
                        Text(stat.label).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(stat.value).font(SportPageMetrics.rowDetail.weight(.bold)).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            CircuitMap(path: path, client: client)
                .frame(width: SportMotorMetrics.map.width, height: SportMotorMetrics.map.height)
                .accessibilityLabel("\(weekend.circuit ?? weekend.name) circuit map")
        }
        .padding(SportPageMetrics.padding)
        .frame(width: SportMotorMetrics.circuitWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: SportPageMetrics.radius, style: .continuous))
        .accessibilityIdentifier("f1.circuit")
    }
}

/// The circuit map (a logo-cache path), decoded large enough for the card; nothing while it loads or when absent.
struct CircuitMap: View {
    let path: String?
    let client: APIClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "flag.checkered").font(.system(size: PigType.hero)).foregroundStyle(.tertiary) }
        }
        .task(id: path) {
            guard let path, let data = try? await client.artworkData(path) else { image = nil; return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 900,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}
