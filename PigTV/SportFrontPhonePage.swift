import SwiftUI
import Combine

// D-44 (R5-Front-iPhone, Apple 139): the iPhone Sport front page. The header (the pig, "Sport", and whether scores
// show); a carousel (each card at least 212 pt, as tall as its content) of the follows, one card each in the order sent, swiped sideways with its dots and "1 of 10
// follows" (Watch or Remind me, and Record every game, on the card); then one card per sport under its "Football ›"
// header, which opens the sport's page, each game a fixture row (`SportFixtureRow`). Pressing a row plays it while its
// channel airs it, else opens its details; a long press offers its RECORD section. The words come from
// `SportPhoneLayout`, spoiler-free already applied. The iPad uses the Apple TV page (`SportFrontTVPage`).

#if os(iOS)
enum SportPhoneMetrics {
    static let cardWidth: CGFloat = 330
    /// #280 (Mark, 10 Nov): the follow card's height in the design, now its minimum: a card grows with its content (two-line
    /// names on both sides, larger text) and every card in the row is as tall as the tallest. A fixed 212 pt pushed
    /// Remind me and Record below the card.
    static let cardMinHeight: CGFloat = 212
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// #264: whether the page has scrolled past the carousel (its height below): past it, the hero shows as the strip.
    /// #352: held by reference and observed only by the strip and the page's mask, so the hand-over never re-draws the page.
    @State private var past = SportPhoneStripPast()
    @State private var carouselHeight: CGFloat = 0

    init(app: AppModel, browse: BrowseModel, open: @escaping (String) -> Void) {
        self.app = app
        self.browse = browse
        self.open = open
        _model = ObservedObject(wrappedValue: browse.sportFront)
        _f1 = ObservedObject(wrappedValue: browse.f1Page)
    }

