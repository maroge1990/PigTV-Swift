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

struct GuideView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: BrowseModel
    @AppStorage("pigtv.guide.filter") private var filter = "all"
    @AppStorage("pigtv.guide.channel") private var lastChannel = ""
    @State private var viewport = GuideNavigation.rounded(Date())
    @State private var programmeSearch = ""
    @State private var pendingSelection: GuideSelection?
    @State private var anchor = Date()
    @State private var clock = Date()
    @State private var search = ""
    @State private var searching = false
    @State private var choosingDate = false
    @State private var jumpDate = Date()
    @State private var selection: GuideSelection?
    @State private var channelDetails: Channel?
    @State private var schedule: GuideChannel?
    @State private var pendingWatch: Channel?
    @State private var retainedFocus: GuideFocus?
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
    @FocusState private var focus: GuideFocus?
    // tvOS: the UIKit grid (GuideGridView, A2.1) is the only grid since
    // build 27. The UIKit grid's focus (it reports it; nothing here assigns it).
    @State private var gridFocus: GuideFocus?
    @State private var gridRequest: GuideGridRequest?
    @State private var rowsVersion = 0
    // Bumped when the player or a details cover closes (the UIKit grid
    // refocuses its last programme or tile).
    @State private var gridFocusRestore = 0
    @FocusState private var gridHasFocus: Bool
    // tvOS: the header's Now button, where Up from the grid's top row
    // lands (the grid hands focus over through `leaveUp`).
    @FocusState private var headerNowFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(iOS)
    // Row pitch (iPad grid). Every tile (logo and programme) is inset by half
    // a gap on each side, so logo→first cell, cell↔cell and row↔row all read
    // as one `GuideMetrics.gap` (R16).
    private let rowHeight: CGFloat = 80
    private static let topAnchor = "guide.top"
    #endif
    private var category: Category? { app.categories.first { $0.id == filter } }
    // The focused grid element.
    private var currentFocus: GuideFocus? {
        if usesGridView { return gridFocus }
        return focus ?? retainedFocus
    }
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
                let channelWidth: CGFloat = compact ? 84 : 176
                let timelineWidth = max(150, geometry.size.width - channelWidth - 48)
                // Phones show one hour (two columns); everything else shows two hours.
                let duration: TimeInterval = compact ? 3600 : GuideNavigation.visibleDuration
                let columns = Int(duration / GuideNavigation.step)
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
                    #if os(tvOS)
                    gridView(channelWidth: channelWidth)
                    #else
                    if usesOnNowList {
                        onNowList
                    } else {
                        timelineGrid(channelWidth: channelWidth, timelineWidth: timelineWidth,
                                     duration: duration, columns: columns, compact: compact)
                    }
                    #endif
                }.padding(.vertical, 12)
            }
            .buttonStyle(GuideFilterStyle())
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    clock = Date()
                }
            }
            .sheet(isPresented: $searching, onDismiss: {
                if let pending = pendingSelection { pendingSelection = nil; selection = pending }
            }) { searchSheet }
            .sheet(isPresented: $choosingDate) { datePicker }
            .task {
                // The guide always opens at the current half-hour; restoring a
                // later browsing position stranded the grid hours ahead.
                viewport = GuideNavigation.rounded(Date())
                anchor = Date()
                // Shared with Home (build 28): whichever appears first loads.
                await model.loadInitialGuide()
                await model.loadFavourites()
                await model.loadRecordings()
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
            .onChange(of: app.playback == nil) { _, closed in
                if closed { focus = retainedFocus; if usesGridView { gridFocusRestore += 1; claimGridFocus() } }
            }
            .fullScreenCover(item: $selection, onDismiss: finishDetails) { item in
                ProgrammeDetails(model: model, channel: item.channel, programme: item.programme) {
                    pendingWatch = asChannel(item.channel)
                    selection = nil
                }
            }
            .fullScreenCover(item: $channelDetails, onDismiss: finishDetails) { channel in
                ChannelDetails(channel: channel, browse: model) {
                    pendingWatch = channel
                    channelDetails = nil
                }
            }
            .fullScreenCover(item: $schedule, onDismiss: finishDetails) { channel in
                ChannelScheduleView(model: model, channel: channel, logo: model.logo(for: channel)) {
                    pendingWatch = asChannel(channel)
                    schedule = nil
                }
            }
        }
    }

    #if os(iOS)
    // The SwiftUI grid: iPad only since build 27 (tvOS uses the UIKit grid,
    // iPhone the On now list). Time header plus lazily built rows.
    @ViewBuilder
    private func timelineGrid(channelWidth: CGFloat, timelineWidth: CGFloat, duration: TimeInterval,
                              columns: Int, compact: Bool) -> some View {
        HStack(spacing: 0) {
            Button("Now", systemImage: "location.fill") { goTo(Date()) }
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .frame(width: channelWidth, alignment: .leading)
            // Labels sit at absolute times and slide with the grid
            // (R14) instead of relabelling fixed columns in place.
            // Each is inset like the cells so it lines up with the
            // leading edge of a half-hour cell.
            let columnWidth = timelineWidth / CGFloat(columns)
            ZStack(alignment: .leading) {
                ForEach(headerTimes(duration: duration), id: \.self) { time in
                    Text(time, style: .time)
                        .font(GuideTypography.small.monospacedDigit())
                        .padding(.leading, GuideMetrics.inset)
                        .frame(width: columnWidth, alignment: .leading)
                        .offset(x: CGFloat(time.timeIntervalSince(viewport) / duration) * timelineWidth)
                }
            }
            .frame(width: timelineWidth, alignment: .leading)
            .clipped()
        }.padding(.horizontal, 24)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    // Stable top anchor: scrolling to it on a category
                    // change reliably returns to the top without
                    // rebuilding the list (the .id(filter) rebuild hung
                    // the focus engine).
                    Color.clear.frame(height: 1).id(Self.topAnchor)
                    ForEach(rows) { channel in
                        guideRow(channel, channelWidth: channelWidth, width: timelineWidth,
                                 duration: duration, compact: compact)
                            .id(channel.id)
                    }
                    if model.guideBusy && model.guide.isEmpty { ProgressView("Loading guide…") }
                    if rows.isEmpty && !model.guideBusy && !model.guideHasMore && model.guideError == nil {
                        ContentUnavailableView(filter == "favourites" ? "No favourites yet" : "No matching channels",
                            systemImage: filter == "favourites" ? "heart" : "magnifyingglass",
                            description: Text(filter == "favourites" ? "Choose a channel, then Details to add it to favourites." : "Try another category or search."))
                    }
                }.padding(.horizontal, 24).padding(.vertical, 5)
            }
            .overlay(alignment: .topLeading) {
                if let offset = nowLineOffset(width: timelineWidth, duration: duration) {
                    Rectangle().fill(Color.accentColor).frame(width: 2)
                        .offset(x: 24 + channelWidth + offset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                shift(value.translation.width < 0 ? duration / 2 : -duration / 2)
            })
            .onChange(of: focus) { _, value in
                // Remember where focus is; the anchor tracks the
                // focused programme's start so Left/Right and the Now
                // button have a stable reference. No focus is
                // reassigned here — doing so fought the focus engine
                // and made the selection jump on its own.
                guard let value else { return }
                if let start = value.start, start > 0,
                   let channel = model.guideChannel(id: value.channel),
                   let programme = channel.programmes.first(where: { $0.startTime == start }) {
                    anchor = max(programme.start, viewport)
                }
                retainedFocus = value
                lastChannel = model.guideChannel(id: value.channel)?.identityKey ?? value.channel
            }
            .onChange(of: filter) {
                // Coalesced: the chip highlight follows every tap at
                // once, but the rows, time window and scroll position
                // change once, after taps settle (R18). Focus stays
                // on the chip; nothing reassigns it here.
                retainedFocus = nil
                filterResetPending = true
                scheduleRowsRefresh(after: .milliseconds(250))
            }
            .onChange(of: scrollToTop) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            .onChange(of: model.guideBusy) { _, busy in
                if !busy, focus == nil, let channel = rows.first(where: { $0.identityKey == lastChannel || $0.id == lastChannel }) {
                    proxy.scrollTo(channel.id)
                }
            }
        }
    }
    #endif

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

    // A2.1: the UIKit grid is the tvOS grid; iOS uses the SwiftUI grid.
    private var usesGridView: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    // A2.1: the UIKit grid in place of the SwiftUI time header and rows. It
    // draws its own pinned time header. Now sits in the guide header next to
    // Earlier/Later (build 22), where Up from the grid's top row lands.
    @ViewBuilder
    private func gridView(channelWidth: CGFloat) -> some View {
        #if os(tvOS)
        ZStack(alignment: .topLeading) {
            GuideGridView(rows: rows, rowsVersion: rowsVersion, model: model, origin: model.window, clock: clock,
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
                        retainedFocus = value
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
            retainedFocus = nil
            gridFocus = nil
            filterResetPending = true
            scheduleRowsRefresh(after: .milliseconds(250))
        }
        #endif
    }

    private var focusedDetail: String {
        if let programme = focusedProgramme {
            let times = "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
            if let description = programme.description, !description.isEmpty { return "\(times) • \(description)" }
            return times
        }
        return "Select to watch • Options for programme details and favourites"
    }

    private func header(compact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
            Image("PigLogo").resizable().scaledToFit().frame(width: 58, height: 48)
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
                Image("PigLogo").resizable().scaledToFit().frame(width: 36, height: 30)
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
        Button { filter = id; retainedFocus = nil } label: {
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

    #if os(iOS)
    private func guideRow(_ channel: GuideChannel, channelWidth: CGFloat, width: CGFloat,
                          duration: TimeInterval, compact: Bool) -> some View {
        let recordingNow = model.recordingChannels.contains(channel.name)
        let flaky = model.isFlaky(channel)
        return HStack(spacing: 0) {
            Button {
                // On a phone the tile opens the channel's programme list (the grid
                // is too narrow to browse); on TV/iPad it starts the channel.
                if compact { schedule = channel } else { play(channel) }
            } label: {
                ChannelTile(name: channel.name, number: model.number(for: channel).map { String($0) },
                            logo: model.logo(for: channel), client: model.client)
                    .frame(width: channelWidth - GuideMetrics.gap, height: rowHeight - GuideMetrics.gap)
                    .overlay(alignment: .topTrailing) {
                        // C-G: an amber dot for an unreliable channel, beside
                        // the recording dot when both apply.
                        HStack(spacing: 4) {
                            if flaky {
                                Circle().fill(Color.orange).frame(width: 12, height: 12)
                                    .accessibilityLabel("Unreliable channel")
                            }
                            if recordingNow {
                                Circle().fill(Color.red).frame(width: 12, height: 12)
                                    .accessibilityLabel("Recording now")
                            }
                        }
                        .padding(6)
                    }
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false))
            .padding(GuideMetrics.inset)
            .focused($focus, equals: GuideFocus(channel: channel.id, start: nil))
            .accessibilityLabel(model.number(for: channel).map { "\($0) \(channel.name)" } ?? channel.name)
            // The button's own label hides its children's, so the dots'
            // meanings are also spoken as its value.
            .accessibilityValue([flaky ? "Unreliable channel" : nil, recordingNow ? "Recording now" : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .contextMenu {
                Button("All programmes on this channel") { schedule = channel }
                Button("Channel and favourites") { channelDetails = asChannel(channel) }
            }
            GuideTimelineRow(channel: channel, caption: model.logo(for: channel) == nil ? nil : channel.name,
                scheduled: model.scheduledKeys,
                viewport: viewport, duration: duration, width: width, height: rowHeight, clock: clock, focus: $focus,
                select: { programme in
                    if programme.isLive(at: Date()) { play(channel) }
                    else { selection = GuideSelection(channel: channel, programme: programme) }
                }, watch: { play(channel) },
                details: { selection = GuideSelection(channel: channel, programme: $0) },
                channelOptions: { channelDetails = asChannel(channel) })
        }
    }

    #endif

    private var searchSheet: some View {
        NavigationStack {
            Form {
                Section("Channels") {
                    TextField("Channel name", text: $search).autocorrectionDisabled()
                    Button("Show matching channels") { searching = false }
                    if !search.isEmpty { Button("Clear channel filter") { search = ""; searching = false } }
                }
                Section("Programmes") {
                    TextField("Programme title", text: $programmeSearch).autocorrectionDisabled()
                    let results = model.searchProgrammes(programmeSearch)
                    if programmeSearch.count >= 2 && results.isEmpty {
                        Text("No upcoming programmes match.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, hit in
                        Button {
                            pendingSelection = GuideSelection(channel: hit.channel, programme: hit.programme)
                            searching = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.programme.title).font(.headline).lineLimit(1)
                                Text("\(hit.channel.name) • \(hit.programme.start.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Refresh guide") { searching = false; reload() }
            }.navigationTitle("Search")
                .presentationBackground { PigPageBackground() }
        }
    }
    private var datePicker: some View {
        NavigationStack {
            Form {
                #if os(tvOS)
                ForEach(0..<7) { day in
                    Button(Calendar.current.date(byAdding: .day, value: day, to: Date())!.formatted(date: .complete, time: .omitted)) {
                        jumpDate = Calendar.current.date(byAdding: .day, value: day, to: Date())!
                    }
                }
                Picker("Hour", selection: Binding(get: { Calendar.current.component(.hour, from: jumpDate) }, set: { hour in
                    jumpDate = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: jumpDate) ?? jumpDate
                })) { ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) } }
                #else
                DatePicker("Date and time", selection: $jumpDate)
                #endif
                Button("Show guide") { choosingDate = false; goTo(jumpDate) }
                Button("Cancel") { choosingDate = false }
            }.navigationTitle("Jump to day and time")
                .presentationBackground { PigPageBackground() }
        }
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
    #if os(iOS)
    // Half-hour marks across the same pre-rendered extent as the grid cells.
    private func headerTimes(duration: TimeInterval) -> [Date] {
        let start = viewport.addingTimeInterval(-GuideMetrics.visualBuffer)
        let count = Int((duration + 2 * GuideMetrics.visualBuffer) / GuideNavigation.step)
        return (0..<count).map { start.addingTimeInterval(Double($0) * GuideNavigation.step) }
    }
    private func nowLineOffset(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        let elapsed = clock.timeIntervalSince(viewport)
        guard elapsed >= 0, elapsed <= duration else { return nil }
        return CGFloat(elapsed / duration) * width
    }
    #endif
    private func scheduleRowsRefresh(after delay: Duration) {
        rowsRefresh?.cancel()
        rowsRefresh = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            refreshRows()
        }
    }
    private func refreshRows() {
        rowsRefresh?.cancel()
        rowsRefresh = nil
        if filterResetPending {
            filterResetPending = false
            viewport = GuideNavigation.rounded(Date())
            anchor = Date()
            scrollToTop += 1
        }
        // Favourites match on the stable identity, and a cross-listed channel
        // is shown once in the Favourites filter (server 0097 semantics).
        rows = GuideRowFilter.rows(from: model.guide, category: category, search: search,
            onlyFavourites: filter == "favourites",
            favouriteKeys: Set(model.favourites.map(\.identityKey) + model.favourites.map(\.id)))
        rowsVersion += 1
    }
    /// `focusGrid`: Now and Jump to… move focus into the new guide's grid;
    /// Earlier/Later leave it on the header button so repeated presses work
    /// (Down then enters the grid where the focus engine chooses).
    private func goTo(_ date: Date, focusGrid: Bool = true) {
        anchor = date
        if usesGridView {
            // The UIKit grid owns its focus; it only needs the time.
            gridRequest = GuideGridRequest(viewport: GuideNavigation.rounded(date), focus: focusGrid)
            if focusGrid { claimGridFocus() }
            setViewport(GuideNavigation.rounded(date))
            return
        }
        setViewport(GuideNavigation.rounded(date), animated: true)
        if let channel = focusedChannel {
            let programme = GuideNavigation.programme(in: channel.programmes, at: date)
            let target = GuideFocus(channel: channel.id, start: programme?.startTime)
            retainedFocus = target
            if focus != nil { focus = target }
        }
    }
    // Move the visible window and, only when it leaves the loaded day, request
    // a new day of programme data around it.
    private func setViewport(_ date: Date, animated: Bool = false) {
        if viewport != date {
            if animated && !reduceMotion {
                withAnimation(.easeInOut(duration: 0.2)) { viewport = date }
            } else {
                viewport = date
            }
        }
        if GuideNavigation.needsReload(viewport: viewport, loadedFrom: model.window) {
            model.window = viewport.addingTimeInterval(-GuideNavigation.leadIn)
            reload()
        }
    }
    private func shift(_ seconds: Double) { goTo(viewport.addingTimeInterval(seconds), focusGrid: false) }
    private func reload() { Task { await model.loadGuide() } }
    /// Moves SwiftUI focus into the UIKit grid; the grid then focuses the
    /// cell it chose (its pending focus). UIKit's own focus requests are
    /// refused while a SwiftUI control holds focus.
    /// Retried briefly: a cover may still be dismissing.
    private func claimGridFocus() {
        for delay in [0.0, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if !gridHasFocus { gridHasFocus = true } }
        }
    }
    private func finishDetails() {
        focus = retainedFocus
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
    // C-A: the channel number ("504"), shown small in the top-leading corner.
    var number: String? = nil
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
        .overlay(alignment: .topLeading) {
            if let number {
                Text(verbatim: number)
                    .font(GuideTypography.small.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .accessibilityHidden(true)
            }
        }
    }
}

// Every programme on one channel from now onwards, for picking something to
// watch or record without steering through the grid.
struct ChannelScheduleView: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let logo: String?
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: GuideSelection?

    private var upcoming: [GuideProgramme] {
        let now = Date()
        return channel.programmes.filter { $0.end > now && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        ChannelArtwork(logo: logo, client: model.client).frame(width: 120, height: 68)
                        Text(channel.name).font(.title2.bold())
                        Spacer()
                    }
                    Button("Watch live", systemImage: "play.fill", action: watch).pigPrimaryButton()
                    if upcoming.isEmpty {
                        Text("No programme information for this channel.").foregroundStyle(.secondary)
                    }
                    ForEach(upcoming, id: \.startTime) { programme in
                        Button { selection = GuideSelection(channel: channel, programme: programme) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(programme.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    if programme.isLive(at: Date()) {
                                        Text("ON NOW").font(.caption.bold()).foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text("\(programme.start.formatted(date: .abbreviated, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let description = programme.description, !description.isEmpty {
                                    Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 14))
                    }
                    Button("Done") { dismiss() }
                }.padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Programmes")
            .presentationBackground { PigPageBackground() }
            .sheet(item: $selection) { item in
                ProgrammeDetails(model: model, channel: channel, programme: item.programme) {
                    selection = nil
                    watch()
                }
            }
        }
    }
}

struct ProgrammeDetails: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var before = 0
    @State private var after = 0
    @State private var scheduled = false
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(channel.name).font(.headline).foregroundStyle(Color.accentColor)
                    Text(programme.title).font(.largeTitle.bold())
                    Text("\(programme.start.formatted(date: .abbreviated, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                    if let description = programme.description, !description.isEmpty {
                        Text(description)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { time in
                        VStack(alignment: .leading, spacing: 20) {
                            if programme.isLive(at: time.date) {
                                Button("Watch channel live", systemImage: "play.fill", action: watch)
                                    .pigPrimaryButton()
                            }
                            if programme.end > time.date && !scheduled {
                                Picker("Start early", selection: $before) {
                                    ForEach([0, 1, 2, 5, 10], id: \.self) { Text("\($0) minutes").tag($0) }
                                }
                                Picker("Finish late", selection: $after) {
                                    ForEach([0, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                                }
                                Button("Schedule recording", systemImage: "record.circle") { confirming = true }
                                    .disabled(model.mutationBusy)
                            } else if scheduled {
                                Label("Recording scheduled", systemImage: "checkmark.circle.fill")
                            } else {
                                Text("This programme has ended. Catch-up playback is not available.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.mutationBusy { ProgressView("Saving…") }
                    if let error = model.actionError { Text(error).foregroundStyle(.secondary) }
                    Button("Done") { dismiss() }.disabled(model.mutationBusy)
                }.padding(40).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Programme")
            .presentationBackground { PigPageBackground() }
            .interactiveDismissDisabled(model.mutationBusy)
            .confirmationDialog("Schedule this recording?", isPresented: $confirming) {
                Button("Schedule recording") {
                    Task { scheduled = await model.schedule(channel: channel, programme: programme, before: before, after: after) }
                }
            } message: {
                Text("PigTV has one provider stream. Recording may need live playback to stop. If the programme has already started, only the remaining portion can be recorded.")
            }
            .onAppear { model.actionError = nil }
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

// Category chips share the app's pink language: focus is the bright pink
// outline + translucent pink fill; the current category keeps a quieter pink
// tint so it stays legible when focus moves elsewhere. Same treatment in both
// appearances (accent is identical; the neutral rest state adapts).
private struct GuideFilterStyle: ButtonStyle {
    var selected = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GuideTypography.body)
            .foregroundStyle(selected && !focused ? Color.accentColor : Color.primary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(focused ? Color.accentColor.opacity(0.22)
                        : selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(focused ? Color.accentColor
                    : selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: focused ? 3 : 1)
            }
    }
}

enum GuideMetrics {
    // The single guide spacing: between the logo tile and the first cell,
    // between cells in a row, and between rows.
    static let gap: CGFloat = 8
    static var inset: CGFloat { gap / 2 }
    // How far either side of the window cells (and header labels) are drawn
    // off screen. Wider than any single navigation step, including a return
    // to live from a few windows ahead.
    static let visualBuffer: TimeInterval = 6 * 3600
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

#if os(iOS)
// One row of the iPad grid. Only programmes overlapping the visible window are
// built; everything else stays as plain data in the model. A day of
// programme data therefore costs nothing on screen, and the row never
// becomes wider than its visible frame (the previous full-day scroll layers
// were large enough to bring down the render server).
private struct GuideTimelineRow: View {
    let channel: GuideChannel
    // Channel name shown on the first visible cell when the tile carries a logo.
    let caption: String?
    let scheduled: Set<String>
    let viewport: Date
    let duration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    let clock: Date
    let focus: FocusState<GuideFocus?>.Binding
    let select: (GuideProgramme) -> Void
    let watch: () -> Void
    let details: (GuideProgramme) -> Void
    let channelOptions: () -> Void
    @Environment(\.colorScheme) private var scheme

    // Points per second of the timeline.
    private var scale: CGFloat { width / CGFloat(duration) }
    // Absolute x of a time relative to the current viewport (can be negative /
    // beyond width; the row is clipped).
    private func x(_ time: Date) -> CGFloat { CGFloat(time.timeIntervalSince(viewport)) * scale }

    var body: some View {
        let visible = GuideNavigation.visible(channel.programmes, viewport: viewport, duration: duration)
        // The channel name rides the now-playing cell, not the first visible
        // one (which is often a finished programme half off the left edge).
        let captionStart = visible.first { $0.isLive(at: clock) }?.startTime ?? visible.first?.startTime
        // Visual extent: programmes well beyond the window on both sides, so
        // the row reads as one wide guide of which only the window is visible
        // and cells slide in from off screen rather than appearing (R14).
        // LazyVStack builds only visible rows, so this stays bounded.
        let buffered = GuideNavigation.visible(channel.programmes,
            viewport: viewport.addingTimeInterval(-GuideMetrics.visualBuffer),
            duration: duration + 2 * GuideMetrics.visualBuffer)
        ZStack(alignment: .leading) {
            Color.clear
            if visible.isEmpty {
                Button("No programme information — watch live", action: watch)
                    .font(GuideTypography.body).buttonStyle(PigSurfaceButtonStyle())
                    .frame(width: width - 2 * edge, height: height - GuideMetrics.gap)
                    .focused(focus, equals: GuideFocus(channel: channel.id, start: -1))
                    .offset(x: edge)
            }
            // Visual layer — slides as one block; never focusable, so its
            // off-screen geometry cannot mislead the focus engine.
            ForEach(buffered, id: \.startTime) { programme in
                let cellWidth = max(1, CGFloat(programme.end.timeIntervalSince(programme.start)) * scale - GuideMetrics.gap)
                let start = x(programme.start)
                cellVisual(programme, caption: programme.startTime == captionStart ? caption : nil,
                           // Keep the title on screen when the cell starts to the
                           // left of the window, without pushing it off the right.
                           hiddenLeading: min(max(0, -start), max(0, cellWidth - 160)))
                    .frame(width: cellWidth, height: height - GuideMetrics.gap)
                    .offset(x: start + GuideMetrics.inset)
            }
            .allowsHitTesting(false)
            // Focus layer — transparent buttons clamped to the visible window,
            // so every focus target's frame is on screen and Up/Down/Left/Right
            // stay geometrically correct while the visuals slide underneath.
            // A sliver too thin to focus is left out.
            ForEach(visible, id: \.startTime) { programme in
                if let span = GuideGeometry.interval(start: programme.startTime, end: programme.endTime,
                    window: viewport.timeIntervalSince1970 * 1000, duration: duration * 1000) {
                    let lower = max(edge, width * span.offset + GuideMetrics.inset)
                    let upper = min(width - edge, width * (span.offset + span.width) - GuideMetrics.inset)
                    if upper - lower >= 8 {
                        focusCell(programme)
                            .frame(width: upper - lower, height: height - GuideMetrics.gap)
                            .offset(x: lower)
                    }
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    // Drawn cell. Highlight is driven by the focus binding (not @Environment
    // isFocused) because this view is not the focusable element.
    private func cellVisual(_ programme: GuideProgramme, caption: String?, hiddenLeading: CGFloat) -> some View {
        let focused = focus.wrappedValue == GuideFocus(channel: channel.id, start: programme.startTime)
        let finished = programme.end <= clock
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let caption { Text(caption).lineLimit(1).layoutPriority(1) }
                Text(programme.start, style: .time)
                if scheduled.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime)) {
                    Image(systemName: "record.circle.fill").foregroundStyle(Color.red)
                }
            }
            .font(GuideTypography.small).foregroundStyle(.secondary).lineLimit(1)
            Text(programme.title).font(GuideTypography.body).lineLimit(caption == nil ? 2 : 1)
            if programme.isLive(at: clock) {
                ProgressView(value: min(1, max(0, clock.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start))))
                    .tint(.accentColor).scaleEffect(x: 1, y: 0.4).frame(height: 4)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12 + hiddenLeading).padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(focused ? Color.accentColor.opacity(0.22) : Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.accentColor : .clear, lineWidth: 3) }
        .opacity(finished ? 0.4 : 1)
        .clipped()
    }

    // Margin at each end of the row.
    private var edge: CGFloat { GuideMetrics.inset }

    // Transparent focus/hit target for one programme.
    private func focusCell(_ programme: GuideProgramme) -> some View {
        Button { select(programme) } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(GuideFocusCellStyle())
            .disabled(programme.end <= clock)
            .focused(focus, equals: GuideFocus(channel: channel.id, start: programme.startTime))
            .contextMenu {
                Button("Programme details") { details(programme) }
                Button("Channel and favourites", action: channelOptions)
            }
            .accessibilityLabel("\(channel.name), \(programme.title)")
    }
}

// The focus layer must be invisible (the visual layer draws the highlight), so
// this style renders nothing but the clear label.
private struct GuideFocusCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif


// Lets a label style be chosen at runtime (SwiftUI's styles are distinct types).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}


extension Color {
    // Guide surfaces: clearly separated from the page in both appearances.
    static func guideCell(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.11)
    }
    // Neutral translucent logo backing: darker in light mode so the tile is
    // clearly separated from the page, lighter grey in dark mode and over video.
    static func logoTile(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.42).opacity(0.38) : Color(white: 0.22).opacity(0.42)
    }
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
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
