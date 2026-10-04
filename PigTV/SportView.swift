import SwiftUI
import Combine

// C-I (build 30): the Sport tab (Home · TV Guide · Sport · Recordings ·
// Settings) and the event card Home's "Sport now & next" shelf shares. Shown
// only when the server advertises `sportsEvents`. Data: `SportModel` (the
// next 72 hours since build 32, refreshed every 60 s while a Sport surface is visible);
// choices: the pure `SportRows`. Select on a live event plays its best
// channel with the event's channels as the zap list; on an upcoming event it
// opens the event page (Watch when it starts, Record, the channels). Long
// press (touch and hold on iOS) offers the channel picker.

enum SportMetrics {
    #if os(tvOS)
    static let cardWidth: CGFloat = 380
    static let cardPadding: CGFloat = 20
    static let cardSpacing: CGFloat = 30
    static let sectionSpacing: CGFloat = 30
    static let pagePadding: CGFloat = 0
    static let radius: CGFloat = 20
    static let logo = CGSize(width: 112, height: 63)
    static let rowLogo = CGSize(width: 136, height: 76)
    static let league: Font = .system(size: 18, weight: .bold)
    static let title: Font = .system(size: 24, weight: .semibold)
    static let detail: Font = .system(size: 19)
    static let sectionTitle: Font = .system(size: 26, weight: .bold)
    #else
    static let cardWidth: CGFloat = 264
    static let cardPadding: CGFloat = 14
    static let cardSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 24
    static let pagePadding: CGFloat = 20
    static let radius: CGFloat = 16
    static let logo = CGSize(width: 64, height: 36)
    static let rowLogo = CGSize(width: 72, height: 40)
    static let league: Font = .caption.bold()
    static let title: Font = .subheadline.weight(.semibold)
    static let detail: Font = .caption
    static let sectionTitle: Font = .title3.bold()
    #endif
}

// MARK: The tab

struct SportView: View {
    // Not observed: `AppModel` and `BrowseModel` publish dozens of
    // properties the Sport tab never draws. It observes the sport snapshot,
    // and the two small observers below (the pending-watch banner, each
    // shelf's logo revision) take what they need (audit R04).
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject var sport: SportModel
    /// The chosen league chip (nil: All).
    @State private var league: String?
    @FocusState private var chipFocus: String?

    var body: some View {
        let buckets = sport.buckets
        let leagues = sport.leagues
        // A league that no longer has events falls back to All.
        let chosen = league.flatMap { leagues.contains($0) ? $0 : nil }
        // Precomputed per league with the snapshot, not filtered per render.
        let shown = sport.rows(league: chosen)
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy: with 200+ events (most of them replays) only the
                // shelves near the screen are built.
                LazyVStack(alignment: .leading, spacing: SportMetrics.sectionSpacing) {
                    header
                    SportPendingBanner(app: app)
                    if !leagues.isEmpty {
                        chips(leagues, chosen: chosen)
                    }
                    shelf("On now", shown.live)
                    shelf("Starting soon", shown.soon)
                    shelf("Later today", shown.later)
                    // Build 32 (72 h): Tomorrow, then one section per day.
                    shelf("Tomorrow", shown.tomorrow)
                    ForEach(shown.days, id: \.day) { day in shelf(day.title, day.events) }
                    // Build 31 (Mark: "I don't mind replays … just should
                    // be its own section").
                    shelf("Replays", shown.replays)
                    if !sport.loaded {
                        ProgressView("Loading sport…").frame(maxWidth: .infinity).padding(.top, 60)
                    } else if buckets.isEmpty {
                        SportEmptyState(error: sport.error) { Task { await sport.load() } }
                    }
                }
                .padding(.horizontal, SportMetrics.pagePadding)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
            #if DEBUG
            // Fixture screenshots: PIGTV_UI_TEST_SPORT_SCROLL=<section title>.
            .task {
                guard let target = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SPORT_SCROLL"] else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(for: .seconds(1.5))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            #endif
            }
            .pigPageBackdrop()
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        // The event page and channel picker live here, not on each card:
        // a recycled lazy cell cannot dismiss an open page.
        .sportPages(app: app, browse: browse, clock: sport.clock)
        .whileVisible { await sport.keepFresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PigBrandMark(width: 58, height: 48)
                .accessibilityHidden(true)
            Text("Sport").font(GuideTypography.title)
            Text(sport.clock, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(GuideTypography.body).foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// All + one chip per league (most events first), the guide's chips.
    private func chips(_ leagues: [String], chosen: String?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                let allCount = sport.leagueCounts.values.reduce(0, +)
                chip("All", count: allCount, selected: chosen == nil) { league = nil }
                    .focused($chipFocus, equals: "All")
                ForEach(leagues, id: \.self) { name in
                    let count = sport.leagueCounts[name] ?? 0
                    chip(name, count: count, selected: chosen == name) { league = name }
                        .focused($chipFocus, equals: name)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .tvFocusSection()
        // Down from the tab bar lands on the current chip, not the one
        // that happens to sit under the Sport tab.
        .defaultFocus($chipFocus, chosen ?? "All", priority: .userInitiated)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Text(verbatim: String(count)).foregroundStyle(.secondary).monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GuideFilterStyle(selected: selected))
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "event" : "events")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sport.league.\(title)")
    }

    @ViewBuilder
    private func shelf(_ title: String, _ events: [SportEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(SportMetrics.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                SportShelf(events: events, browse: browse, clock: sport.clock)
            }
            .tvFocusSection()
            .id(title)
        }
    }
}

/// A horizontal row of event cards (the Sport tab's sections and Home's
/// "Sport now & next"), optionally ending with a "See all" card. Lazy: the
/// Replays shelf alone holds 150+ cards on a production feed, and only the
/// few on screen need building.
struct SportShelf: View {
    let events: [SportEvent]
    /// Not observed: cards read it for logos only, and `logos` says when
    /// those may have changed.
    let browse: BrowseModel
    let clock: Date
    var seeAll: (() -> Void)? = nil
    @ObservedObject private var logos: SportLogoRevision
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.channelWarmer) private var warmer
    @FocusState private var focused: String?
    @State private var warmOwner = UUID().uuidString

    init(events: [SportEvent], browse: BrowseModel, clock: Date, seeAll: (() -> Void)? = nil) {
        self.events = events
        self.browse = browse
        self.clock = clock
        self.seeAll = seeAll
        _logos = ObservedObject(wrappedValue: browse.sportLogos)
    }

    var body: some View {
        // Whole minutes, as the rows are bucketed: cards whose input is
        // unchanged skip their body.
        let minute = SportRows.minute(clock)
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SportMetrics.cardSpacing) {
                ForEach(events) { event in
                    SportEventTile(input: SportCardInput(event: event, clock: minute, logoRevision: logos.value),
                                   browse: browse, presenter: presenter)
                        .equatable()
                        .focused($focused, equals: event.id)
                }
                if let seeAll {
                    SportSeeAllCard(count: events.count, action: seeAll)
                }
            }
            // Every card as tall as the tallest (the See all card stretches).
            .fixedSize(horizontal: false, vertical: true)
            // Room for the focus lift and its shadow.
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        // Entering a shelf (Down from the chips or the shelf above) lands
        // on its first event: live first, soonest first.
        .tvFocusSection()
        .defaultFocus($focused, events.first?.id, priority: .userInitiated)
        // R11: a focused live event warms its best channel (after the dwell).
        .onChange(of: focused) { _, id in
            warmer?.setBrowseTarget(SportWarming.target(eventID: id, in: events, now: clock), owner: warmOwner)
        }
        .onDisappear { warmer?.setBrowseTarget(nil, owner: warmOwner) }
    }
}