    private var hidden: Bool { SportSpoilers.hidden(preference: f1.hidesSpoilers, answer: model.front?.spoilerFree, page: false) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .whileVisible { await model.keepFresh(preferences: f1) }
        // #342: the splash lands on this page once its first answer (or error) is in, not on its placeholders.
        .splashPageReady("Sport", when: model.state != .loading)
        .task { await model.loadLabels(enabled: browse.sportFollowsEnabled) }
        .onChange(of: f1.hidesSpoilers) { Task { await model.load() } }
        .sportRecordFlow(flow, app: app)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // #263: the header stays put above the page, as the TV Guide's does; before, it scrolled away with the cards.
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            header
            // #264: once the hero has scrolled under, it shows as the strip, pinned over the page's top (#352: see
            // SportPhoneStripLayer; while it shows nothing of the page is drawn in its room, as on the Apple TV and iPad).
            ScrollViewReader { reader in
                // The strip's words are worked out here, with the page, never at the hand-over.
                let words = model.front.flatMap { $0.isEmpty ? nil : strip($0, now: now) }
                ZStack(alignment: .top) {
                    page(now: now, hasStrip: words != nil)
                        .mask(alignment: .top) { SportPhoneStripMask(past: past, hasStrip: words != nil) }
                    SportPhoneStripLayer(past: past, words: words) { words, shows in
                        SportHeroStripView(strip: words, onTap: {
                            pigWithAnimation(moves: true, momentum: true, reduceMotion: reduceMotion) { reader.scrollTo(Self.carouselID, anchor: .top) }
                        }, hidden: !shows)
                        .padding(.horizontal, SportPhoneMetrics.edge)
                    }
                }
            }
        }
    }

    static let carouselID = "sport.front.carousel"


    /// #264: the hero's words, slim (the carousel's first card is the hero's follow).
    private func strip(_ front: SportFront, now: Date) -> SportHeroStrip {
        let words = model.heroGame.map { SportFrontLayout.hero($0, in: front, hidden: hidden, now: now, labels: model.labels) }
            ?? SportBannerHero(kicker: "YOUR SPORTS", live: false, title: "Nothing on right now",
                               line: "The next games you follow are below.")
        return SportHeroStrip(hero: words, items: SportFrontLayout.followItems(front, now: now), selected: model.heroFollowIndex)
    }

    private func page(now: Date, hasStrip: Bool) -> some View {
        ScrollView(.vertical) {
            // #280: the four states (PageState), as on the Apple TV and iPad (SportFrontTVPage.page).
            VStack(alignment: .leading, spacing: PigSpacing.m) {
                switch model.state {
                case .loading:
                    SportFrontPhonePlaceholder()
                case .failed(let failure):
                    PigErrorState(failure: failure, retry: { await model.load() }, identifier: "sport.front.error", schedule: model.schedule)
                        .pigStateFillsPage()
                case .empty, .emptyStale:
                    // An empty answer whose refresh failed keeps E1 under the slim notice (it may be out of date); the
                    // scores feed's own note shows above it, as above the content.
                    if model.state.isStale {
                        PigStaleNotice(since: model.state.staleSince, retry: { await model.load() }, identifier: "sport.front.stale")
                            .padding(.horizontal, SportPhoneMetrics.edge)
                    }
                    if model.front?.scoresUnavailable == true {
                        Label(SportFrontText.scoresUnavailable, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, SportPhoneMetrics.edge)
                            .accessibilityIdentifier("sport.front.scoresUnavailable")
                    }
                    SportFollowEmpty(app: app, settings: browse.sportFollowsEnabled).pigStateFillsPage()
                case .content, .stale:
                    if let front = model.front {
                        if case .stale(let since) = model.state {
                            PigStaleNotice(since: since, retry: { await model.load() }, identifier: "sport.front.stale")
                                .padding(.horizontal, SportPhoneMetrics.edge)
                        }
                        if front.scoresUnavailable {
                            Label(SportFrontText.scoresUnavailable, systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, SportPhoneMetrics.edge)
                                .accessibilityIdentifier("sport.front.scoresUnavailable")
                        }
                        carousel(front, now: now)
                            .id(Self.carouselID)
                            .modifier(SportBandGuard())
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { carouselHeight = $0 }
                        ForEach(SportPhoneLayout.groups(front, hidden: hidden, now: now, labels: model.labels)) { group in
                            groupView(group, front: front, now: now)
                        }
                        also(front, now: now)
                    }
                }
            }
            .padding(.bottom, PigSpacing.section)
            .pigScrollProbe()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sport.front")
            .environment(\.sportStripBand, hasStrip ? past : nil)
        }
        .coordinateSpace(name: SportBandGuardRule.space)
        .onScrollPast({ [carouselHeight] in
            SportHeroStrip.shows(scrolled: $0, bannerHeight: carouselHeight, stripHeight: SportHeroStripMetrics.height)
        }, action: { [past] in past.value = $0 })
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
                // #298: the sport, then its note on the same line; when they do not fit (the larger text sizes), the
                // note goes under the sport, so the sport's name has the line to itself and breaks only between words
                // (at the largest sizes it broke inside them: "Aus-/tralia/n/foot-/ball").
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                        sectionTitle(group.sport)
                        Spacer(minLength: 8)
                        Text(group.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                        // Past accessibility 2 a word as long as "Australian" is wider than an iPhone: the title stops
                        // growing there, so it breaks between words only.
                        sectionTitle(group.sport).dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        Text(group.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, PigSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .pigPressable()
            .accessibilityLabel("\(group.sport), \(group.note), open its page")
            .accessibilityIdentifier("sport.rail.header.\(group.sport)")
            .modifier(SportBandGuard())
            SportPhoneRowsCard(app: app, browse: browse, flow: flow, front: front, rows: group.rows, identifier: "sport.front.game")
        }
        .padding(.horizontal, SportPhoneMetrics.edge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.front.group.\(group.sport)")
    }

    /// "Football ›".
    private func sectionTitle(_ sport: String) -> some View {
        (Text(sport) + Text(" ›").foregroundStyle(.secondary)).font(.title3.weight(.heavy))
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
                            .pigPressable()
                            .accessibilityIdentifier("sport.also.\(sport)")
                            .modifier(SportBandGuard())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, SportPhoneMetrics.edge)
        }
    }
}

/// #352: whether the iPhone page has scrolled past its carousel. A reference the page holds without observing it: only
/// the strip and the mask below observe it, so the hand-over re-draws those two, never the page under the finger.
@MainActor final class SportPhoneStripPast: ObservableObject {
    var value = false {
        willSet { if newValue != value { objectWillChange.send() } }
    }
}

/// #264: the strip, over the page's top, while the page is past the carousel and there is a hero to show.
/// #352 (Mark, 18 Nov 2026, the page jolted on the iPhone as the hero became the strip): two causes, both at the hand-over.
/// The strip took its own room above the ScrollView, which moved down by that room the moment it showed (52 pt against
/// the finger); it is now drawn over the page, whose frame never changes. And the hand-over stalled the main thread (the
/// page's whole body re-drawn, the strip's words worked out and the strip built from nothing: 0.05–0.4 s on the
/// simulator): a stall in the middle of a drag swallows its last moves, the scroll view reads the catch-up as a flick
/// and carries the page on (~135 pt, about a third of the runs). Now the page is not re-drawn (`SportPhoneStripPast`),
/// the words come with the page, and the strip is built with the page and only slides and fades in.
private struct SportPhoneStripLayer<Strip: View>: View {
    @ObservedObject var past: SportPhoneStripPast
    /// The hero's words (none without a hero).
    let words: SportHeroStrip?
    /// The strip for the words, and whether it shows.
    @ViewBuilder let strip: (SportHeroStrip, Bool) -> Strip

