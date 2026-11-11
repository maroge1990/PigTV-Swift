import SwiftUI

// D-44 (Apple 110, #57's Apple half, R5-Search-*): Search and Jump to on one page, side by side, pushed on the TV
// Guide's NavigationStack. Search looks through the loaded guide (channels by name, programmes in the next 24 hours by
// title), debounced and off the main actor, with results keyed by stable ids; a channel opens its page, a programme its
// page. Jump to: a day, an hour, then Show guide moves the grid there. The server's full-text search is not used.

/// One programme found: keyed by the channel's id and the programme's start (stable across refreshes).
nonisolated struct GuideSearchHit: Identifiable, Equatable, Sendable {
    let channel: GuideChannel
    let programme: GuideProgramme
    var id: String { "\(channel.id)|\(programme.startTime)" }
    static func == (a: GuideSearchHit, b: GuideSearchHit) -> Bool { a.id == b.id && a.programme == b.programme }
}

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

struct GuideSearchPage: View {
    /// The page reads the guide once per search and the logos; it observes the guide's store only for its state (#280:
    /// still loading, failed, or loaded), and searches again when a load finishes.
    let model: BrowseModel
    @ObservedObject private var guideStore: GuideStore
    /// The grid can be moved (not the iPhone's upright On now list).
    let canJump: Bool
    /// Jump to… opened the page: focus starts on the selected day, not the search field.
    let startWithJump: Bool
    let openChannel: (GuideChannel) -> Void
    let openProgramme: (GuideChannel, GuideProgramme) -> Void
    let showGuide: (Date) -> Void
    var pushedFrom: String? = nil

    @State private var query = ""
    @State private var results = GuideSearch.Results()
    /// #280: the query the results are for (nil until a search has run).
    @State private var searched: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var date: Date
    private enum Focus: Hashable { case field, day(Int) }
    @FocusState private var focus: Focus?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(model: BrowseModel, date: Date, canJump: Bool, startWithJump: Bool,
         openChannel: @escaping (GuideChannel) -> Void, openProgramme: @escaping (GuideChannel, GuideProgramme) -> Void,
         showGuide: @escaping (Date) -> Void, pushedFrom: String? = nil) {
        self.model = model
        _guideStore = ObservedObject(wrappedValue: model.guideStore)
        _date = State(initialValue: date)
        self.canJump = canJump
        self.startWithJump = startWithJump
        self.openChannel = openChannel
        self.openProgramme = openProgramme
        self.showGuide = showGuide
        self.pushedFrom = pushedFrom
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
        .onChange(of: query) { scheduleSearch() }
        // #280: a guide that was still loading (or failed) is searched as soon as it has channels.
        .onChange(of: model.guideState.showsContent) { _, ready in if ready { scheduleSearch() } }
        .onDisappear { searchTask?.cancel() }
        #if DEBUG
        .task {
            if let prefill = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SEARCH"], query.isEmpty { query = prefill }
        }
        #endif
    }

    // MARK: Search

