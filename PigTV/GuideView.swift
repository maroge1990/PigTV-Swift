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
    @ObservedObject var model: BrowseModel
    @AppStorage("pigtv.guide.filter") private var filter = "all"
    @AppStorage("pigtv.guide.channel") private var lastChannel = ""
    @State private var viewport = GuideNavigation.rounded(Date())
    @State private var programmeSearch = ""
    @State private var pendingSelection: GuideSelection?
    @State private var clock = Date()
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
    @State private var lastRowsInput: GuideRowsInput?
    // Bumped when the player or a details cover closes (the UIKit grid
    // refocuses its last programme or tile).
    @State private var gridFocusRestore = 0
    @FocusState private var gridHasFocus: Bool
    // tvOS: the header's Now button, where Up from the grid's top row
    // lands (the grid hands focus over through `leaveUp`).
    @FocusState private var headerNowFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var category: Category? { app.categories.first { $0.id == filter } }
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
                let compact = geometry.size.width < 700
                VStack(alignment: .leading, spacing: 10) {
                    header(compact: compact)
                    filters(compact: compact)
                    if !compact {
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
                }.padding(.vertical, 12)
            }
            .buttonStyle(GuideFilterStyle())
            // The app's page behind the guide (build 28): tvOS otherwise
            // shows its blurred system backdrop in dark mode.
            .pigPageBackdrop()
            .task {
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
            .task {
                // Periodic refresh keeps the loaded day current during long sessions.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                    await model.refreshGuideIfStale()
                    await model.loadRecordings()
                }
            }
            .onAppear { refreshRows() }
            // Background paging adds 50 channels at a time; refresh at most a
            // few times a second rather than once per page.
            .onChange(of: model.guide.count) {
                // Throttle, not debounce: pages can arrive faster than the
                // interval, and the first page should appear at once.
                if rows.isEmpty { refreshRows() }
                else if rowsRefresh == nil { scheduleRowsRefresh(after: .milliseconds(400)) }
            }
            .onChange(of: model.favourites.count) { refreshRows() }
            .onChange(of: search) { refreshRows() }
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
        .onChange(of: filter) {
            // As the SwiftUI grid (R18): coalesced; the grid returns to the
            // top row and the live baseline once taps settle.
            gridFocus = nil
            filterResetPending = true
            scheduleRowsRefresh(after: .milliseconds(250))
        }
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
        ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
            PigBrandMark(width: 58, height: 48)
                .accessibilityLabel("PigTV")
            Text("TV Guide").font(GuideTypography.title)
            Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(GuideTypography.body).foregroundStyle(.secondary)
            Spacer()
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
        // Phone layout: icon-only controls so nothing wraps.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PigBrandMark(width: 36, height: 30)
                Text("TV Guide").font(.headline)
                Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
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
        }.padding(.horizontal, 24)
    }

    // Filter chips: a strip clipped to the guide's own width with soft edges on
    // large screens; a compact menu on phones where a strip would be endless.
    @ViewBuilder
    private func filters(compact: Bool) -> some View {
        if compact {
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
            .padding(.horizontal, 24)
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
                       favourites: model.favourites.map(\.id), categories: app.categories.count,
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

// Logo tile for the channel column. The logo replaces the channel name; the
// name is only drawn here when no artwork is available.
struct ChannelTile: View {
    let name: String
    // Build 29: no channel number on the tile (Mark: it obscured logos and
    // is not important to him); numbers appear only as muted text beside a
    // channel's name (`ChannelNumberText`).
    let logo: String?
    let client: APIClient?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // The only app-provided artwork backing: one neutral translucent
            // tile, the same for every channel, with the logo inset so it
            // never touches the tile edge.
            RoundedRectangle(cornerRadius: 10).fill(Color.logoTile(scheme))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                Text(name).font(GuideTypography.small.weight(.semibold)).lineLimit(3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RetryBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.callout)
            Spacer()
            Button("Retry", action: retry)
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
    }
}

enum GuideMetrics {
    // The single guide spacing: between the logo tile and the first cell,
    // between cells in a row, and between rows.
    static let gap: CGFloat = 8
    static var inset: CGFloat { gap / 2 }
}

enum GuideTypography {
    static var body: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .subheadline
        #endif
    }
    static var small: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .caption
        #endif
    }
    static var title: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title3.bold()
        #endif
    }
}

// Lets a label style be chosen at runtime (SwiftUI's styles are distinct types).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}


extension Color {
    // Guide surfaces: clearly separated from the page in both appearances.
    static func guideCell(_ scheme: ColorScheme) -> Color {
        Color.pigRaised
    }
    // Neutral translucent logo backing: darker in light mode so the tile is
    // clearly separated from the page, lighter grey in dark mode and over video.
    static func logoTile(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.42).opacity(0.38) : Color(white: 0.22).opacity(0.42)
    }
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        Color.pigCanvas
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
                    .frame(width: width).offset(x: -origin)
                } else { Color.black }
            }
    }
}
