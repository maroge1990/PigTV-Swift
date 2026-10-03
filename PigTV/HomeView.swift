import SwiftUI

// Home (build 28): the first tab. A "Continue watching" hero for the last
// channel played, then shelves: Recently watched, Favourites on now, Starting
// soon on your favourites, Sport now & next (C-I, build 30) and Recordings. Everything is
// drawn from data the app already holds (the guide, favourites, recordings)
// plus `library/recent`; the row choices are the pure `HomeRows` functions.
// No live video here: the provider allows one stream and Home must never
// take it.

/// Everything Home draws, rebuilt on data changes and every minute rather
/// than on each render (the guide has ~18 000 channels).
private struct HomeContent: Equatable {
    var hero: HomeChannel?
    var recent: [HomeChannel] = []
    var favouritesOnNow: [HomeChannel] = []
    var startingSoon: [HomeSoonItem] = []
    /// C-I: live sport events, then those starting within the hour.
    var sport: [SportEvent] = []
    var recordings: [Recording] = []
    /// Recording id → its channel's logo (found by channel name in the guide).
    var recordingLogos: [Int: String] = [:]

    var isEmpty: Bool { hasNoHistory && sport.isEmpty }
    /// First run: nothing watched, no favourites, no recordings yet.
    var hasNoHistory: Bool {
        hero == nil && recent.isEmpty && favouritesOnNow.isEmpty && startingSoon.isEmpty && recordings.isEmpty
    }

    static func == (lhs: HomeContent, rhs: HomeContent) -> Bool {
        lhs.hero == rhs.hero && lhs.recent == rhs.recent && lhs.favouritesOnNow == rhs.favouritesOnNow
            && lhs.startingSoon == rhs.startingSoon && lhs.sport == rhs.sport
            && lhs.recordings.map(\.id) == rhs.recordings.map(\.id)
            && lhs.recordings.map(\.status) == rhs.recordings.map(\.status)
            && lhs.recordingLogos == rhs.recordingLogos
    }
}

