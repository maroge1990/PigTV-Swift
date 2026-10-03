import SwiftUI

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
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    @ObservedObject var sport: SportModel
    /// The chosen league chip (nil: All).
    @State private var league: String?
    @FocusState private var chipFocus: String?

    var body: some View {
        let buckets = sport.buckets
        let leagues = sport.leagues
        // A league that no longer has events falls back to All.
        let chosen = league.flatMap { leagues.contains($0) ? $0 : nil }
        let shown = SportRows.filter(buckets, league: chosen)
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SportMetrics.sectionSpacing) {
                    header
                    if let pending = app.pendingWatch {
                        PendingWatchBanner(pending: pending) { app.cancelPendingWatch() }
                    }
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
        .task { await sport.keepFresh() }
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
                SportShelf(events: events, app: app, browse: browse, clock: sport.clock)
            }
            .tvFocusSection()
            .id(title)
        }
    }
}

/// A horizontal row of event cards (the Sport tab's sections and Home's
/// "Sport now & next"), optionally ending with a "See all" card. Not lazy:
/// at most a few dozen cards, and every card keeps its own pages.
struct SportShelf: View {
    let events: [SportEvent]
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    let clock: Date
    var seeAll: (() -> Void)? = nil
    @FocusState private var focused: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: SportMetrics.cardSpacing) {
                ForEach(events) { event in
                    SportEventTile(event: event, app: app, browse: browse, clock: clock)
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
    }
}

// MARK: Card and its pages

/// An event card with its behaviour: Select plays (live) or opens the event
/// page (upcoming); long press offers the channel picker and the page.
struct SportEventTile: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    let clock: Date
    @State private var page: SportPage?
    /// Run once the page has closed (the player cannot present over it).
    @State private var afterDismiss: (() -> Void)?

    enum SportPage: String, Identifiable {
        case details, channels
        var id: String { rawValue }
    }

    var body: some View {
        let live = event.isLive(at: clock)
        SportEventCard(event: event, browse: browse, clock: clock) {
            if live { app.playSportEvent(event) } else { page = .details }
        }
        .contextMenu {
            if event.channels.count > 1 {
                Button("Choose a channel", systemImage: "list.bullet") { page = .channels }
            }
            if live {
                Button("Watch on \(event.best?.name ?? "the best channel")", systemImage: "play.fill") { app.playSportEvent(event) }
            }
            Button("Event details", systemImage: "info.circle") { page = .details }
        }
        .detailCover(item: $page, onDismiss: {
            let action = afterDismiss
            afterDismiss = nil
            action?()
        }) { page in
            switch page {
            case .details:
                SportEventDetails(event: event, app: app, browse: browse, play: close(then:))
            case .channels:
                SportChannelPicker(event: event, app: app, browse: browse, clock: clock, play: close(then:))
            }
        }
    }

    private func close(then action: @escaping () -> Void) {
        afterDismiss = action
        page = nil
    }
}

/// The card: league, title, time (and progress when live), the best
/// channel's logo and how many more channels show it; LIVE when on now.
struct SportEventCard: View {
    let event: SportEvent
    let browse: BrowseModel
    let clock: Date
    let action: () -> Void