/// R11: which channel a focused Sport card should warm.
enum SportWarming {
    /// The best channel of the focused event, only for an event that is on
    /// now (a replay, an upcoming event or no focus warms nothing).
    nonisolated static func target(eventID: String?, in events: [SportEvent], now: Date) -> WarmTarget? {
        guard let eventID, let event = events.first(where: { $0.id == eventID }),
              !event.isReplay, event.isLive(at: now), let best = event.best else { return nil }
        return WarmTarget(sourceId: best.sourceId, channelId: best.rawID, identityKey: best.identityKey)
    }
}

// MARK: Card and its pages

/// The pending-watch banner, observing `AppModel` on its own so the rest of
/// the Sport tab does not re-evaluate whenever the app model publishes.
private struct SportPendingBanner: View {
    @ObservedObject var app: AppModel
    var body: some View {
        if let pending = app.pendingWatch {
            PendingWatchBanner(pending: pending) { app.cancelPendingWatch() }
        }
    }
}

/// "Fox Footy at 8:30 pm" with Cancel, while a watch is waiting.
struct PendingWatchBanner: View {
    let pending: PendingWatch
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "alarm.fill").foregroundStyle(Color.pigAccentText)
            Text("Watching \(pending.channelName) at \(pending.at.formatted(date: .omitted, time: .shortened)): \(pending.title)")
                .font(GuideTypography.body).lineLimit(1)
            Spacer(minLength: 12)
            Button("Cancel", systemImage: "xmark", action: cancel)
                #if os(tvOS)
                .font(GuideTypography.body)
                #else
                .buttonStyle(.bordered)
                #endif
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: SportMetrics.radius, style: .continuous))
        .tvFocusSection()
    }
}

/// No events: how to follow sports (web app → Settings → Sports).
private struct SportEmptyState: View {
    let error: String?
    let retry: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sportscourt").font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text(error == nil ? "No sport in the next three days" : "Sport is unavailable right now")
                .font(DetailType.title).multilineTextAlignment(.center)
            Text(error ?? "Choose the sports, leagues and teams you follow in the PigTV web app, under Settings → Sports. Their events on your channels appear here and on Home, live ones first.")
                .font(DetailType.meta).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            if error != nil {
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .pigPrimaryButton()
            }
        }
        .padding(.vertical, 70).padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .tvFocusSection()
        .background(Color.guideCell(scheme).opacity(0.7), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
    }
}