// Build 31 (Mark: "a very long screen … continue watching takes up about
// 50% of the screen"): on the TV the hero is about a third of the screen
// (~340 pt of 1080) and the cards are smaller, so the hero and two full
// shelves fit on one 1080p screen. The page header (pig, "Home", date) is
// not drawn on the TV: the tab bar already says Home.
private enum HomeMetrics {
    #if os(tvOS)
    static let pagePadding: CGFloat = 0
    static let sectionSpacing: CGFloat = 22
    static let cardWidth: CGFloat = 260
    static let artHeight: CGFloat = 120
    static let cardSpacing: CGFloat = 30
    static let cardPadding: CGFloat = 12
    static let cardTextSpacing: CGFloat = 6
    /// Vertical room around a shelf's cards for the focus lift.
    static let shelfPadding: CGFloat = 14
    static let heroHeight: CGFloat = 320
    static let heroPadding = CGSize(width: 56, height: 26)
    static let heroSpacing: CGFloat = 6
    static let heroRadius: CGFloat = 32
    static let cardRadius: CGFloat = 18
    static let heroTitle: Font = .system(size: 40, weight: .bold)
    static let heroChannel: Font = .system(size: 22, weight: .semibold)
    static let heroDetail: Font = .system(size: 22, weight: .medium)
    static let eyebrow: Font = .system(size: 18, weight: .bold)
    static let sectionTitle: Font = .system(size: 26, weight: .bold)
    static let cardTitle: Font = .system(size: 22, weight: .semibold)
    static let cardDetail: Font = .system(size: 18)
    static let heroLogo = CGSize(width: 300, height: 170)
    static let heroLogoInset = CGSize(width: 28, height: 20)
    static let artInset = CGSize(width: 30, height: 18)
    static let welcomeTitle: Font = .system(size: 48, weight: .bold)
    #else
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let cardWidth: CGFloat = 200
    static let artHeight: CGFloat = 100
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 12
    static let cardTextSpacing: CGFloat = 5
    static let shelfPadding: CGFloat = 8
    static let heroHeight: CGFloat = 0
    static let heroPadding = CGSize(width: 20, height: 18)
    static let heroSpacing: CGFloat = 6
    static let heroRadius: CGFloat = 22
    static let cardRadius: CGFloat = 14
    static let heroTitle: Font = .title2.bold()
    static let heroChannel: Font = .subheadline.weight(.semibold)
    static let heroDetail: Font = .subheadline
    static let eyebrow: Font = .caption.bold()
    static let sectionTitle: Font = .headline
    static let cardTitle: Font = .subheadline.weight(.semibold)
    static let cardDetail: Font = .caption
    static let heroLogo = CGSize(width: 150, height: 84)
    static let heroLogoInset = CGSize(width: 14, height: 10)
    static let artInset = CGSize(width: 24, height: 14)
    static let welcomeTitle: Font = .title.bold()
    #endif
}

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: BrowseModel
    /// Switches to the TV Guide tab (first-run state).
    var openGuide: () -> Void = {}
    /// Switches to the Sport tab (Sport now & next → See all).
    var openSport: () -> Void = {}
    @State private var content = HomeContent()
    @State private var clock = Date()
    @State private var rebuild: Task<Void, Never>?
    @State private var details: HomeDetails?
    @State private var schedule: GuideChannel?
    @State private var playingRecording: Recording?
    @State private var recordingDetails: Recording?
    @State private var pendingWatch: Channel?
    @State private var pendingSchedule: GuideChannel?
    @Environment(\.colorScheme) private var scheme

    private struct HomeDetails: Identifiable {
        let channel: GuideChannel
        let programme: GuideProgramme
        var id: String { "\(channel.id)|\(programme.startTime)" }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                    #if os(iOS)
                    header
                    #endif
                    if let hero = content.hero {
                        HomeHero(channel: hero, model: model, clock: clock,
                                 watch: { play(hero, from: [hero]) },
                                 schedule: model.guideRow(id: hero.id, identityKey: hero.identityKey).map { row in { schedule = row } })
                    } else if content.hasNoHistory && !(model.guideBusy && model.guide.isEmpty) {
                        HomeWelcome(openGuide: openGuide)
                    }
                    if model.sportEnabled, let pending = app.pendingWatch {
                        PendingWatchBanner(pending: pending) { app.cancelPendingWatch() }
                    }
                    shelf("Recently watched", content.recent) { channel in
                        HomeChannelCard(channel: channel, model: model, clock: clock) { play(channel, from: content.recent) }
                    }
                    shelf("Favourites on now", content.favouritesOnNow) { channel in
                        HomeChannelCard(channel: channel, model: model, clock: clock) { play(channel, from: content.favouritesOnNow) }
                    }
                    shelf("Starting soon on your favourites", content.startingSoon) { item in
                        HomeSoonCard(item: item, model: model, clock: clock) { showDetails(item) }
                    }
                    if !content.sport.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sport now & next").font(HomeMetrics.sectionTitle)
                                .accessibilityAddTraits(.isHeader)
                            SportShelf(events: content.sport, browse: model, clock: clock, seeAll: openSport)
                        }
                        .tvFocusSection()
                        .id("Sport now & next")
                    }
                    shelf("Recordings", content.recordings) { recording in
                        HomeRecordingCard(recording: recording, logo: content.recordingLogos[recording.id], model: model) { open(recording) }
                    }
                    if model.guideBusy && model.guide.isEmpty && content.isEmpty {
                        ProgressView("Loading your channels…").frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, HomeMetrics.pagePadding)
                .padding(.bottom, 60)
                #if os(tvOS)
                // The tab bar is the page's title on the TV; a little air
                // between it and the hero.
                .padding(.top, 2)
                #endif
            }
            .scrollClipDisabled()
            #if DEBUG
            // Fixture screenshots: PIGTV_UI_TEST_HOME_SCROLL=<shelf title>
            // scrolls that shelf to the top (no remote driving needed).
            .task {
                guard let target = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_HOME_SCROLL"] else { return }
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
        // The sport event page and channel picker belong to the screen, not
        // to a card (a card can be scrolled away or recycled while open).
        .sportPages(app: app, browse: model, clock: clock)
        .task {
            await load()
            // Kept current while Home is on screen: now/next, progress,
            // "in 12 min", history and recordings, once a minute.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                clock = Date()
                if !model.isFixture {
                    await model.loadRecent()
                    await model.loadRecordings()
                }
                refresh()
            }
        }
        .onAppear { clock = Date(); refresh() }
        // Guide pages arrive in bursts; rebuild at most a few times a second.
        .onChange(of: model.guide.count) { scheduleRefresh() }
        // Whole-value equality, not id lists: a recording's status or
        // `native_status` changing (same id) must rebuild Home, while an
        // unrelated publish that leaves these arrays equal does not.
        .onChange(of: model.favourites) { refresh() }
        .onChange(of: model.recent) { refresh() }
        .onChange(of: model.recordings) { refresh() }
        .onChange(of: app.lastWatched) { refresh() }
        // C-I: the sport events (refreshed every minute while Home shows).
        .onReceive(model.sport.$events) { _ in scheduleRefresh() }
        .task { if model.sportEnabled { await model.sport.keepFresh() } }
        .onChange(of: app.playback == nil) { _, closed in if closed { clock = Date(); refresh() } }
        .fullScreenCover(item: $details, onDismiss: finishCover) { item in
            ProgrammeDetails(model: model, channel: item.channel, programme: item.programme, watch: {
                pendingWatch = model.asChannel(item.channel)
                details = nil
            }, openSchedule: {
                pendingSchedule = item.channel
                details = nil
            })
        }
        .fullScreenCover(item: $schedule, onDismiss: finishCover) { channel in
            ChannelScheduleView(model: model, channel: channel, logo: model.logo(for: channel)) {
                pendingWatch = model.asChannel(channel)
                schedule = nil
            }
        }
        .fullScreenCover(item: $playingRecording) { recording in
            RecordingPlayerScreen(recording: recording, client: model.client)
        }
        .fullScreenCover(item: $recordingDetails) { recording in
            RecordingDetails(model: model, original: recording)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PigBrandMark(width: 58, height: 48)
                .accessibilityHidden(true)
            Text("Home").font(GuideTypography.title)
            Text(clock, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(GuideTypography.body).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Shelves

    @ViewBuilder
    private func shelf<Item: Identifiable, Card: View>(_ title: String, _ items: [Item],
                                                       @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(HomeMetrics.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HomeMetrics.cardSpacing) {
                        ForEach(items) { card($0) }
                    }
                    // Room for the focus lift and its shadow.
                    .padding(.vertical, HomeMetrics.shelfPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            // Up/Down move between shelves rather than skipping by geometry.
            .tvFocusSection()
            .id(title)
        }
    }

    // MARK: Data

    private func load() async {
        guard !model.isFixture else { refresh(); return }
        // Build 31: each appearance loads only what is older than a minute
        // (the loop below refreshes every minute while Home shows).
        async let guide: Void = model.loadInitialGuide()
        async let recent: Void = model.loadRecentIfStale()
        await model.loadFavouritesIfStale()
        await recent
        refresh()
        await model.loadRecordingsIfStale()
        await guide
        refresh()
    }

    private func scheduleRefresh() {
        guard rebuild == nil else { return }
        rebuild = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            rebuild = nil
            refresh()
        }
    }

    private func refresh() {
        let sp = PigTVSignpost.begin("HomeRebuild"); defer { PigTVSignpost.end("HomeRebuild", sp) }
        let now = Date()
        let recent = model.recent.map(model.homeChannel)
        let hero = HomeRows.continueWatching(last: app.lastWatched, recent: recent) { last in
            model.guideRow(id: last.id, identityKey: last.identityKey).map(model.homeChannel)
        }
        let favourites = model.favourites.map(model.homeChannel)
        var next = HomeContent()
        next.hero = hero
        next.recent = HomeRows.recentlyWatched(recent, excluding: hero)
        next.favouritesOnNow = HomeRows.onNow(favourites, now: now)
        next.startingSoon = HomeRows.startingSoon(favourites, now: now)
        if model.sportEnabled {
            next.sport = SportRows.nowAndNext(SportRows.buckets(model.sport.events, now: now))
        }
        next.recordings = HomeRows.recordings(model.recordings)
        // One pass over the guide for the recordings' channel logos.
        let names = Set(next.recordings.compactMap(\.channel_name))
        if !names.isEmpty {
            var logos: [String: String] = [:]
            for row in model.guide where names.contains(row.name) && logos[row.name] == nil {
                if let logo = model.logo(for: row) { logos[row.name] = logo }
                if logos.count == names.count { break }
            }
            for recording in next.recordings {
                if let name = recording.channel_name, let logo = logos[name] { next.recordingLogos[recording.id] = logo }
            }
        }
        if next != content { content = next }
    }

    // MARK: Actions

    private func play(_ channel: HomeChannel, from row: [HomeChannel]) {
        app.zapList = row.map(model.playable)
        app.beginPlayback(model.playable(channel))
    }

    private func showDetails(_ item: HomeSoonItem) {
        let row = model.guideRow(id: item.channel.id, identityKey: item.channel.identityKey)
            ?? GuideChannel(rawID: item.channel.rawID, sourceId: item.channel.sourceId, name: item.channel.name,
                            logo: item.channel.logo, category: item.channel.category, programmes: item.channel.programmes,
                            stableId: item.channel.stableId, number: item.channel.number)
        details = HomeDetails(channel: row, programme: item.programme)
    }

    private func open(_ recording: Recording) {
        if recording.playLabel(recordingHls: model.client.info?.features.recordingHls == true) != nil {
            playingRecording = recording
        } else {
            recordingDetails = recording
        }
    }

    private func finishCover() {
        if let channel = pendingSchedule {
            pendingSchedule = nil
            DispatchQueue.main.async { schedule = channel }
            return
        }
        if let channel = pendingWatch { pendingWatch = nil; app.beginPlayback(channel) }
    }
}