    var body: some View {
        let live = event.isLive(at: clock)
        let timing = SportRows.timing(event, now: clock)
        let replay = event.isReplay
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text(event.league.uppercased()).font(SportMetrics.league).tracking(2)
                        .foregroundStyle(Color.pigAccentText).lineLimit(1)
                    Spacer(minLength: 8)
                    // Kept (invisible) on upcoming cards so every title
                    // starts at the same height.
                    // A replay says so instead (build 31).
                    if replay {
                        CardBadge(text: "REPLAY", systemImage: "arrow.counterclockwise", colour: Color(white: 0.4))
                            .accessibilityHidden(true)
                    } else {
                        CardBadge(text: "LIVE", colour: .red).opacity(live ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                Text(event.title).font(SportMetrics.title)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(timing).font(SportMetrics.detail).foregroundStyle(live ? Color.primary : Color.secondary)
                    .monospacedDigit().lineLimit(1)
                // The bar keeps its space on upcoming cards so rows line up.
                PigProgressBar(fraction: SportRows.progress(event, now: clock))
                    .opacity(live ? 1 : 0)
                if let best = event.best {
                    HStack(spacing: 14) {
                        ChannelLogoTile(logo: browse.logo(for: best), client: browse.client, name: best.name,
                                        size: SportMetrics.logo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(best.name).font(SportMetrics.detail.weight(.semibold)).lineLimit(1)
                            Text(SportRows.moreChannels(event) ?? " ")
                                .font(SportMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(SportMetrics.cardPadding)
            .frame(width: SportMetrics.cardWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel([event.league, event.title, replay ? "replay" : (live ? "live" : nil), timing,
                             event.best.map { "on \($0.name)" }, SportRows.moreChannels(event)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("sport.event.\(event.id)")
    }
}

/// Home's trailing card: switches to the Sport tab.
struct SportSeeAllCard: View {
    let count: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "sportscourt.fill").font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.pigAccentText)
                Text("See all sport").font(SportMetrics.title)
                Text("Every event, by league").font(SportMetrics.detail).foregroundStyle(.secondary)
            }
            .padding(SportMetrics.cardPadding)
            .frame(width: SportMetrics.cardWidth * 0.62)
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel("See all sport")
        .accessibilityIdentifier("home.sport.seeAll")
    }
}

/// "UHD" / "HD" / "SD": UHD in pink, the others outlined.
struct QualityBadge: View {
    let quality: SportQuality
    var body: some View {
        Text(quality.rawValue)
            .font(SportMetrics.detail.weight(.bold)).monospaced()
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(quality == .uhd ? Color.white : Color.secondary)
            .background(quality == .uhd ? Color.pigAccent : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(quality == .uhd ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5) }
            .accessibilityLabel(quality == .uhd ? "Ultra HD" : quality == .hd ? "HD" : "Standard definition")
    }
}

/// One of an event's channels: logo, name (and number), quality. A live (or
/// about-to-start) event plays on select; an upcoming one on another channel
/// offers a choice (Record / Watch when it starts) instead of tuning at
/// once (build 33: Mark, live testing — a secondary channel used to tune
/// straight away on an upcoming event). The icon and accessibility label
/// say which: play, an already-scheduled recording, or the choice.
struct SportChannelRow: View {
    let channel: SportEventChannel
    let browse: BrowseModel
    var isBest = false
    var playsNow = true
    var scheduled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                ChannelLogoTile(logo: browse.logo(for: channel), client: browse.client, name: channel.name,
                                size: SportMetrics.rowLogo)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(channel.name).font(DetailType.rowTitle).lineLimit(1)
                        if browse.showsChannelNumbers, let number = channel.number {
                            ChannelNumberText(number: String(number), font: DetailType.rowDetail)
                        }
                    }
                    if isBest {
                        Text("Recommended").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                    if scheduled {
                        Text("Recording scheduled").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if let quality = channel.quality { QualityBadge(quality: quality) }
                Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, 24).padding(.vertical, 16)
            #else
            .padding(.horizontal, 14).padding(.vertical, 10)
            #endif
            .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 16))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sport.channel.\(channel.id)")
    }

    private var icon: String {
        if playsNow { return "play.fill" }
        return scheduled ? "record.circle" : "alarm"
    }

    private var accessibilityLabel: String {
        let text = playsNow ? "Watch on \(channel.name)"
            : scheduled ? "Recording scheduled on \(channel.name)" : "Record or watch \(channel.name) when it starts"
        return text + (channel.quality.map { ", \($0.rawValue)" } ?? "")
    }
}

/// The channel picker (long press → Choose a channel). Behaves like the
/// event page's channel list (`SportChannelList`): the same rule decides
/// whether a row plays or offers a choice.
struct SportChannelPicker: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    let clock: Date
    /// Closes the picker, then runs the action (playback or a wait).
    let play: (@escaping () -> Void) -> Void

    var body: some View {
        DetailPage(title: "Choose a channel") {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: event.league)
                Text(event.title).font(DetailType.channel)
                Text(SportRows.timing(event, now: clock)).font(DetailType.meta).foregroundStyle(.secondary)
            }
            SportChannelList(event: event, app: app, browse: browse, clock: clock, play: play)
        }
    }
}

