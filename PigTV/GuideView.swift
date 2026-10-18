import SwiftUI

private struct GuideSelection: Identifiable {
    let id = UUID()
    let channel: GuideChannel
    let programme: GuideProgramme
}

// Focus identity for every focusable element on the guide screen. Grid cells
// use the channel identity plus a programme start; -1 marks the placeholder
// cell of a channel without EPG data; nil marks the channel tile.
private struct GuideFocus: Hashable {
    let channel: String
    let start: Double?
}

private struct FilterStripMetrics: Equatable {
    var offset: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var contentWidth: CGFloat = 0

    private var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    private var overflows: Bool { maximumOffset > 1 }
    var fadesLeading: Bool { overflows && offset > 1 }
    var fadesTrailing: Bool { overflows && offset < maximumOffset - 1 }
}

/// Build 31: the inputs of GuideView's filtered rows.
private struct GuideRowsInput: Equatable {
    /// Guides this large are filtered off the main actor.
    static let offMainThreshold = 3000
    var count: Int
    var first: String?
    var last: String?
    var loadedAt: Date?
    var fromCache: Bool
    var filter: String
    var search: String
    var favourites: [String]
    var categories: Int
    // Build 33: channel identity/count alone does not change when a forward
    // extension merges more programmes into existing rows, so this is what
    // tells the memoisation below to recompute `rows` for that.
    var programmesVersion: Int
}

struct GuideView: View {
    @ObservedObject var app: AppModel
    /// Not observed itself (audit R05): the Guide draws from the guide
    /// store, the favourites and the schedule marks, and from nothing else
    /// BrowseModel holds, so a recordings refresh or a busy flag elsewhere
    /// does not re-render it.
    let model: BrowseModel
    @ObservedObject private var guideStore: GuideStore
    @ObservedObject private var library: LibraryStore
    @ObservedObject private var marks: ScheduleMarks
    @AppStorage("pigtv.guide.filter") private var filter = "all"
    @AppStorage("pigtv.guide.channel") private var lastChannel = ""
    @State private var viewport = GuideNavigation.rounded(Date())
    @State private var programmeSearch = ""
    @State private var pendingSelection: GuideSelection?
    @State private var clock = Date()
    @State private var lastPeriodicRefresh = Date()
    @State private var search = ""
    @State private var searching = false
    @State private var choosingDate = false
    /// Show guide was chosen (its own `goTo` already claims grid focus).
    @State private var jumped = false
    @State private var jumpDate = Date()
    @State private var selection: GuideSelection?
    @State private var channelDetails: Channel?
    @State private var schedule: GuideChannel?
    @State private var pendingWatch: Channel?
    // A details page's "Channel schedule": opened once that page has closed.
    @State private var pendingSchedule: GuideChannel?
    @State private var filterStripMetrics = FilterStripMetrics()
    // Filtered rows are cached: filtering hundreds of channels inside `body`
    // on every focus change or clock tick is what made scrolling stutter.
    @State private var rows: [GuideChannel] = []
    // Pending coalesced row refresh (R18): rapid category taps and background
    // guide paging each replace this, so only the last one filters 18 000
    // channels and diffs the grid.
    @State private var rowsRefresh: Task<Void, Never>?
    // Set by a category change; the next row refresh (whichever triggered it)
    // also resets the time window and scrolls to the top.
    @State private var filterResetPending = false
    @State private var scrollToTop = 0
    // tvOS: the UIKit grid (GuideGridView, A2.1) is the only grid since
    // build 27. The UIKit grid's focus (it reports it; nothing here assigns it).
    @State private var gridFocus: GuideFocus?
    @State private var gridRequest: GuideGridRequest?
    @State private var rowsVersion = 0
    @State private var gridReady = false
    @State private var lastRowsInput: GuideRowsInput?
    // Bumped when the player or a details cover closes (the UIKit grid
    // refocuses its last programme or tile).
    @State private var gridFocusRestore = 0
    @FocusState private var gridHasFocus: Bool
    // tvOS: the header's Now button, where Up from the grid's top row
    // lands (the grid hands focus over through `leaveUp`).
    @FocusState private var headerNowFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    init(app: AppModel, model: BrowseModel) {
        self.app = app
        self.model = model
        _guideStore = ObservedObject(wrappedValue: model.guideStore)
        _library = ObservedObject(wrappedValue: model.library)
        _marks = ObservedObject(wrappedValue: model.marks)
    }