// MARK: Hero

/// The "Continue watching" hero: the channel's logo large, what is on and
/// what is next, and Watch. Behind it a wash of the logo's own colours
/// (the logo, scaled up and heavily blurred) under a veil, never video.
private struct HomeHero: View {
    let channel: HomeChannel
    let model: BrowseModel
    let clock: Date
    let watch: () -> Void
    let schedule: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    private enum Control: Hashable { case watch, schedule }
    @FocusState private var focus: Control?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let row = channel.onNow(at: clock)
        #if os(tvOS)
        HStack(alignment: .center, spacing: 56) {
            details(row)
            Spacer(minLength: 0)
            logo
        }
        // Entering the hero from anywhere (the tab bar above, a shelf
        // below) lands on Watch.
        .focusSection()
        .defaultFocus($focus, .watch, priority: .userInitiated)
        .padding(.horizontal, HomeMetrics.heroPadding.width).padding(.vertical, HomeMetrics.heroPadding.height)
        .frame(maxWidth: .infinity, minHeight: HomeMetrics.heroHeight, alignment: .leading)
        .background { LogoWash(logo: channel.logo, client: model.client) }
        .clipShape(RoundedRectangle(cornerRadius: HomeMetrics.heroRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HomeMetrics.heroRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 24, y: 12)
        #else
        Group {
            // Build 31: iPad (regular width) lays the hero out like the TV,
            // logo on the right, so it is short; iPhone stacks it.
            if sizeClass == .regular {
                HStack(alignment: .center, spacing: 24) {
                    details(row)
                    Spacer(minLength: 0)
                    logo
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    logo
                    details(row)
                }
            }
        }
        .padding(.horizontal, HomeMetrics.heroPadding.width).padding(.vertical, HomeMetrics.heroPadding.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { LogoWash(logo: channel.logo, client: model.client) }
        .clipShape(RoundedRectangle(cornerRadius: HomeMetrics.heroRadius, style: .continuous))
        #endif
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.logoTile(scheme))
            if channel.logo != nil {
                ChannelArtwork(logo: channel.logo, client: model.client)
                    .padding(.horizontal, HomeMetrics.heroLogoInset.width).padding(.vertical, HomeMetrics.heroLogoInset.height)
            } else {
                Text(channel.name).font(HomeMetrics.heroChannel).multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.6).padding(16)
            }
        }
        .frame(width: HomeMetrics.heroLogo.width, height: HomeMetrics.heroLogo.height)
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        .accessibilityHidden(true)
    }

    private func details(_ row: OnNowRow) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.heroSpacing) {
            // One line: the eyebrow, then the channel (build 31, was two).
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("CONTINUE WATCHING").font(HomeMetrics.eyebrow).tracking(2.2)
                    .foregroundStyle(Color.pigAccent)
                    .fixedSize()
                Text(channel.name).lineLimit(1).font(HomeMetrics.heroChannel).foregroundStyle(.secondary)
                if let number = channel.number {
                    ChannelNumberText(number: String(number), font: HomeMetrics.cardDetail)
                }
            }
            Text(row.current?.title ?? "No programme information")
                .font(HomeMetrics.heroTitle).lineLimit(1).minimumScaleFactor(0.75)
            if let current = row.current {
                Text("\(timeRange(current)) · \(remaining(current))")
                    .font(HomeMetrics.heroDetail).foregroundStyle(.secondary).lineLimit(1)
                PigProgressBar(fraction: row.progress, height: 6)
                    .frame(maxWidth: 520)
                    .accessibilityLabel("\(Int(row.progress * 100)) percent through")
            }
            if let next = row.next {
                (Text("NEXT  ").font(HomeMetrics.eyebrow).foregroundColor(.secondary)
                 + Text("\(next.start.formatted(date: .omitted, time: .shortened))  ").font(HomeMetrics.heroDetail.monospacedDigit())
                 + Text(next.title).font(HomeMetrics.heroDetail))
                    .lineLimit(1)
            }
            HStack(spacing: 22) {
                Button(action: watch) {
                    Label("Watch", systemImage: "play.fill")
                        #if os(tvOS)
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 2)
                        #endif
                }
                .pigPrimaryButton()
                .focused($focus, equals: .watch)
                .accessibilityLabel("Watch \(channel.name)")
                .accessibilityIdentifier("home.watch")
                if let schedule {
                    Button("Schedule", systemImage: "list.bullet.rectangle", action: schedule)
                        #if os(tvOS)
                        .font(.system(size: 22, weight: .medium))
                        #endif
                        .focused($focus, equals: .schedule)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func timeRange(_ programme: GuideProgramme) -> String {
        "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
    }

    private func remaining(_ programme: GuideProgramme) -> String {
        let minutes = max(1, Int((programme.end.timeIntervalSince(clock) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(rest) min left"
    }
}

/// First run (no history, favourites or recordings yet).
private struct HomeWelcome: View {
    let openGuide: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 22) {
            PigBrandMark(width: 150, height: 120)
                .accessibilityHidden(true)
            Text("Welcome to PigTV").font(HomeMetrics.welcomeTitle)
            Text("Channels you watch, your favourites and your recordings will gather here. Start with the TV Guide, and use Details on any channel to add it to your favourites.")
                .font(HomeMetrics.heroDetail).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            Button(action: openGuide) {
                Label("Open the TV Guide", systemImage: "calendar")
                    #if os(tvOS)
                    .font(.system(size: 26, weight: .semibold))
                    #endif
            }
            .pigPrimaryButton()
            .padding(.top, 10)
        }
        .padding(.vertical, 70).padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .tvFocusSection()
        .background(Color.guideCell(scheme).opacity(0.7), in: RoundedRectangle(cornerRadius: HomeMetrics.heroRadius, style: .continuous))
    }
}

// MARK: Cards

/// Home's card focus: the app's pink outline and translucent pink fill,
/// plus the tvOS lift (scale and shadow).
struct HomeCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HomeMetrics.cardRadius, style: .continuous)
        configuration.label
            .foregroundStyle(.primary)
            .background(focused ? Color.pigAccent.opacity(0.22) : Color.guideCell(scheme), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .scaleEffect(focused && !reduceMotion ? 1.07 : (configuration.isPressed ? 0.98 : 1))
            .shadow(color: .black.opacity(focused ? (scheme == .dark ? 0.6 : 0.25) : 0), radius: focused ? 26 : 0, y: focused ? 16 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// The logo panel at the top of every card (the guide's neutral tile).
private struct CardArt<Badge: View>: View {
    let logo: String?
    let name: String
    let client: APIClient
    var symbol: String? = nil
    @ViewBuilder var badge: Badge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.logoTile(scheme)
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, HomeMetrics.artInset.width).padding(.vertical, HomeMetrics.artInset.height)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.pigAccent)
            } else {
                Text(name).font(HomeMetrics.cardTitle).multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.7).padding(16)
            }
        }
        .frame(width: HomeMetrics.cardWidth, height: HomeMetrics.artHeight)
        .overlay(alignment: .topTrailing) { badge.padding(12) }
    }
}

