import SwiftUI

// D-44 (Apple 110, #57's Apple half, R5-Search-*), D-66: Search and Jump to on one page, side by side, pushed on the TV
// Guide's NavigationStack, or opened by any tab's magnifier (the app-level page, `AppSearchHost`). Search asks the
// server's index (`LibrarySearchRunner`: teams, games, programmes, channels, recordings), grouped in that order, four rows
// a group then "Show all"; an older server (404) is searched through the loaded guide as before (channels by name,
// programmes in the next 24 hours by title), off the main actor. Before typing: this device's recent searches. Jump to:
// a day, an hour, then Show guide moves the grid there.

/// The search over the loaded guide. Pure; tested (GuidePagesTests).
nonisolated enum GuideSearch {
    struct Results: Equatable, Sendable {
        var channels: [GuideChannel] = []
        var programmes: [GuideSearchHit] = []
        static func == (a: Results, b: Results) -> Bool {
            a.channels.map(\.id) == b.channels.map(\.id) && a.programmes == b.programmes
        }
    }

    /// The window programmes are searched in.
    static let horizon: TimeInterval = 24 * 3600

    /// Channels whose name contains `query` (each listing once, by its stable identity), and programmes whose title
    /// contains it that have not ended and start within the next 24 hours, soonest first. Two letters at least.
    static func run(_ query: String, in guide: [GuideChannel], now: Date, channelLimit: Int = 12,
                    programmeLimit: Int = 60) -> Results {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return Results() }
        var seen = Set<String>()
        let channels = guide.filter { $0.name.localizedStandardContains(text) && seen.insert($0.identityKey).inserted }
        let until = now.addingTimeInterval(horizon)
        var hits: [GuideSearchHit] = []
        for channel in guide {
            for programme in GuideNavigation.ordered(channel.programmes)
            where programme.end > now && programme.start < until && programme.title.localizedStandardContains(text) {
                hits.append(GuideSearchHit(channel: channel, programme: programme))
            }
        }
        hits.sort { ($0.programme.startTime, $0.channel.name) < ($1.programme.startTime, $1.channel.name) }
        return Results(channels: Array(channels.prefix(channelLimit)), programmes: Array(hits.prefix(programmeLimit)))
    }
}

/// Jump to's days and hours. Pure; tested.
nonisolated enum GuideJump {
    /// The time chips a row in Jump to (#57: four, so every label fits whole, "12 pm" included, on the TV as on touch).
    static let hourColumns = 4

    /// "Today", "Tomorrow", then "Wed 5"…, seven days from today.
    static func days(now: Date, calendar: Calendar = .current) -> [(date: Date, title: String)] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let title = offset == 0 ? "Today" : offset == 1 ? "Tomorrow" : day.formatted(.dateTime.weekday(.abbreviated).day())
            return (day, title)
        }
    }

    /// `date` on `day`, keeping its hour (on the hour).
    static func moving(_ date: Date, toDay day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: calendar.component(.hour, from: date), minute: 0, second: 0, of: day) ?? day
    }

    /// `date` at `hour`:00, keeping its day.
    static func moving(_ date: Date, toHour hour: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    }
}

/// What Search's rows do (#57, D-66). The Guide's page and the app-level page (every tab's magnifier) each supply their
/// own: the Guide plays from its grid, the app-level page closes itself first.
struct SearchActions {
    /// Watch a channel (a channel row, or a programme on now).
    var watchChannel: (GuideChannel) -> Void = { _ in }
    /// Watch a live game: the sport player (the live games list).
    var watchGame: (SportEvent) -> Void = { _ in }
    /// Record a game: the record flow (the game's channels).
    var recordGame: (SportEvent) -> Void = { _ in }
    /// Record a programme: the record page.
    var recordProgramme: (GuideChannel, GuideProgramme) -> Void = { _, _ in }
    /// Play a recording: the recording player.
    var playRecording: (Recording) -> Void = { _ in }