    private var searchColumn: some View {
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            Text("Search").font(DetailType.pageTitle).accessibilityAddTraits(.isHeader)
            TextField("Channel or programme", text: $query)
                .autocorrectionDisabled()
                .pigField()
                .focused($focus, equals: .field)
                .accessibilityIdentifier("search.field")
            let state = PageState.search(query: query, searched: searched,
                                         found: !results.channels.isEmpty || !results.programmes.isEmpty, guide: model.guideState)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                Text("Type two letters or more: channels by name, and programmes in the next 24 hours.")
                    .font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary)
            } else if state == .loading {
                SearchResultsPlaceholder()
            } else if let failure = state.failure {
                // #280 (R1): Search looks through the guide, which did not load. The app's next pass retries it.
                PigErrorState(failure: failure, retry: { await model.retryGuide() }, identifier: "search.error",
                              schedule: guideStore.schedule)
            } else if state == .empty {
                // #280 (E1): Show guide is this page's rose button, so Clear search is the secondary one.
                PigEmptyState(title: PageWords.searchNothingTitle(searched ?? query), text: PageWords.searchNothingText,
                              action: PigStateAction(label: PageWords.clearSearch, prominent: false) {
                                  query = ""
                                  focus = .field
                              },
                              identifier: "search.empty")
            } else {
                if !results.channels.isEmpty {
                    sectionTitle("Channels · \(results.channels.count)")
                    ScrollView(.horizontal) {
                        HStack(spacing: PigSpacing.s) {
                            ForEach(results.channels) { channel in channelButton(channel) }
                        }
                        .padding(.vertical, PigSpacing.s)
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }
                sectionTitle("Programmes · next 24 hours · \(results.programmes.count)")
                if results.programmes.isEmpty {
                    Text("No programmes in the next 24 hours match.").font(DetailType.meta).foregroundStyle(Color.pigSecondary)
                }
                LazyVStack(alignment: .leading, spacing: PigSpacing.s) {
                    ForEach(results.programmes) { hit in
                        SearchResultRow(model: model, channel: hit.channel, programme: hit.programme) {
                            openProgramme(hit.channel, hit.programme)
                        }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(DetailType.rowDetail.weight(.bold)).foregroundStyle(Color.pigSecondary).monospacedDigit()
            .padding(.top, PigSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func channelButton(_ channel: GuideChannel) -> some View {
        let now = OnNowRow.make(programmes: channel.programmes, now: Date()).current
        return Button { openChannel(channel) } label: {
            HStack(spacing: PigSpacing.m) {
                ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                                size: DetailMetrics.smallLogo)
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(channel.name).font(DetailType.rowTitle).lineLimit(1)
                    if let now { Text(now.title).font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary).lineLimit(1) }
                }
            }
            .padding(.vertical, PigSpacing.s).padding(.leading, PigSpacing.s).padding(.trailing, PigSpacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .accessibilityLabel([channel.name, now.map { "on now: \($0.title)" }].compactMap { $0 }.joined(separator: ", "))
    }

    /// Debounced, and computed off the main actor: a real guide holds thousands of channels.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        let guide = model.guide
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let found = await Task.detached(priority: .userInitiated) { GuideSearch.run(text, in: guide, now: Date()) }.value
            guard !Task.isCancelled else { return }
            results = found
            searched = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
                            .monospacedDigit().lineLimit(1).pigMinimumScale(0.7, size: PigType.body).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GuideFilterStyle(selected: Calendar.current.component(.hour, from: date) == hour))
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                .font(DetailType.meta).foregroundStyle(Color.pigSecondary)
            Button("Show guide", systemImage: "calendar") { showGuide(date) }
                .pigPrimaryButton()
        }
        .padding(DetailMetrics.heroPadding / 1.6)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
    }

    private var hourColumns: Int {
        #if os(tvOS)
        6
        #else
        4
        #endif
    }
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

private struct SearchResultRow: View {
    let model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let action: () -> Void

    init(model: BrowseModel, channel: GuideChannel, programme: GuideProgramme, action: @escaping () -> Void) {
        self.model = model
        self.channel = channel
        self.programme = programme
        self.action = action
    }

    var body: some View {
        let now = Date()
        let live = programme.isLive(at: now)
        Button(action: action) {
            HStack(spacing: PigSpacing.l) {
                #if os(tvOS)
                ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                                size: CGSize(width: 136, height: 76))
                #else
                ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                                size: CGSize(width: 72, height: 40))
                #endif
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    HStack(spacing: PigSpacing.s) {
                        Text(programme.title).font(DetailType.rowTitle).lineLimit(1)
                        if live { StatusPill(text: "On now", colour: .pigAccent) }
                    }
                    Text("\(channel.name) · \(DetailText.day(programme.start, now: now)) · \(programme.timeRange)")
                        .font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(DetailType.rowDetail).foregroundStyle(Color.pigSecondary)
                    .accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
            #else
            .padding(PigSpacing.m)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .accessibilityLabel("\(programme.title), \(channel.name), \(DetailText.day(programme.start, now: now)) \(programme.timeRange)\(live ? ", on now" : "")")
    }
}