/// A small capsule label on a card ("LIVE", "in 12 min", "REC").
struct CardBadge: View {
    let text: String
    var systemImage: String? = nil
    var colour: Color = .pigAccent
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(HomeMetrics.cardDetail.weight(.bold))
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(colour, in: Capsule())
        .foregroundStyle(colour == .pigAccent ? Color.pigOnAccent : Color.white)
    }
}

/// The text under a card's art (build 31, one line shorter than before):
/// the title, a progress bar (its space kept when there is none, so cards in
/// a shelf line up), and one detail line.
/// `accent` leads the detail line in colour ("in 12 min", "REC"): with the
/// smaller art, badges drawn over it covered the logo.
private struct CardText: View {
    let title: String
    let progress: Double?
    let detail: String
    var accent: (text: String, colour: Color)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: HomeMetrics.cardTextSpacing) {
            Text(title).font(HomeMetrics.cardTitle).lineLimit(1)
            PigProgressBar(fraction: progress ?? 0)
                .opacity(progress == nil ? 0 : 1)
                .accessibilityHidden(progress == nil)
            detailLine.font(HomeMetrics.cardDetail).lineLimit(1)
        }
        .padding(HomeMetrics.cardPadding)
        .frame(width: HomeMetrics.cardWidth, alignment: .leading)
    }

    private var detailLine: Text {
        let rest = Text(detail.isEmpty ? " " : detail).foregroundColor(.secondary)
        guard let accent else { return rest }
        return Text(accent.text).bold().foregroundColor(accent.colour) + Text(detail.isEmpty ? "" : " · ").foregroundColor(.secondary)
            + (detail.isEmpty ? Text("") : rest)
    }
}