    static let none = SearchActions()

    /// Through the app's presentation layer: a play closes what is open first (the player cannot present over a page);
    /// a record page replaces the search page.
    @MainActor static func app(_ app: AppModel, browse: BrowseModel) -> SearchActions {
        SearchActions(
            watchChannel: { channel in app.presenter.dismiss { app.beginPlayback(browse.asChannel(channel), origin: "Search") } },
            watchGame: { event in app.presenter.dismiss { app.playSportEvent(event, origin: "Search") } },
            recordGame: { event in app.record(event) },
            recordProgramme: { channel, programme in
                app.presenter.present(.record(browse.recordRequest(channel: channel, programme: programme)))
            },
            playRecording: { recording in app.presenter.present(.playRecording(recording)) })
    }
}

struct GuideSearchPage: View {
    /// The page reads the guide once per search and the logos; it observes the guide's store only for its state (#280:
    /// still loading, failed, or loaded), and searches again when a load finishes.
    let model: BrowseModel
    private let guideStore: GuideStore
    /// The grid can be moved (not the iPhone's upright On now list).
    let canJump: Bool
    /// Jump to… opened the page: focus starts on the selected day, not the search field.
    let startWithJump: Bool
    let openChannel: (GuideChannel) -> Void
    let openProgramme: (GuideChannel, GuideProgramme) -> Void
    let showGuide: (Date) -> Void
    var pushedFrom: String? = nil
    let actions: SearchActions

    @State private var query = ""
    /// #57: the server's search (debounced, stale answers dropped), or the loaded guide's on an older server.
    @StateObject private var runner: LibrarySearchRunner
    /// Sections showing every row ("Show all").
    @State private var expanded: Set<LibrarySearchSection> = []
    @State private var recent: [String] = []
    /// Teams followed from this page (the server's `followed` is from before).
    @State private var followedHere: Set<String> = []
    @State private var followBusy: Set<String> = []
    /// What the account follows (Settings › Sport's model), read when the page opens: Follow is offered in a followed
    /// league only. nil without the server's `sportFollows`.
    @State private var follows: SportFollows?
    @State private var date: Date
    private enum Focus: Hashable { case field, day(Int) }
    @FocusState private var focus: Focus?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(model: BrowseModel, date: Date, canJump: Bool, startWithJump: Bool,
         openChannel: @escaping (GuideChannel) -> Void, openProgramme: @escaping (GuideChannel, GuideProgramme) -> Void,
         showGuide: @escaping (Date) -> Void, pushedFrom: String? = nil, actions: SearchActions = .none) {
        self.model = model
        self.guideStore = model.guideStore
        _date = State(initialValue: date)
        self.canJump = canJump
        self.startWithJump = startWithJump
        self.openChannel = openChannel
        self.openProgramme = openProgramme
        self.showGuide = showGuide
        self.pushedFrom = pushedFrom
        self.actions = actions
        _runner = StateObject(wrappedValue: Self.runner(for: model))
    }

    /// The server's search, except in the offline fixtures (no server); the loaded guide's when it answers 404.
    static func runner(for model: BrowseModel) -> LibrarySearchRunner {
        let client = model.client
        var fetch: LibrarySearchRunner.Fetch?
        if !model.isFixture { fetch = { @MainActor text in try await client.librarySearch(text) } }
        #if DEBUG
        // #57: the fixture's server search, for the screenshots (PIGTV_UI_TEST_LIBRARY_SEARCH=1).
        if model.isFixture && ProcessInfo.processInfo.environment["PIGTV_UI_TEST_LIBRARY_SEARCH"] == "1" {
            fetch = { @MainActor [weak model] text in GuideFixtures.librarySearch(text, guide: model?.guide ?? []) }
        }
        #endif
        return LibrarySearchRunner(fetch: fetch) { [weak model] text, failed in
            let guide = model?.guide ?? []
            // Computed off the main actor: a real guide holds thousands of channels.
            let found = await Task.detached(priority: .userInitiated) { GuideSearch.run(text, in: guide, now: Date()) }.value
            return LibrarySearchResults(guide: found, query: text, serverFailed: failed)
        }
    }

