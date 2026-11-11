import SwiftUI

/// D-44 (Apple 107): what the long-press menu is open on, and where (window coordinates).
struct GuideMenuTarget {
    let channel: GuideChannel
    let programme: GuideProgramme?
    let subject: ProgrammeMenuSubject
    let anchor: CGRect
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
    @State private var clock = Date()
    /// Jump to's Show guide: the time to show once the Guide is back on screen (the page has popped).
    @State private var pendingJump: Date?
    /// The tool that opened the Search page, where a pop puts focus back (Show guide then moves the grid).
    private enum PageTool: Hashable { case search, jump }
    @FocusState private var pageToolFocus: PageTool?
    /// D-44 (#49, Apple 108): the pages pushed on the Guide's NavigationStack (programme details, …).
    @State private var path: [GuideRoute] = []
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
    /// D-44 (Apple 107): the long-press menu card, open beside a programme.
    @State private var menu: GuideMenuTarget?
    /// #257: the live event whose channels "Watch on…" lists.
    @State private var watchOn: SportEvent?
    /// #219: what failed in the iPhone's On now menu (the system menu has closed, so it cannot show it).
    @State private var onNowError: String?
    /// iPad: where the strip's More button is (the card opens beside it).
    @State private var stripMoreFrame: CGRect = .zero
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