/// A channel: logo, number and name, what is on now with its progress.
private struct HomeChannelCard: View {
    let channel: HomeChannel
    let model: BrowseModel
    let clock: Date
    let action: () -> Void

    var body: some View {
        let row = channel.onNow(at: clock)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CardArt(logo: channel.logo, name: channel.name, client: model.client) { EmptyView() }
                CardText(title: row.current?.title ?? "No programme information", progress: row.current.map { _ in row.progress },
                         detail: [channel.name, row.current.map { "until \($0.end.formatted(date: .omitted, time: .shortened))" }]
                            .compactMap { $0 }.joined(separator: " · "))
            }
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel([channel.number.map(String.init), channel.name,
                             row.current.map { "now \($0.title)" }].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Starting soon: the programme, its channel and "in 12 min".
private struct HomeSoonCard: View {
    let item: HomeSoonItem
    let model: BrowseModel
    let clock: Date
    let action: () -> Void

    var body: some View {
        let countdown = HomeRows.countdown(to: item.programme.start, now: clock)
        let scheduled = model.scheduledKeys.contains(ScheduledRecording.key(channel: item.channel.name, start: item.programme.startTime))
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CardArt(logo: item.channel.logo, name: item.channel.name, client: model.client) { EmptyView() }
                CardText(title: item.programme.title, progress: nil,
                         detail: (scheduled ? "REC · " : "") + "\(item.channel.name) · \(item.programme.start.formatted(date: .omitted, time: .shortened))",
                         accent: (countdown, Color.pigAccent))
            }
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel("\(item.programme.title), \(item.channel.name), starts \(countdown)")
    }
}

/// A recording: in progress (REC) or completed, with its resume point.
private struct HomeRecordingCard: View {
    let recording: Recording
    let logo: String?
    let model: BrowseModel
    let action: () -> Void

    var body: some View {
        let recordingNow = recording.status == "recording"
        let resume = HomeRows.resumeFraction(position: UserDefaults.standard.double(forKey: "pigtv.resume.\(recording.id)"),
                                             duration: recording.duration_sec)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CardArt(logo: logo, name: recording.channel_name ?? recording.title, client: model.client,
                        symbol: "play.rectangle.fill") { EmptyView() }
                CardText(title: recording.title, progress: resume,
                         detail: ([recording.channel_name].compactMap { $0 } + [detail(resuming: resume != nil)])
                            .filter { !$0.isEmpty }.joined(separator: " · "),
                         accent: recordingNow ? ("● REC", Color.red) : nil)
            }
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel("\(recording.title), \(recordingNow ? "recording now" : "recorded")")
    }

    /// The channel and REC lead the line; then the date, length and Resume.
    private func detail(resuming: Bool) -> String {
        var parts: [String] = []
        if let started = recording.started { parts.append(started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        if let duration = recording.duration_sec, duration > 0 { parts.append("\(Int(duration / 60)) min") }
        if resuming { parts.append("Resume") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// A tvOS focus section (Up/Down enter it as a whole); nothing on iOS.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}