    var body: some View {
        DetailPage(pushedFrom: pushedFrom) {
            #if os(tvOS)
            HStack(alignment: .top, spacing: PigSpacing.section) {
                searchColumn.frame(maxWidth: .infinity, alignment: .leading)
                if canJump { jumpPanel.frame(width: 640) }
            }
            #else
            if sizeClass == .regular {
                HStack(alignment: .top, spacing: PigSpacing.section) {
                    searchColumn.frame(maxWidth: .infinity, alignment: .leading)
                    if canJump { jumpPanel.frame(width: 340) }
                }
            } else {
                searchColumn
                if canJump { jumpPanel }
            }
            #endif
        }
        .defaultFocus($focus, startWithJump && canJump ? .day(selectedDay) : .field)
        .onAppear {
            recent = RecentSearches().all
            // Back from a result's page: a search that leaving interrupted runs again.
            runner.resume(query)
        }
        .task {
            guard model.sportFollowsEnabled else { return }
            if model.sportFollows.follows == nil { await model.sportFollows.load() }
            follows = model.sportFollows.follows
        }
        .onChange(of: query) {
            expanded = []
            runner.update(query)
        }
        // #280: a guide that was still loading (or failed) is searched as soon as it has channels (the guide's search).
        .onChange(of: model.guideState.showsContent) { _, ready in if ready && runner.usesGuide { runner.refresh(query) } }
        .onDisappear { runner.cancel() }
        #if DEBUG
        .task {
            if let prefill = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SEARCH"], query.isEmpty { query = prefill }
        }
        #endif
    }