/// One event's channels, each row deciding for itself (build 33): live, or
/// starting within `SportRows.watchNowWindow`, plays on select; otherwise
/// select opens a choice — Record on that channel (unless already
/// scheduled), or Watch it when it starts — via `confirmationDialog`, not
/// another full-screen cover (tvOS focus: stacked covers can strand focus;
/// Record still needs one, same as the event page's own Record button).
/// Shared by the event page (`SportEventDetails`) and the long-press
/// channel picker (`SportChannelPicker`).
struct SportChannelList: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    let clock: Date
    /// Closes the covering page, then runs the action (playback or a wait).
    let play: (@escaping () -> Void) -> Void
    @State private var choosing: SportEventChannel?
    @State private var recording: SportEventChannel?

    var body: some View {
        let playsNow = SportRows.playsChannelNow(event, now: clock)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(event.channels.enumerated()), id: \.element.id) { index, channel in
                let scheduled = !playsNow && browse.isScheduled(event, on: channel)
                SportChannelRow(channel: channel, browse: browse, isBest: index == 0 && event.channels.count > 1,
                                 playsNow: playsNow, scheduled: scheduled) {
                    if playsNow { play { app.playSportEvent(event, channel: channel) } }
                    else { choosing = channel }
                }
            }
        }
        .tvFocusSection()
        .confirmationDialog(choosing?.name ?? "", isPresented: Binding(
            get: { choosing != nil }, set: { if !$0 { choosing = nil } }
        ), titleVisibility: .visible, presenting: choosing) { channel in
            if !browse.isScheduled(event, on: channel) {
                Button("Record on \(channel.name)", systemImage: "record.circle") {
                    choosing = nil
                    recording = channel
                }
            }
            Button("Watch \(channel.name) when it starts", systemImage: "alarm") {
                choosing = nil
                play { app.watchWhenStarts(event, channel: channel, now: clock) }
            }
            Button("Cancel", role: .cancel) { choosing = nil }
        } message: { _ in
            Text(SportRows.timing(event, now: clock))
        }
        .detailCover(item: $recording) { channel in
            RecordSheet(model: browse, channel: browse.recordingRow(event, on: channel), programme: event.programme) { _ in
                recording = nil
            }
        }
    }
}

/// An upcoming event's page: Watch <channel> when it starts (plays at once
/// within five minutes), Record on the best channel, and every channel.
struct SportEventDetails: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    /// Closes the page, then runs the action (playback).
    let play: (@escaping () -> Void) -> Void
    @State private var recordSheet = false
    private enum Control: Hashable { case watch }
    @FocusState private var focus: Control?

    var body: some View {
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                content(now: now)
            }
        }
        .onAppear { browse.actionError = nil; browse.actionMessage = nil }
        .detailCover(isPresented: $recordSheet) {
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme) { _ in
                    recordSheet = false
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let live = event.isLive(at: now)
        let playsNow = SportRows.playsChannelNow(event, now: now)
        let pending = app.pendingWatch?.eventID == event.id
        let best = event.best
        VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
            DetailHero(logo: best.flatMap { browse.logo(for: $0) }, client: browse.client) {
                HStack(alignment: .top) {
                    Eyebrow(text: "\(event.league) · \(live ? "Live" : DetailText.day(event.start, now: now))")
                    Spacer(minLength: 20)
                    if live { StatusBadge(text: "LIVE", colour: .red) }
                    else if let best, browse.isScheduled(event, on: best) {
                        StatusBadge(text: "Recording scheduled", systemImage: "record.circle")
                    }
                }
                Text(event.title).font(DetailType.title).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.programme.timeRange) · \(live ? SportRows.endsIn(event, now: now) : SportRows.startsIn(event, now: now))")
                    .font(DetailType.meta).foregroundStyle(.secondary).monospacedDigit()
                if live {
                    PigProgressBar(fraction: SportRows.progress(event, now: now), height: 6).frame(maxWidth: 640)
                }
            }
            if let best {
                DetailActions {
                    if pending {
                        Button("Don't watch at \(event.start.formatted(date: .omitted, time: .shortened))",
                               systemImage: "xmark") { app.cancelPendingWatch() }
                            .focused($focus, equals: .watch)
                    } else if playsNow {
                        Button("Watch \(best.name)", systemImage: "play.fill") {
                            play { app.playSportEvent(event) }
                        }
                        .pigPrimaryButton()
                        .focused($focus, equals: .watch)
                        .accessibilityIdentifier("sport.watch")
                    } else {
                        // Closes the page (the wait shows as a banner on
                        // the Sport tab and Home), so nothing is covering
                        // the player when the event starts.
                        Button("Watch \(best.name) when it starts", systemImage: "alarm") {
                            play { app.watchWhenStarts(event, now: now) }
                        }
                        .pigPrimaryButton()
                        .focused($focus, equals: .watch)
                        .accessibilityIdentifier("sport.watch")
                    }
                    if event.end > now && !browse.isScheduled(event, on: best) {
                        Button("Record", systemImage: "record.circle") { recordSheet = true }
                            .disabled(browse.mutationBusy)
                            .accessibilityIdentifier("sport.record")
                    }
                }
                .defaultFocus($focus, .watch)
                if pending {
                    Text("PigTV will start \(best.name) at \(event.start.formatted(date: .omitted, time: .shortened)) while the app stays open.")
                        .font(DetailType.meta).foregroundStyle(.secondary)
                }
            }
            PigSectionHeader(title: event.channels.count == 1 ? "Channel" : "Channels")
            SportChannelList(event: event, app: app, browse: browse, clock: now, play: play)
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