    var body: some View {
        if let words {
            let shows = past.value
            strip(words, shows)
                .offset(y: shows ? 0 : -SportHeroStripMetrics.room)
                .opacity(shows ? 1 : 0)
                .allowsHitTesting(shows)
                .accessibilityHidden(!shows)
                .pigAnimation(value: shows, moves: true)
        }
    }
}

/// #352 (Codex's open medium): while the strip shows, the band under it (its room at the page's top, where the mask
/// draws nothing of the page) passes no tap and no VoiceOver focus to the rows beneath. Nothing is laid over the band (a
/// hit-absorbing shield there made a scroll dead zone, as a drag starting on it never reached the scroll view): a row
/// partly under the band takes no tap until it has scrolled out of it, and a row wholly under it is hidden from
/// accessibility. A drag starting on the band still starts inside the scroll view, so it scrolls.
private struct SportBandKey: EnvironmentKey {
    static let defaultValue: SportPhoneStripPast? = nil
}

extension EnvironmentValues {
    /// The iPhone front page's strip state while it has a strip; nil elsewhere (no band to guard).
    var sportStripBand: SportPhoneStripPast? {
        get { self[SportBandKey.self] }
        set { self[SportBandKey.self] = newValue }
    }
}

/// A row on the iPhone front page: its part under the strip's band takes no tap, and wholly under it, no VoiceOver focus.
struct SportBandGuard: ViewModifier {
    @Environment(\.sportStripBand) private var band

    func body(content: Content) -> some View {
        if let band { content.modifier(SportBandGuardActive(past: band)) } else { content }
    }
}

private struct SportBandGuardActive: ViewModifier {
    @ObservedObject var past: SportPhoneStripPast
    /// How much of the row's top is under the band now (points, whole), and its height.
    @State private var hiddenTop: CGFloat = 0
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let hidden = past.value ? hiddenTop : 0
        content
            // A row any part of which is under the band takes no tap (its hidden part would take it: a contentShape cut
            // to the visible part narrowed only its accessibility frame, not the button's own touch area). Touches then
            // fall through to the scroll view, so a drag starting there still scrolls.
            .allowsHitTesting(hidden == 0)
            .accessibilityHidden(past.value && height > 0 && hidden >= height - 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SportBandGuardRule.space)) } action: { frame in
                let covered = SportBandGuardRule.hiddenTop(rowTop: frame.minY, rowHeight: frame.height)
                if abs(covered - hiddenTop) >= 1 || (covered == 0) != (hiddenTop == 0) { hiddenTop = covered }
                if abs(frame.height - height) >= 1 { height = frame.height }
            }
    }
}

/// The band's rule (pure, `SportBandGuardTests`).
enum SportBandGuardRule {
    /// The page's ScrollView (its visible frame); a row inside a sideways scroll is still measured against it.
    static let space = "sport.front.page"
    /// How much of a row (its top and height in the scroll view's visible frame) is under the strip's band.
    static func hiddenTop(rowTop: CGFloat, rowHeight: CGFloat) -> CGFloat {
        min(max(0, SportHeroStripMetrics.room - rowTop), max(0, rowHeight)).rounded(.up)
    }
}

/// #352: while the strip shows nothing of the page is drawn in its room (the rows scroll beneath it, as on the Apple TV
/// and iPad, #312); the mask is the only part of the page that changes at the hand-over, and it changes no layout.
private struct SportPhoneStripMask: View {
    @ObservedObject var past: SportPhoneStripPast
    let hasStrip: Bool

    var body: some View {
        SportPageTopMask(top: past.value && hasStrip ? SportHeroStripMetrics.room : 0, fade: false)
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
                    // #280: 11 pt letters (they were 9): the badge widens to hold them rather than cut them off.
                    Text(row.badge ?? "").font(.system(size: PigType.micro, weight: .heavy)).foregroundStyle(Color.pigOnStatus)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, PigSpacing.xxs)
                        .frame(minWidth: SportPhoneMetrics.rowBadge, minHeight: SportPhoneMetrics.rowBadge)
                        .background(Color(SportFrontText.leagueColorName(row.league)),
                                    in: RoundedRectangle(cornerRadius: PigRadius.inner, style: .continuous))
                        .accessibilityHidden(true)
                    Text(row.title).font(.subheadline.weight(.bold)).lineLimit(1)
                }
                Spacer(minLength: 10)
                if let score = row.shortScore ?? row.score {
                    Text(score).font(.system(.subheadline, design: .rounded).weight(.heavy)).pigFigures().lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: PigSpacing.s) {
                if let live = row.live {
                    Text("● \(live)").font(.caption.weight(.bold)).foregroundStyle(Color.pigDanger).pigFigures()
                        .fixedSize()
                    if !row.sub.isEmpty { Text("·") }
                }
                Text(row.sub).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary).pigFigures()
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

#endif