    // MARK: Search

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchColumn: some View {
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            Text("Search").font(DetailType.pageTitle).accessibilityAddTraits(.isHeader)
            TextField(runner.usesGuide ? "Channel or programme" : "Team, game, programme, channel or recording", text: $query)
                .autocorrectionDisabled()
                .pigField()
                .focused($focus, equals: .field)
                .onSubmit { remember() }
                .accessibilityIdentifier("search.field")
            // Only the answer for the query on screen: an earlier query's rows are never shown under a newer one.
            let results = runner.results(for: query)
            // The server's search does not need the guide; the guide's search waits for it (and fails with it).
            let state = PageState.search(query: query, searched: results?.query, found: results.map { !$0.isEmpty } ?? false,
                                         guide: runner.usesGuide ? model.guideState : .content)
            if trimmed.count < LibrarySearchRunner.minimumLength {
                recentSearches
            } else if state == .loading {
                SearchResultsPlaceholder()
            } else if let failure = state.failure {
                // #280 (R1): the guide's search looks through the guide, which did not load. The app's next pass retries it.
                PigErrorState(failure: failure, retry: { await model.retryGuide() }, identifier: "search.error",
                              schedule: guideStore.schedule)
            } else if state == .empty {
                // #280 (E1): Show guide is this page's rose button, so Clear search is the secondary one.
                PigEmptyState(title: PageWords.searchNothingTitle(runner.searched ?? trimmed),
                              text: results?.source == .server ? PageWords.searchNothingAnywhereText : PageWords.searchNothingText,
                              action: PigStateAction(label: PageWords.clearSearch, prominent: false) {
                                  query = ""
                                  focus = .field
                              },
                              identifier: "search.empty")
            } else if let results {
                if results.serverFailed {
                    Text(PageWords.searchGuideOnly).font(DetailType.meta).foregroundStyle(Color.pigSecondary)
                        .accessibilityIdentifier("search.guideOnly")
                }
                ForEach(results.sections) { section in
                    resultSection(section, in: results)
                }
            }
        }
    }

    /// Before typing (D-66): this device's last searches, newest first; a hint when there are none.
    @ViewBuilder
    private var recentSearches: some View {
        if recent.isEmpty {
            Text(LibrarySearchSection.hint(guideOnly: runner.usesGuide))
                .font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary)
        } else {
            HStack(spacing: PigSpacing.m) {
                sectionTitle("Recent searches")
                Spacer(minLength: 0)
                Button("Clear") {
                    RecentSearches().clear()
                    recent = []
                }
                .pigSecondaryButton()
                .accessibilityIdentifier("search.recent.clear")
            }
            FlowChips(spacing: PigSpacing.s) {
                ForEach(recent, id: \.self) { text in
                    Button { query = text } label: { Label(text, systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(GuideFilterStyle(selected: false))
                        .accessibilityLabel("Search again for \(text)")
                }
            }
            .accessibilityIdentifier("search.recent")
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    /// Keeps the query among the recent searches (a submit, or acting on a result).
    private func remember() {
        let text = runner.searched ?? trimmed
        guard text.count >= LibrarySearchRunner.minimumLength else { return }
        recent = RecentSearches().add(text)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(DetailType.rowDetail.weight(.bold)).foregroundStyle(Color.pigSecondary).pigFigures()
            .padding(.top, PigSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    /// One group: its title, four rows, then "Show all" in place (D-66).
    private func resultSection(_ section: LibrarySearchSection, in results: LibrarySearchResults) -> some View {
        let count = results.count(section)
        let isExpanded = expanded.contains(section)
        let shown = LibrarySearchLayout.visible(count, expanded: isExpanded)
        return VStack(alignment: .leading, spacing: PigSpacing.s) {
            sectionTitle("\(section.title(count: count, source: results.source)) · \(count)")
            LazyVStack(alignment: .leading, spacing: PigSpacing.s) {
                switch section {
                case .teams:
                    ForEach(results.teams.prefix(shown)) { teamRow($0) }
                case .games:
                    ForEach(results.games.prefix(shown)) { gameRow($0) }
                case .programmes:
                    ForEach(results.programmes.prefix(shown)) { programmeRow($0) }
                case .channels:
                    ForEach(results.channels.prefix(shown)) { channelRow($0) }
                case .recordings:
                    ForEach(results.recordings.prefix(shown)) { recordingRow($0) }
                }
            }
            if LibrarySearchLayout.offersShowAll(count, expanded: isExpanded) {
                Button("Show all \(count)") { expanded.insert(section) }
                    .pigSecondaryButton()
                    .accessibilityLabel("Show all \(count) \(section.title(count: count, source: results.source).lowercased())")
                    .accessibilityIdentifier("search.showAll.\(section.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.section.\(section.rawValue)")
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: Rows

    private func programmeRow(_ hit: GuideSearchHit) -> some View {
        let scheduled = model.activeSchedule(channel: hit.channel, programme: hit.programme) != nil
        let record: (() -> Void)? = scheduled ? nil : {
            remember()
            actions.recordProgramme(hit.channel, hit.programme)
        }
        return SearchResultRow(model: model, channel: hit.channel, programme: hit.programme,
                               action: { remember(); openProgramme(hit.channel, hit.programme) },
                               watch: { remember(); actions.watchChannel(hit.channel) },
                               record: record)
    }

    private func teamRow(_ team: LibrarySearchTeam) -> some View {
        let followed = team.followed || followedHere.contains(team.id)
        let sport = LibrarySearchFollow.sport(forLeague: team.league, in: follows)
        return SearchRowCard {
            SportBadge(name: team.name, logo: team.cachedLogo, league: team.league, client: model.client,
                       size: SearchRowMetrics.badge)
            SearchRowText(title: team.name, detail: SearchRowWords.teamDetail(league: team.league, followed: followed))
        } watch: {
            EmptyView()
        } other: {
            if followed {
                // A state, not an action: on touch its icon (the detail line says "Following").
                Label(SearchRowWords.following, systemImage: "checkmark")
                    .font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary)
                    .accessibilityIdentifier("search.team.following")
            } else if let sport {
                Button("Follow", systemImage: "plus") { follow(team, sport: sport) }
                    .pigSecondaryButton()
                    .disabled(followBusy.contains(team.id))
                    .accessibilityLabel("Follow \(team.name)")
            }
        }
        .accessibilityIdentifier("search.team.\(team.id)")
    }

    private func follow(_ team: LibrarySearchTeam, sport: String) {
        remember()
        followBusy.insert(team.id)
        Task {
            if await model.sportFollows.follow(sport, team.name) { followedHere.insert(team.id) }
            follows = model.sportFollows.follows
            followBusy.remove(team.id)
        }
    }

    private func gameRow(_ event: SportEvent) -> some View {
        let now = Date()
        let live = event.isLive(at: now) && !event.channels.isEmpty
        let detail = [event.league, live ? nil : DetailText.day(event.start, now: now),
                      "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))",
                      event.best?.name].compactMap { $0 }.joined(separator: " · ")
        return SearchRowCard {
            SportBadge(name: event.title, logo: nil, league: event.league, client: model.client, size: SearchRowMetrics.badge)
            SearchRowText(title: event.title, detail: detail, tags: ProgrammeTags(live: live))
        } watch: {
            if live {
                Button("Watch", systemImage: "play.fill") { remember(); actions.watchGame(event) }
                    .pigSecondaryButton()
                    .accessibilityLabel("Watch \(event.title)")
            }
        } other: {
            if event.end > now {
                Button("Record", systemImage: "record.circle") { remember(); actions.recordGame(event) }
                    .pigSecondaryButton()
                    .accessibilityLabel("Record \(event.title)")
            }
        }
        .accessibilityIdentifier("search.game.\(event.id)")
    }

    private func channelRow(_ channel: GuideChannel) -> some View {
        // The loaded guide's copy has the schedule (the search's row may not).
        let programmes = model.guideChannel(id: channel.id)?.programmes ?? channel.programmes
        let now = OnNowRow.make(programmes: programmes, now: Date()).current
        return SearchRowCard(action: { remember(); openChannel(channel) },
                             label: [channel.name, now.map { "on now: \($0.title)" }].compactMap { $0 }.joined(separator: ", ")) {
            ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                            size: SearchRowMetrics.logo)
            SearchRowText(title: channel.name, detail: now.map { "On now: \($0.title)" })
        } watch: {
            Button("Watch", systemImage: "play.fill") { remember(); actions.watchChannel(channel) }
                .pigSecondaryButton()
                .accessibilityLabel("Watch \(channel.name)")
        } other: {
            EmptyView()
        }
        .accessibilityIdentifier("search.channel.\(channel.id)")
    }

    private func recordingRow(_ recording: Recording) -> some View {
        let detail = [recording.channel_name, recording.started.map { DetailText.day($0, now: Date()) },
                      recording.status == "recording" ? "Recording now" : nil].compactMap { $0 }.joined(separator: " · ")
        return SearchRowCard(action: { remember(); actions.playRecording(recording) },
                             label: "Play \(recording.title)\(detail.isEmpty ? "" : ", \(detail)")") {
            ChannelLogoTile(logo: recording.image ?? recording.channel_logo, client: model.client,
                            name: recording.channel_name ?? recording.title, size: SearchRowMetrics.logo)
            SearchRowText(title: recording.title, detail: detail.isEmpty ? nil : detail)
        } watch: {
            EmptyView()
        } other: {
            Image(systemName: "play.fill").font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("search.recording.\(recording.id)")
    }

    // MARK: Jump to

    private var selectedDay: Int {
        GuideJump.days(now: Date()).firstIndex { Calendar.current.isDate($0.date, inSameDayAs: date) } ?? 0
    }

    private var jumpPanel: some View {
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            Text("Jump to").font(DetailType.pageTitle).accessibilityAddTraits(.isHeader)
            sectionTitle("Day")
            FlowChips(spacing: PigSpacing.s) {
                ForEach(Array(GuideJump.days(now: Date()).enumerated()), id: \.offset) { index, day in
                    Button(day.title) { date = GuideJump.moving(date, toDay: day.date) }
                        .buttonStyle(GuideFilterStyle(selected: Calendar.current.isDate(day.date, inSameDayAs: date)))
                        .focused($focus, equals: .day(index))
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
            sectionTitle("Time")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PigSpacing.s), count: hourColumns), spacing: PigSpacing.s) {
                ForEach(0..<24, id: \.self) { hour in
                    Button { date = GuideJump.moving(date, toHour: hour) } label: {
                        Text(GuideJump.moving(Date(), toHour: hour).formatted(.dateTime.hour()))
                            .pigFigures().lineLimit(1).pigMinimumScale(0.7, size: PigType.body).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideFilterStyle(selected: Calendar.current.component(.hour, from: date) == hour))
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                .font(DetailType.meta).foregroundStyle(Color.pigSecondary).pigFigures()
            Button("Show guide", systemImage: "calendar") { showGuide(date) }
                .pigPrimaryButton()
        }
        .padding(DetailMetrics.heroPadding / 1.6)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
    }

    /// Four hours a row on every device: six on the TV cut "12 pm" to "12…" in the 640 pt panel.
    private var hourColumns: Int { GuideJump.hourColumns }
}

/// Chips that wrap onto more lines when the row is full.
private struct FlowChips: Layout {
    var spacing: CGFloat = PigSpacing.s
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

nonisolated enum SearchRowMetrics {
    #if os(tvOS)
    static let logo = CGSize(width: 136, height: 76)
    static let badge: CGFloat = 76
    #else
    static let logo = CGSize(width: 72, height: 40)
    static let badge: CGFloat = 40
    #endif
}

/// A result row's title, its line, and (a programme or a game) its LIVE / NEW badges and episode.
private struct SearchRowText: View {
    let title: String
    var detail: String? = nil
    var tags: ProgrammeTags? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            Text(title).font(DetailType.rowTitle).lineLimit(1)
            if let tags, !tags.isEmpty { ProgrammeTagsRow(tags: tags, title: title, font: DetailType.rowDetail) }
            if let detail {
                Text(detail).font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(1)
            }
        }
    }
}

/// A result row: the row itself (a button when it opens or plays something), then its actions in a fixed column at the
/// trailing edge: a Watch slot, then one for Record, Follow / Following or Play. Each slot keeps the width of its widest
/// action whether it has one or not, so every row's card is the same width and each action sits at the same x on every
/// row. On the TV the row and each action are separate focus targets in one line.
private struct SearchRowCard<Leading: View, Watch: View, Other: View>: View {
    var action: (() -> Void)? = nil
    /// What VoiceOver (and the focus) reads for the row; nil: its texts.
    var label: String? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var watch: Watch
    @ViewBuilder var other: Other

    init(action: (() -> Void)? = nil, label: String? = nil, @ViewBuilder leading: () -> Leading,
         @ViewBuilder watch: () -> Watch, @ViewBuilder other: () -> Other) {
        self.action = action
        self.label = label
        self.leading = leading()
        self.watch = watch()
        self.other = other()
    }

    var body: some View {
        HStack(spacing: PigSpacing.s) {
            if let action {
                let button = Button(action: action) { content }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                if let label { button.accessibilityLabel(label) } else { button }
            } else {
                content
                    .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
                    .accessibilityElement(children: .combine)
            }
            HStack(spacing: PigSpacing.s) {
                SearchActionSlot(template: { Self.button("Watch", "play.fill") }) { watch }
                SearchActionSlot(template: {
                    Self.button("Record", "record.circle")
                    Self.button("Follow", "plus")
                    Label(SearchRowWords.following, systemImage: "checkmark").font(DetailType.rowDetail)
                }) { other }
            }
            #if os(iOS)
            // Touch: Search's column is narrow (iPad beside Jump to, the iPhone): the actions are their icons (each
            // keeps its spoken label), so the row's title keeps the room.
            .labelStyle(.iconOnly)
            #endif
        }
        // The row's identifier (set by its caller) names the row, not each control in it.
        .accessibilityElement(children: .contain)
    }

    /// A slot's sizing copy of an action (never drawn, focused or read).
    private static func button(_ title: String, _ icon: String) -> some View {
        Button(title, systemImage: icon) {}.pigSecondaryButton()
    }

    private var content: some View {
        HStack(spacing: PigSpacing.l) {
            leading
            Spacer(minLength: 0)
        }
        #if os(tvOS)
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        #else
        .padding(PigSpacing.m)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One action slot of a result row: as wide as the widest action it can hold (its hidden `template`), the action (or
/// nothing) at its trailing edge.
private struct SearchActionSlot<Template: View, Content: View>: View {
    @ViewBuilder var template: Template
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack { template }
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
            content
        }
    }
}

/// Search's row words. Pure; tested (LibrarySearchTests).
nonisolated enum SearchRowWords {
    static let following = "Following"

    /// A team's line: its league; on touch, where Following is only an icon, "AFL · Following" when it is followed.
    static func teamDetail(league: String, followed: Bool, touch: Bool = SearchRowWords.isTouch) -> String {
        followed && touch ? "\(league) · \(following)" : league
    }

    static var isTouch: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
}

/// A programme found: opens its page; Watch while it is on, Record until it ends (not when already scheduled).
private struct SearchResultRow: View {
    let model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let action: () -> Void
    var watch: (() -> Void)? = nil
    var record: (() -> Void)? = nil

    /// "On now · " before the detail line on touch (the TV draws the pill beside the title).
    private func touchOnNow(_ live: Bool) -> String {
        #if os(tvOS)
        ""
        #else
        ProgrammeTags.showsOnNow(live: live, tags: ProgrammeTags(programme)) ? "On now · " : ""
        #endif
    }

    var body: some View {
        let now = Date()
        let live = programme.isLive(at: now)
        let tags = ProgrammeTags(programme)
        let line = "\(channel.name) · \(DetailText.day(programme.start, now: now)) · \(programme.timeRange)"
        let spoken = [programme.title, tags.spoken(title: programme.title), channel.name,
                      "\(DetailText.day(programme.start, now: now)) \(programme.timeRange)", live ? "on now" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        SearchRowCard(action: action, label: spoken) {
            ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name, size: SearchRowMetrics.logo)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                #if os(tvOS)
                HStack(spacing: PigSpacing.s) {
                    Text(programme.title).font(DetailType.rowTitle).lineLimit(1)
                    if ProgrammeTags.showsOnNow(live: live, tags: tags) { StatusPill(text: "On now", colour: .pigAccent).fixedSize() }
                }
                ProgrammeTagsRow(tags: tags, title: programme.title, font: DetailType.rowDetail)
                #else
                // Touch: the column is narrow, so the title has its line to itself and On now leads the detail line.
                Text(programme.title).font(DetailType.rowTitle).lineLimit(1)
                ProgrammeTagsRow(tags: tags, title: programme.title, font: DetailType.rowDetail)
                #endif
                Text(touchOnNow(live) + line).font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(1)
            }
        } watch: {
            if live, let watch {
                Button("Watch", systemImage: "play.fill", action: watch)
                    .pigSecondaryButton()
                    .accessibilityLabel("Watch \(programme.title) on \(channel.name)")
            }
        } other: {
            if programme.end > now, let record {
                Button("Record", systemImage: "record.circle", action: record)
                    .pigSecondaryButton()
                    .accessibilityLabel("Record \(programme.title)")
            }
        }
    }
}