    /// iPhone in landscape (compact height): one slim bar replaces the header,
    /// the filters and the details row, and the tab bar hides.
    private var slim: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private var category: Category? { app.categories.first { $0.id == filter } }
    /// Favourite membership by identity (review F5): a list with the same
    /// count but different channels must still refresh the rows.
    private var favouriteKeys: [String] { model.favourites.map(\.identityKey) }
    // The focused grid element.
    private var currentFocus: GuideFocus? { gridFocus }
    private var focusedChannel: GuideChannel? {
        guard let key = currentFocus else { return nil }
        return model.guideChannel(id: key.channel)
    }
    private var focusedProgramme: GuideProgramme? {
        guard let start = currentFocus?.start else { return nil }
        return focusedChannel?.programmes.first { $0.startTime == start }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                #if os(tvOS)
                // Never compact on the TV. The reader's first pass has zero
                // size, which read as compact and built the phone menu only to
                // throw it away (part of the first visit's stall).
                let compact = false
                #else
                let compact = geometry.size.width < 700
                #endif
                VStack(alignment: .leading, spacing: slim ? 4 : 10) {
                    if slim {
                        slimBar
                    } else {
                        header(compact: compact)
                        filters(compact: compact)
                    }
                    if !compact && !slim {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(focusedProgramme?.title ?? focusedChannel?.name ?? "Choose a programme to watch")
                                .font(GuideTypography.body.weight(.semibold)).lineLimit(1, reservesSpace: true)
                            Text(focusedDetail)
                                .font(GuideTypography.small).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                        }
                        .frame(height: 78, alignment: .top)
                        Spacer()
                        if model.guideHasMore && model.guideError == nil {
                            ProgressView()
                            Text("\(model.guide.count) of \(model.guideTotal) channels")
                                .font(GuideTypography.small).foregroundStyle(.secondary)
                        }
                        if let programme = focusedProgramme, let channel = focusedChannel {
                            Button("Details", systemImage: "info.circle") {
                                selection = GuideSelection(channel: channel, programme: programme)
                            }
                        }
                    }.frame(height: 78, alignment: .top).padding(.horizontal, 24)
                    }
                    if let error = model.guideError {
                        RetryBanner(message: error) { reload() }
                    }
                    // Build 29: the UIKit grid on iPad too (free touch
                    // scrolling there); iPhone keeps the On now list.
                    if usesOnNowList {
                        onNowList
                    } else {
                        gridView()
                    }
                }
                // No top inset under the header: it sits at the same corner on every tab (PigPageHeader).
                .padding(.top, slim ? 4 : 0).padding(.bottom, slim ? 4 : 12)
            }
            #if os(iOS)
            // Landscape iPhone: the grid gets the height (every control is in
            // the slim bar); rotate to portrait to reach the other tabs.
            .toolbar(slim ? .hidden : .automatic, for: .tabBar)
            // No empty navigation bar above the header, as on every other tab (it put the Guide's header lower).
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .buttonStyle(GuideFilterStyle())
            // The app's page behind the guide (build 28): tvOS otherwise
            // shows its blurred system backdrop in dark mode.
            .pigPageBackdrop()
            .whileVisible {
                // Back on screen after a while: the clock is stale at once.
                clock = Date()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    clock = Date()
                }
            }
            .detailCover(isPresented: $searching, onDismiss: {
                if let pending = pendingSelection { pendingSelection = nil; selection = pending }
                else if usesGridView { gridFocusRestore += 1; claimGridFocus() }
            }) { searchSheet }
            // A full-screen cover on tvOS: a tvOS sheet is a narrow card and
            // clipped the day and time chips (R6.14).
            .detailCover(isPresented: $choosingDate, onDismiss: finishJump) { datePicker }
            .task {
                // The guide always opens at the current half-hour; restoring a
                // later browsing position stranded the grid hours ahead.
                viewport = GuideNavigation.rounded(Date())
                // Shared with Home (build 28): whichever appears first loads.
                await model.loadInitialGuide()
                // Build 31: not on every appearance, only when stale.
                await model.loadFavouritesIfStale()
                await model.loadRecordingsIfStale()
            }
            .task { await model.loadArtworkIndex() }
            .whileVisible {
                // Periodic refresh keeps the loaded day current during long sessions.
                // Counted from the last one, not from each appearance, so
                // visiting other tabs neither skips nor repeats it.
                while !Task.isCancelled {
                    let wait = max(1, 15 * 60 - Date().timeIntervalSince(lastPeriodicRefresh))
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    lastPeriodicRefresh = Date()
                    await model.refreshGuideIfStale()
                    await model.loadRecordings(quietly: true)
                }
            }
            .onAppear {
                refreshRows()
                if !gridReady { NextFrame.run { gridReady = true } }
            }
            // Background paging adds 50 channels at a time; refresh at most a
            // few times a second rather than once per page.
            .onChange(of: model.guide.count) {
                // Throttle, not debounce: pages can arrive faster than the
                // interval, and the first page should appear at once.
                if rows.isEmpty { refreshRows() }
                else if rowsRefresh == nil { scheduleRowsRefresh(after: .milliseconds(400)) }
            }
            .onChange(of: favouriteKeys) { refreshRows() }
            .onChange(of: search) { refreshRows() }
            // Every layout (16 Oct): this was on the iPad/tvOS grid only, so the
            // iPhone's On now list ignored a category change until the Guide
            // reappeared. Coalesced (R18); the grid returns to the top row and
            // the live baseline once taps settle.
            .onChange(of: filter) {
                gridFocus = nil
                filterResetPending = true
                scheduleRowsRefresh(after: .milliseconds(250))
            }
            // Build 33: a forward extension merged more programmes in place.
            .onChange(of: model.guideProgrammesVersion) { refreshRows() }
            .onChange(of: app.playback == nil) { _, closed in
                if closed, usesGridView { gridFocusRestore += 1; claimGridFocus() }
            }
            .fullScreenCover(item: $selection, onDismiss: finishDetails) { item in
                ProgrammeDetails(model: model, channel: item.channel, programme: item.programme, watch: {
                    pendingWatch = asChannel(item.channel)
                    selection = nil
                }, openSchedule: {
                    pendingSchedule = item.channel
                    selection = nil
                })
            }
            .fullScreenCover(item: $channelDetails, onDismiss: finishDetails) { channel in
                ChannelDetails(channel: channel, browse: model, watch: {
                    pendingWatch = channel
                    channelDetails = nil
                }, openSchedule: model.guideChannel(id: channel.id).map { row in {
                    pendingSchedule = row
                    channelDetails = nil
                } })
            }
            .fullScreenCover(item: $schedule, onDismiss: finishDetails) { channel in
                ChannelScheduleView(model: model, channel: channel, logo: model.logo(for: channel)) {
                    pendingWatch = asChannel(channel)
                    schedule = nil
                }
            }
        }
    }

    // A4.4: iPhone (compact width) shows the "On now" list instead of the
    // one-hour grid; iPad (regular width) keeps the grid.
    private var usesOnNowList: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var onNowList: some View {
        #if os(iOS)
        if model.guideBusy && model.guide.isEmpty {
            ProgressView("Loading guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty && !model.guideBusy && !model.guideHasMore && model.guideError == nil {
            ContentUnavailableView(filter == "favourites" ? "No favourites yet" : "No matching channels",
                systemImage: filter == "favourites" ? "heart" : "magnifyingglass",
                description: Text(filter == "favourites" ? "Open a channel's schedule, then add it to favourites." : "Try another category or search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OnNowList(rows: rows, model: model, clock: clock, play: { play($0) }, info: { schedule = $0 })
        }
        #endif
    }

    // A2.1: the UIKit grid is the tvOS grid; since build 29 also the iPad's
    // (regular width). The SwiftUI grid was deleted.
    private var usesGridView: Bool { !usesOnNowList }

    // A2.1: the UIKit grid in place of the SwiftUI time header and rows. It
    // draws its own pinned time header. Now sits in the guide header next to
    // Earlier/Later (build 22), where Up from the grid's top row lands.
    @ViewBuilder
    private func gridView() -> some View {
        ZStack(alignment: .topLeading) {
            // Not in the first frame: the shell (header, chips) is built and
            // shown first, then the grid, so the first visit is several short
            // frames instead of one long stall.
            if gridReady {
                GuideGridView(rows: rows, rowsVersion: rowsVersion, model: model, origin: model.window,
                    loadedDuration: model.guideLoadedUntil.timeIntervalSince(model.window), clock: clock,
                    scheduled: model.scheduledKeys, recording: model.recordingChannels,
                    request: gridRequest, resetToken: scrollToTop, focusRestoreToken: gridFocusRestore,
                    actions: GuideGridActions(
                        select: { channel, programme in
                            if programme.isLive(at: Date()) { play(channel) }
                            else { selection = GuideSelection(channel: channel, programme: programme) }
                        },
                        play: { play($0) },
                        details: { selection = GuideSelection(channel: $0, programme: $1) },
                        channelOptions: { channelDetails = asChannel($0) },
                        schedule: { schedule = $0 },
                        focusChanged: { channel, start in
                            let value = GuideFocus(channel: channel, start: start)
                            gridFocus = value
                            lastChannel = model.guideChannel(id: channel)?.identityKey ?? channel
                        },
                        viewportChanged: { setViewport($0) },
                        leaveUp: { headerNowFocused = true }))
                    .focused($gridHasFocus)
            }
            if model.guideBusy && model.guide.isEmpty {
                ProgressView("Loading guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && !model.guideBusy && !model.guideHasMore && model.guideError == nil {
                ContentUnavailableView(filter == "favourites" ? "No favourites yet" : "No matching channels",
                    systemImage: filter == "favourites" ? "heart" : "magnifyingglass",
                    description: Text(filter == "favourites" ? "Choose a channel, then Details to add it to favourites." : "Try another category or search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
    }

    private var focusedDetail: String {
        if let programme = focusedProgramme {
            let times = "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
            if let description = programme.description, !description.isEmpty { return "\(times) • \(description)" }
            return times
        }
        #if os(tvOS)
        return "Select to watch • Options for programme details and favourites"
        #else
        return "Tap a programme on now to watch, a later one for details • Touch and hold for options"
        #endif
    }

    private func header(compact: Bool) -> some View {
        Group {
            #if os(tvOS)
            // The TV is always wide enough, and ViewThatFits builds and
            // measures both layouts: part of the first visit's stall.
            regularHeader
            #else
            // 18 Oct (test team): an iPhone in portrait fitted the regular header, so "Search" kept its text and
            // wrapped onto a second line. Compact widths always take the icon-only header.
            if compact {
                phoneHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    regularHeader
                    phoneHeader
                }
            }
            #endif
        }
    }

    private var regularHeader: some View {
        PigPageHeader(title: "TV Guide",
                      subtitle: Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))) {
            if usesGridView {
                Button("Now", systemImage: "location.fill") { goTo(Date()) }
                    .focused($headerNowFocused)
            }
            if !usesOnNowList {
                Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
                Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
            }
            Button("Search", systemImage: "magnifyingglass") { searching = true }
            if !usesOnNowList {
                Button("Jump to…", systemImage: "calendar") { jumpDate = viewport; choosingDate = true }
            }
        }
    }

    /// Landscape phone: title, date, the category menu and icon-only controls
    /// in a single row.
    private var slimBar: some View {
        HStack(spacing: 10) {
            Text("TV Guide").font(.headline)
            Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            filterMenu
            Group {
                if usesGridView {
                    Button("Now", systemImage: "location.fill") { goTo(Date()) }
                }
                if !usesOnNowList {
                    Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
                    Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
                }
                Button("Search", systemImage: "magnifyingglass") { searching = true }
                if !usesOnNowList {
                    Button("Jump to…", systemImage: "calendar") { jumpDate = viewport; choosingDate = true }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.horizontal, 24)
    }

    #if !os(tvOS)
    // Phone layout: icon-only controls so nothing wraps.
    private var phoneHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The shared header (16 Oct); the controls go icon-only so nothing wraps.
            PigPageHeader(title: "TV Guide",
                          subtitle: Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))) {
                // The On now list (A4.4) has no time axis to move.
                if !usesOnNowList {
                    Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
                    Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
                }
                Button("Search", systemImage: "magnifyingglass") { searching = true }
                if !usesOnNowList {
                    Button("Jump to…", systemImage: "calendar") { jumpDate = viewport; choosingDate = true }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }
    #endif

    // Filter chips: a strip clipped to the guide's own width with soft edges on
    // large screens; a compact menu on phones where a strip would be endless.
    @ViewBuilder
    private func filters(compact: Bool) -> some View {
        if compact {
            filterMenu.padding(.horizontal, 24)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    filterButton("All", id: "all")
                    filterButton("Favourites", id: "favourites")
                    ForEach(app.categories) { category in
                        filterButton(category.name, id: category.id)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .clipped()
            .coordinateSpace(name: "categoryStrip")
            .onScrollGeometryChange(for: FilterStripMetrics.self, of: { geometry in
                FilterStripMetrics(offset: max(0, geometry.contentOffset.x + geometry.contentInsets.leading),
                                   viewportWidth: geometry.containerSize.width,
                                   contentWidth: geometry.contentSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing)
            }) { _, metrics in
                filterStripMetrics = metrics
            }
            .padding(.horizontal, 12)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Category", selection: $filter) {
                Text("All").tag("all")
                Text("Favourites").tag("favourites")
                ForEach(app.categories) { category in Text(category.name).tag(category.id) }
            }
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline).lineLimit(1)
        }
    }

    private var filterTitle: String {
        switch filter {
        case "all": return "All channels"
        case "favourites": return "Favourites"
        default: return category?.name ?? "All channels"
        }
    }

    private func filterButton(_ title: String, id: String) -> some View {
        Button { filter = id } label: {
            // No selection checkmark: the pink tint already marks the current
            // category, and a chip that changed width on every tap relaid the
            // whole strip (and its edge fades) under rapid switching (R18).
            Text(title).font(GuideTypography.body).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GuideFilterStyle(selected: filter == id))
        .modifier(CategoryContentFade(width: filterStripMetrics.viewportWidth,
            leading: filterStripMetrics.fadesLeading, trailing: filterStripMetrics.fadesTrailing))
        .accessibilityAddTraits(filter == id ? .isSelected : [])
    }

    private var searchSheet: some View {
        GuideSearchSheet(model: model, search: $search, programmeSearch: $programmeSearch,
                         done: { searching = false },
                         choose: { channel, programme in
                             pendingSelection = GuideSelection(channel: channel, programme: programme)
                             searching = false
                         },
                         refresh: { searching = false; reload() })
    }
    private var datePicker: some View {
        GuideJumpSheet(date: $jumpDate, show: { date in jumped = true; choosingDate = false; goTo(date) },
                       cancel: { choosingDate = false })
    }
    // Start a channel and hand the player the current row order for channel up/down.
    private func play(_ channel: GuideChannel) {
        app.zapList = rows.map(model.asChannel)
        app.beginPlayback(asChannel(channel))
    }
    private func asChannel(_ channel: GuideChannel) -> Channel {
        Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name,
            logo: model.logo(for: channel), category: channel.category, now: nil, next: nil, stableId: channel.stableId,
            number: model.number(for: channel))
    }
    private func scheduleRowsRefresh(after delay: Duration) {
        rowsRefresh?.cancel()
        rowsRefresh = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            refreshRows()
        }
    }
    /// Build 31: what the rows depend on. Appearing again with the same
    /// inputs does not refilter (it used to on every tab switch).
    private var rowsInput: GuideRowsInput {
        GuideRowsInput(count: model.guide.count, first: model.guide.first?.id, last: model.guide.last?.id,
                       loadedAt: model.guideLoadedAt, fromCache: model.fromCache, filter: filter, search: search,
                       favourites: model.favourites.map { "\($0.identityKey)|\($0.id)" }, categories: app.categories.count,
                       programmesVersion: model.guideProgrammesVersion)
    }

    private func refreshRows(force: Bool = false) {
        rowsRefresh?.cancel()
        rowsRefresh = nil
        if filterResetPending {
            filterResetPending = false
            viewport = GuideNavigation.rounded(Date())
            scrollToTop += 1
        }
        let input = rowsInput
        guard force || input != lastRowsInput else { return }
        lastRowsInput = input
        // Favourites match on the stable identity, and a cross-listed channel
        // is shown once in the Favourites filter (server 0097 semantics).
        let guide = model.guide
        let category = category
        let search = search
        let onlyFavourites = filter == "favourites"
        let keys = Set(model.favourites.map(\.identityKey) + model.favourites.map(\.id))
        // Small guides (and the very first rows) are filtered at once; a large
        // guide is filtered off the main actor and published when done, unless
        // newer inputs arrived meanwhile.
        if rows.isEmpty || guide.count < GuideRowsInput.offMainThreshold {
            rows = GuideRowFilter.rows(from: guide, category: category, search: search,
                                       onlyFavourites: onlyFavourites, favouriteKeys: keys)
            rowsVersion += 1
            return
        }
        rowsRefresh = Task { @MainActor in
            let filtered = await Task.detached(priority: .userInitiated) {
                GuideRowFilter.rows(from: guide, category: category, search: search,
                                    onlyFavourites: onlyFavourites, favouriteKeys: keys)
            }.value
            guard !Task.isCancelled, lastRowsInput == input else { return }
            rowsRefresh = nil
            rows = filtered
            rowsVersion += 1
        }
    }
    /// `focusGrid`: Now and Jump to… move focus into the new guide's grid;
    /// Earlier/Later leave it on the header button so repeated presses work
    /// (Down then enters the grid where the focus engine chooses).
    private func goTo(_ date: Date, focusGrid: Bool = true) {
        // The UIKit grid owns its focus and position; it only needs the time.
        gridRequest = GuideGridRequest(viewport: GuideNavigation.rounded(date), focus: focusGrid)
        if focusGrid { claimGridFocus() }
        setViewport(GuideNavigation.rounded(date))
    }
    // Move the visible window; as it approaches the end of the loaded data,
    // extend it forward in the background (no reload, nothing blanks); only
    // a genuine jump outside the loaded range (Jump to…) still reloads, and
    // keeps the grid visible while it does.
    private func setViewport(_ date: Date) {
        if viewport != date { viewport = date }
        if GuideNavigation.needsExtension(viewport: viewport, loadedUntil: model.guideLoadedUntil) {
            Task { await model.extendGuideForward() }
        }
        if GuideNavigation.needsReload(viewport: viewport, loadedFrom: model.window, until: model.guideLoadedUntil) {
            model.window = viewport.addingTimeInterval(-GuideNavigation.leadIn)
            Task { await model.loadGuide(keepVisible: true) }
        }
    }
    private func shift(_ seconds: Double) { goTo(viewport.addingTimeInterval(seconds), focusGrid: false) }
    // The guide error banner's Retry: resumes background paging from where
    // it stopped rather than starting the whole guide over (build 33).
    private func reload() { Task { await model.retryGuide() } }
    /// Moves SwiftUI focus into the UIKit grid; the grid then focuses the
    /// cell it chose (its pending focus). UIKit's own focus requests are
    /// refused while a SwiftUI control holds focus.
    /// Retried briefly: a cover may still be dismissing.
    private func claimGridFocus() {
        // Touch (iPad) has no focus to move.
        #if os(tvOS)
        for delay in [0.0, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if !gridHasFocus { gridHasFocus = true } }
        }
        #endif
    }
    private func finishJump() {
        let showed = jumped
        jumped = false
        guard usesGridView else { return }
        if !showed { gridFocusRestore += 1 }
        claimGridFocus()
    }
    private func finishDetails() {
        if let channel = pendingSchedule {
            pendingSchedule = nil
            // Presented after this cover has gone.
            DispatchQueue.main.async { schedule = channel }
            return
        }
        // Unless a Watch choice is about to open the player (it restores
        // focus when it closes).
        if usesGridView && pendingWatch == nil { gridFocusRestore += 1; claimGridFocus() }
        Task { await model.loadFavourites() }
        if let channel = pendingWatch { pendingWatch = nil; app.beginPlayback(channel) }
    }
}

// Fade the rendered chips, not the scrolling/focus container. No coloured
// paint is laid over the page, and clipped chips remain focusable/scrollable.
private struct CategoryContentFade: ViewModifier {
    let width: CGFloat
    let leading: Bool
    let trailing: Bool
    @State private var origin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("categoryStrip")).minX } action: { origin = $0 }
            .mask(alignment: .leading) {
                if width > 0 {
                    let edge = min(0.5, 36 / width)
                    LinearGradient(stops: [
                        .init(color: leading ? .clear : .black, location: 0),
                        .init(color: .black, location: edge),
                        .init(color: .black, location: 1 - edge),
                        .init(color: trailing ? .clear : .black, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    // The focus ring extends 4 pt outside the chip. Fade only
                    // horizontally; keep its top/bottom inside the mask.
                    .padding(.vertical, -6)
                    .offset(x: -origin)
                } else { Color.black.padding(.vertical, -6) }
            }
    }
}