    /// D-44 (Apple 106): the categories the chosen chip shows (nil: All or Favourites).
    private var filterCategories: [Category]? { GuideChips.categories(for: filter, in: app.categories) }
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
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                #if os(tvOS)
                // Never compact on the TV. The reader's first pass has zero
                // size, which read as compact and built the phone menu only to
                // throw it away (part of the first visit's stall).
                let compact = false
                #else
                let compact = geometry.size.width < 700
                #endif
                let state = pageState
                VStack(alignment: .leading, spacing: slim ? PigSpacing.xs : PigSpacing.s) {
                    Group {
                        if slim {
                            slimBar
                        } else {
                            header(compact: compact)
                            // #280: the guide failed: the header, then the error (no strip or chips over nothing).
                            if state.failure == nil {
                                staleNotice(state)
                                // D-44 (Apple 106): the slim focus strip, then the chips and the tools, above the grid.
                                if !compact { focusStrip.padding(.horizontal, PigSpacing.l) }
                                filters(compact: compact)
                            }
                        }
                    }
                    // The menu card holds focus while it is open.
                    .disabled(menu != nil)
                    if slim { staleNotice(state) }
                    if let failure = state.failure {
                        // #280 (R1): retried by the app's next freshness pass (its countdown), or now.
                        ScrollView {
                            PigErrorState(failure: failure, retry: { await model.retryGuide() }, identifier: "guide.error",
                                          schedule: guideStore.schedule)
                                .pigStateFillsPage()
                        }
                    } else if usesOnNowList {
                        // Build 29: the UIKit grid on iPad too (free touch
                        // scrolling there); iPhone keeps the On now list.
                        onNowList(state)
                    } else {
                        gridView(state)
                    }
                }
                // No top inset under the header: it sits at the same corner on every tab (PigPageHeader).
                .padding(.top, slim ? PigSpacing.xs : 0).padding(.bottom, slim ? PigSpacing.xs : PigSpacing.s)
            }
            .overlay {
                if let menu {
                    ProgrammeMenuOverlay(subject: menu.subject, anchor: menu.anchor, now: Date(),
                                         actions: ProgrammeMenuActions { await runMenu($0, menu) }, close: closeMenu)
                }
            }
            // #257: the channels carrying the live event, best first; choosing one plays it there.
            .confirmationDialog("Watch on", isPresented: Binding(get: { watchOn != nil }, set: { if !$0 { watchOn = nil } }),
                                titleVisibility: .visible, presenting: watchOn) { event in
                ForEach(WatchOn.onAir(event, now: Date()).channels) { channel in
                    Button(WatchOn.label(channel)) {
                        if let current = WatchOn.play(event, on: channel, now: Date()) {
                            app.playSportEvent(current, channel: channel, origin: "TV Guide")
                        }
                    }
                    .accessibilityIdentifier("watchOn.\(channel.id)")
                }
                Button("Cancel", role: .cancel) {}
            } message: { event in Text(event.title) }
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
                if model.sportEnabled { await model.sport.loadIfStale() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    clock = Date()
                    // Audit F6: the long-press menu's Watch on… reads these; at most ~5 minutes old while the Guide is up.
                    if model.sportEnabled { await model.sport.loadIfStale() }
                }
            }
            .task {
                // The guide always opens at the current half-hour; restoring a
                // later browsing position stranded the grid hours ahead.
                viewport = GuideNavigation.rounded(Date())
                // Shared with Home (build 28): whichever appears first loads.
                await model.loadInitialGuide()
                // Build 31: not on every appearance, only when stale.
                await model.loadFavouritesIfStale()
                await model.loadRecordingsIfStale()
                // #257: the long-press menu's Watch on… needs the sport events (the Sport tab may not have loaded them).
                if model.sportEnabled { await model.sport.loadIfStale() }
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
            // Apple 163: the categories can arrive after the rows (161 loads them in the background)
            .onChange(of: app.categories.count) { refreshRows() }
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
            // Jump to's Show guide: once the page has popped, the grid moves there and takes focus. On the TV that is when
            // the pop has put focus back on the tool that opened the page (taking it before then loses it to that
            // restoration); touch has no focus, so there it is when the Guide is back on screen.
            #if os(tvOS)
            .onChange(of: pageToolFocus) { _, tool in
                if tool != nil, let date = pendingJump { pendingJump = nil; goTo(date) }
            }
            #else
            .onAppear {
                if let date = pendingJump { pendingJump = nil; goTo(date) }
            }
            #endif
            .navigationDestination(for: GuideRoute.self) { route in destination(route) }
            .closesForOutsidePlay { path = []; menu = nil } // #179
        }
    }

    /// #280: what the page shows: the model's state, or E1 when the chosen chip leaves no channels.
    private var pageState: PageState {
        PageState.guideRows(model.guideState, rowsEmpty: rows.isEmpty, paging: model.guideHasMore)
    }

    /// #280 (R1): channels on screen whose refresh (or a later page) failed: they stay, with the slim notice.
    @ViewBuilder
    private func staleNotice(_ state: PageState) -> some View {
        if state.isStale {
            PigStaleNotice(since: state.staleSince, retry: { await model.retryGuide() }, identifier: "guide.stale")
                .padding(.horizontal, PigSpacing.l)
        }
    }

    /// #280 (E1): no channels, no favourites, or none in the chosen category; the filters' one action shows them all.
    private var guideEmpty: some View {
        let words = PageWords.guideEmpty(filter: filter, channels: model.guide.count)
        return PigEmptyState(title: words.title, text: words.text,
                             action: words.showsAll ? PigStateAction(label: PageWords.showAllChannels) { filter = "all" } : nil,
                             identifier: "guide.empty")
    }

    // A4.4, D-44: the iPhone upright shows the "On now" list instead of the
    // grid; sideways (compact height) and the iPad keep the grid.
    private var usesOnNowList: Bool {
        #if os(iOS)
        GuideLayout.usesOnNowList(compactWidth: sizeClass == .compact, compactHeight: verticalSizeClass == .compact)
        #else
        false
        #endif
    }

    @ViewBuilder
    private func onNowList(_ state: PageState) -> some View {
        #if os(iOS)
        if state == .loading {
            OnNowPlaceholder()
        } else if state.showsEmpty {
            ScrollView { guideEmpty.pigStateFillsPage() }
        } else {
            OnNowList(rows: rows, model: model, clock: clock, play: { play($0) }, info: { openChannel($0) },
                      menu: { channel in menuSubject(channel, OnNowRow.make(programmes: channel.programmes, now: Date()).current) },
                      choose: { channel, programme, item in
                          let target = GuideMenuTarget(channel: channel, programme: programme,
                                                       subject: menuSubject(channel, programme), anchor: .zero)
                          // #219 (Apple 123): the system menu has closed by now, so a failure is said in an alert.
                          Task {
                              guard let error = await runMenu(item, target) else { return }
                              try? await Task.sleep(for: .milliseconds(350)) // the menu's closing animation
                              onNowError = error
                          }
                      })
            .alert("That didn\u{2019}t work", isPresented: Binding(get: { onNowError != nil }, set: { if !$0 { onNowError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(onNowError ?? "")
            }
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
    private func gridView(_ state: PageState) -> some View {
        ZStack(alignment: .topLeading) {
            // Not in the first frame: the shell (header, chips) is built and
            // shown first, then the grid, so the first visit is several short
            // frames instead of one long stall.
            if gridReady {
                GuideGridView(rows: rows, rowsVersion: rowsVersion, model: model, origin: model.window,
                    loadedDuration: model.guideLoadedUntil.timeIntervalSince(model.window), clock: clock,
                    scheduled: model.scheduledKeys, recording: model.recordingChannels,
                    request: gridRequest, resetToken: scrollToTop, focusRestoreToken: gridFocusRestore,
                    menuOpen: menu != nil,
                    actions: GuideGridActions(
                        select: { channel, programme in
                            if programme.isLive(at: Date()) { play(channel) }
                            else { open(channel, programme) }
                        },
                        play: { play($0) },
                        focusChanged: { channel, start in
                            let value = GuideFocus(channel: channel, start: start)
                            gridFocus = value
                            lastChannel = model.guideChannel(id: channel)?.identityKey ?? channel
                        },
                        viewportChanged: { setViewport($0) },
                        leaveUp: { headerNowFocused = true },
                        menu: { openMenu($0, $1, anchor: $2) }))
                    .focused($gridHasFocus)
                    // #280: kept (it is built once) but not drawn while its shape stands in for it.
                    .opacity(state == .loading ? 0 : 1)
            }
            switch state {
            case .loading:
                GuideGridPlaceholder()
            case .empty, .emptyStale:
                ScrollView { guideEmpty.pigStateFillsPage() }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, PigSpacing.l)
    }

    private var stripHint: String {
        #if os(tvOS)
        "Select a programme on now to watch, a later one for details"
        #else
        "Tap a programme on now to watch, a later one for details · Touch and hold for options"
        #endif
    }

    /// What the strip says: the focused programme (or tile) from the loaded guide and the schedule marks.
    private var stripText: GuideStripText {
        let channel = focusedChannel
        let programme = focusedProgramme
        let scheduled = channel.flatMap { c in programme.map { marks.scheduledKeys.contains(ScheduledRecording.key(channel: c.name, start: $0.startTime)) } } ?? false
        return GuideStripText.make(channel: channel?.name, number: channel.flatMap { model.number(for: $0) },
                                   programme: programme,
                                   current: programme == nil ? channel.flatMap { OnNowRow.make(programmes: $0.programmes, now: clock).current } : nil,
                                   scheduled: scheduled, recordingNow: channel.map { marks.recordingChannels.contains($0.name) } ?? false,
                                   now: clock, hint: stripHint)
    }

    private var focusStrip: some View {
        GuideFocusStrip(text: stripText) {
            if model.guideHasMore && model.guideError == nil {
                ProgressView()
                Text("\(model.guide.count) of \(model.guideTotal) channels")
                    .font(GuideTypography.small).foregroundStyle(Color.pigSecondary).pigFigures()
            }
            #if os(tvOS)
            Text("Long press for options").font(.system(size: PigType.caption)).foregroundStyle(Color.pigSecondary).fixedSize()
                .accessibilityIdentifier("guide.strip.hint")
            #endif
            if let programme = focusedProgramme, let channel = focusedChannel {
                Button("Details", systemImage: "info.circle") { open(channel, programme) }
                .pigSecondaryButton()
                .accessibilityIdentifier("guide.strip.details")
                #if os(iOS)
                // D-44 (Apple 107): touch has no long press on the strip; its … opens the same menu.
                Button { openMenu(channel, programme, anchor: stripMoreFrame) } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 28, minHeight: 28)
                }
                .accessibilityLabel("More for this programme")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripMoreFrame = $0 }
                #endif
            }
        }
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
        // D-44 (Apple 106): the tools moved beside the chips (`tools`).
        PigPageHeader(title: "TV Guide",
                      subtitle: PigHeaderDate.text(viewport))
    }

    /// Now, Earlier, Later, Search and Jump to… at the end of the chip row (R5-Guide-TV). Up from the grid's top row
    /// lands on Now (`leaveUp`).
    @ViewBuilder
    private var tools: some View {
        Button { goTo(Date()) } label: { GuideToolLabel(title: "Now", systemImage: "location.fill") }
            .focused($headerNowFocused)
        Button { shift(-GuideNavigation.step) } label: { GuideToolLabel(title: "Earlier", systemImage: "chevron.left") }
        Button { shift(GuideNavigation.step) } label: { GuideToolLabel(title: "Later", systemImage: "chevron.right", trailingIcon: true) }
        Button { path.append(.search(jump: false)) } label: { GuideToolLabel(title: "Search", systemImage: "magnifyingglass") }
            .focused($pageToolFocus, equals: .search)
        Button { path.append(.search(jump: true)) } label: { GuideToolLabel(title: "Jump to…", systemImage: "calendar") }
            .focused($pageToolFocus, equals: .jump)
    }

    /// Landscape phone: title, date, the category menu and icon-only controls
    /// in a single row.
    private var slimBar: some View {
        HStack(spacing: PigSpacing.s) {
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
                Button("Search", systemImage: "magnifyingglass") { path.append(.search(jump: false)) }
                if !usesOnNowList {
                    Button("Jump to…", systemImage: "calendar") { path.append(.search(jump: true)) }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            // #280: 44 pt to touch (brand 1.8 §16); `.small` drew them about 28 pt
            .controlSize(.large)
        }
        .padding(.horizontal, PigSpacing.l)
    }

    #if !os(tvOS)
    // Phone layout: icon-only controls so nothing wraps.
    private var phoneHeader: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            // The shared header (16 Oct); the controls go icon-only so nothing wraps.
            PigPageHeader(title: "TV Guide",
                          subtitle: PigHeaderDate.text(viewport)) {
                // The On now list (A4.4) has no time axis to move.
                if !usesOnNowList {
                    Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
                    Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
                }
                Button("Search", systemImage: "magnifyingglass") { path.append(.search(jump: false)) }
                if !usesOnNowList {
                    Button("Jump to…", systemImage: "calendar") { path.append(.search(jump: true)) }
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
            filterMenu.padding(.horizontal, PigSpacing.l)
        } else {
            HStack(spacing: PigSpacing.s) {
            ScrollView(.horizontal) {
                HStack(spacing: PigSpacing.s) {
                    ForEach(GuideChips.make(categories: app.categories)) { chip in
                        filterButton(chip)
                    }
                }.padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.s)
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
            if usesGridView {
                HStack(spacing: PigSpacing.s) { tools }
                    .buttonStyle(GuideFilterStyle())
                    #if os(tvOS)
                    .focusSection()
                    #endif
            }
            }
            .padding(.horizontal, PigSpacing.s)
            .padding(.trailing, PigSpacing.s)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Category", selection: $filter) {
                ForEach(GuideChips.make(categories: app.categories)) { chip in Text(chip.title).tag(chip.id) }
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
        default: return GuideChips.make(categories: app.categories).first { GuideChips.isSelected($0, filter: filter, in: app.categories) }?.title ?? "All channels"
        }
    }

    private func filterButton(_ chip: GuideChip) -> some View {
        let selected = GuideChips.isSelected(chip, filter: filter, in: app.categories)
        let title = chip.title
        return Button { filter = chip.id } label: {
            // No selection checkmark: the pink tint already marks the current
            // category, and a chip that changed width on every tap relaid the
            // whole strip (and its edge fades) under rapid switching (R18).
            Text(title).font(GuideTypography.body).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GuideFilterStyle(selected: selected))
        .modifier(CategoryContentFade(width: filterStripMetrics.viewportWidth,
            leading: filterStripMetrics.fadesLeading, trailing: filterStripMetrics.fadesTrailing))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // Start a channel and hand the player the current row order for channel up/down.
    private func play(_ channel: GuideChannel) {
        app.zapList = rows.map(model.asChannel)
        app.beginPlayback(asChannel(channel), origin: "guide")
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
                       loadedAt: model.guideLoadedAt, fromCache: model.fromCache, filter: filter, search: "",
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
        let categories = filterCategories
        // D-44 (Apple 110): Search is its own page now; the rows are no longer filtered by channel name.
        let search = ""
        let onlyFavourites = filter == "favourites"
        let keys = Set(model.favourites.map(\.identityKey) + model.favourites.map(\.id))
        // Small guides (and the very first rows) are filtered at once; a large
        // guide is filtered off the main actor and published when done, unless
        // newer inputs arrived meanwhile.
        if rows.isEmpty || guide.count < GuideRowsInput.offMainThreshold {
            rows = GuideRowFilter.rows(from: guide, categories: categories, search: search,
                                       onlyFavourites: onlyFavourites, favouriteKeys: keys)
            rowsVersion += 1
            return
        }
        rowsRefresh = Task { @MainActor in
            let filtered = await Task.detached(priority: .userInitiated) {
                GuideRowFilter.rows(from: guide, categories: categories, search: search,
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
    /// Moves SwiftUI focus into the UIKit grid; the grid then focuses the
    /// cell it chose (its pending focus). UIKit's own focus requests are
    /// refused while a SwiftUI control holds focus. #49 (Apple 110): once,
    /// with no timed retries: the Guide's pages are pushed, not covers, so
    /// nothing is still dismissing when this runs.
    private func claimGridFocus() {
        // Touch (iPad) has no focus to move.
        #if os(tvOS)
        gridHasFocus = true
        #endif
    }
    // MARK: Pages (D-44, #49)

    /// Pushes a programme's page.
    private func open(_ channel: GuideChannel, _ programme: GuideProgramme) {
        path.append(.programme(channel: channel.id, start: programme.startTime))
    }

    /// Pushes a channel's page (D-44, Apple 109: the schedule and "Channel and favourites" in one).
    private func openChannel(_ channel: GuideChannel) {
        path.append(.channel(channel.id))
    }

    /// A page's Watch: back to the grid, then the player (it closes onto the grid).
    private func watchFromPage(_ channel: GuideChannel) {
        path = []
        play(channel)
    }

    @ViewBuilder
    private func destination(_ route: GuideRoute) -> some View {
        switch route {
        case .programme(let id, let start):
            if let channel = model.guideChannel(id: id), let programme = channel.programmes.first(where: { $0.startTime == start }) {
                ProgrammeDetails(model: model, presenter: app.presenter, channel: channel, programme: programme,
                                 watch: { watchFromPage(channel) }, openSchedule: { openChannel(channel) },
                                 openProgramme: { open(channel, $0) }, pushedFrom: "TV Guide")
            } else {
                missingPage
            }
        case .channel(let id):
            if let channel = model.guideChannel(id: id) {
                ChannelPageView(model: model, presenter: app.presenter, channel: channel, watch: { watchFromPage(channel) },
                            openProgramme: { open(channel, $0) }, pushedFrom: "TV Guide")
            } else {
                missingPage
            }
        case .search(let jump):
            GuideSearchPage(model: model, date: viewport, canJump: usesGridView, startWithJump: jump,
                            openChannel: { openChannel($0) }, openProgramme: { open($0, $1) },
                            showGuide: { date in pendingJump = date; path = [] }, pushedFrom: "TV Guide")
        }
    }

    /// A route whose channel or programme has left the loaded guide (a refresh moved on past it).
    private var missingPage: some View {
        DetailPage(pushedFrom: "TV Guide") {
            Text("This is no longer in the guide.").font(DetailType.meta).foregroundStyle(Color.pigSecondary)
        }
    }

    // MARK: The long-press menu (D-44, Apple 107)

    private func menuSubject(_ channel: GuideChannel, _ programme: GuideProgramme?) -> ProgrammeMenuSubject {
        ProgrammeMenuSubject(channelName: channel.name, programme: programme,
                             recordingStatus: programme.flatMap { model.activeSchedule(channel: channel, programme: $0)?.statusWord },
                             canWatchFromStart: programme.flatMap { model.recordingInProgress(channel: channel, programme: $0) } != nil,
                             isFavourite: model.isFavourite(asChannel(channel)),
                             watchOnChannels: liveEvent(channel, programme).map { WatchOn.onAir($0, now: Date()).channels.count } ?? 0)
    }

    /// #257: the live sport event this programme is, when the server has sport events (several channels may carry it).
    private func liveEvent(_ channel: GuideChannel, _ programme: GuideProgramme?) -> SportEvent? {
        guard model.sportEnabled, let programme else { return nil }
        return WatchOn.event(in: model.sport.events, sourceId: channel.sourceId, rawID: channel.rawID,
                             stableId: channel.stableId, programme: programme, now: Date())
    }

    private func openMenu(_ channel: GuideChannel, _ programme: GuideProgramme?, anchor: CGRect) {
        withAnimation(PigMotion.standard) {
            menu = GuideMenuTarget(channel: channel, programme: programme, subject: menuSubject(channel, programme), anchor: anchor)
        }
    }

    /// Closes the card; focus goes back to the programme it was opened on (the grid takes focus again once its cells
    /// can: `menuOpen` false, then the restore token).
    private func closeMenu() {
        guard menu != nil else { return }
        withAnimation(PigMotion.standard) { menu = nil }
        if usesGridView {
            gridFocusRestore += 1
            #if os(tvOS)
            gridHasFocus = true
            #endif
        }
    }

    /// What a menu item does on the Guide; nil when it worked (the card closes), else the error to show in the card.
    private func runMenu(_ item: ProgrammeMenuItem, _ target: GuideMenuTarget) async -> String? {
        let channel = target.channel
        switch item {
        case .recordThis:
            guard let programme = target.programme else { return nil }
            guard await model.schedule(channel: channel, programme: programme, before: nil, after: nil) else {
                return model.actionError ?? "The recording could not be scheduled."
            }
            closeMenu()
        case .changeRecording:
            // Apple 114: the record page as Change recording (its padding; Cancel recording there, with Undo).
            closeMenu()
            if let programme = target.programme { app.presenter.present(.record(model.recordRequest(channel: channel, programme: programme))) }
        case .recordEvery:
            guard let programme = target.programme else { return nil }
            guard await model.addRule(RuleBody(kind: "series", match: programme.title, sourceId: channel.sourceId,
                                               channelId: channel.rawID, channelName: channel.name, newOnly: true)) else {
                return model.actionError ?? "The rule could not be added."
            }
            closeMenu()
        case .moreOptions:
            closeMenu()
            if let programme = target.programme { app.presenter.present(.record(model.recordRequest(channel: channel, programme: programme))) }
        case .watchOn:
            let event = liveEvent(channel, target.programme)
            closeMenu()
            watchOn = event
        case .watchFromStart:
            closeMenu()
            if let programme = target.programme, let recording = model.recordingInProgress(channel: channel, programme: programme) {
                app.presenter.present(.recordingPlayer(recording))
            }
        case .details:
            closeMenu()
            if let programme = target.programme { open(channel, programme) }
        case .schedule:
            closeMenu()
            openChannel(channel)
        case .favourite(_, let isFavourite):
            guard await model.setFavourite(asChannel(channel), !isFavourite) else { return "Favourites could not be changed." }
            closeMenu()
        }
        return nil
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
                        .init(color: leading ? .clear : Color.pigMediaCanvas, location: 0),
                        .init(color: Color.pigMediaCanvas, location: edge),
                        .init(color: Color.pigMediaCanvas, location: 1 - edge),
                        .init(color: trailing ? .clear : Color.pigMediaCanvas, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    // The focus ring extends 4 pt outside the chip. Fade only
                    // horizontally; keep its top/bottom inside the mask.
                    .padding(.vertical, -PigFocus.clearance)
                    .offset(x: -origin)
                } else { Color.pigMediaCanvas.padding(.vertical, -PigFocus.clearance) }
            }
    }
}
