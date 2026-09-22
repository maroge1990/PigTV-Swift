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
    @State private var choosingOptions = false
    @State private var choosingDate = false
    @State private var jumpDate = Date()
    @State private var selection: GuideSelection?
    @State private var channelDetails: Channel?
    @State private var schedule: GuideChannel?
    @State private var pendingWatch: Channel?
    @State private var retainedFocus: GuideFocus?
    @State private var navigationGeneration = UUID()
    @State private var filterStripMetrics = FilterStripMetrics()
    // Filtered rows are cached: filtering hundreds of channels inside `body`
    // on every focus change or clock tick is what made scrolling stutter.
    @State private var rows: [GuideChannel] = []
    @FocusState private var focus: GuideFocus?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rowHeight: CGFloat = 76
    private var category: Category? { app.categories.first { $0.id == filter } }
    private var focusedChannel: GuideChannel? {
        guard let key = (focus ?? retainedFocus) else { return nil }
        return model.guide.first { $0.id == key.channel }
    }
    private var focusedProgramme: GuideProgramme? {
        guard let start = (focus ?? retainedFocus)?.start else { return nil }
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
                            Button("Details", systemImage: "text.expand") {
                                selection = GuideSelection(channel: channel, programme: programme)
                            }
                        }
                        Button("Options", systemImage: "ellipsis.circle") { showOptions() }
                            .disabled(focusedChannel == nil)
                    }.frame(height: 78, alignment: .top).padding(.horizontal, 24)
                    }
                    if let error = model.guideError {
                        RetryBanner(message: error) { reload() }
                    }
                    HStack(spacing: 0) {
                        Button("Now", systemImage: "location.fill") { goTo(Date()) }
                            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                            .frame(width: channelWidth, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(0..<columns, id: \.self) { step in
                                Text(viewport.addingTimeInterval(Double(step) * GuideNavigation.step), style: .time)
                                    .font(GuideTypography.small.monospacedDigit())
                                    .frame(width: timelineWidth / CGFloat(columns), alignment: .leading)
                            }
                        }
                        .frame(width: timelineWidth, alignment: .leading)
                    }.padding(.horizontal, 24)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 4) {
                                ForEach(rows) { channel in
                                    guideRow(channel, channelWidth: channelWidth, width: timelineWidth,
                                             duration: duration, compact: compact)
                                        .id(channel.id)
                                }
                                if model.guideBusy && model.guide.isEmpty { ProgressView("Loading guide…") }
                                if rows.isEmpty && !model.guideBusy && !model.guideHasMore && model.guideError == nil {
                                    ContentUnavailableView(filter == "favourites" ? "No favourites yet" : "No matching channels",
                                        systemImage: filter == "favourites" ? "heart" : "magnifyingglass",
                                        description: Text(filter == "favourites" ? "Choose a channel, then Options to add it to favourites." : "Try another category or search."))
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
                        #if os(iOS)
                        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                            shift(value.translation.width < 0 ? duration / 2 : -duration / 2)
                        })
                        #endif
                        .onChange(of: focus) { _, value in
                            // Remember where focus is; the anchor tracks the
                            // focused programme's start so Left/Right and the Now
                            // button have a stable reference. No focus is
                            // reassigned here — doing so fought the focus engine
                            // and made the selection jump on its own.
                            guard let value else { return }
                            if let start = value.start, start > 0,
                               let channel = model.guide.first(where: { $0.id == value.channel }),
                               let programme = channel.programmes.first(where: { $0.startTime == start }) {
                                anchor = max(programme.start, viewport)
                            }
                            retainedFocus = value
                            lastChannel = value.channel
                        }
                        .onChange(of: filter) {
                            // A new category starts at its first channel, at the
                            // live baseline, with focus claimed so the remote is
                            // never left with nothing focusable. The scroll and
                            // focus are deferred so the rebuilt rows are laid out
                            // first — otherwise scrollTo targeted the old list.
                            refreshRows()
                            viewport = GuideNavigation.rounded(Date())
                            anchor = Date()
                            retainedFocus = nil
                            focus = nil
                            let first = rows.first
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(30))
                                guard let first, rows.contains(where: { $0.id == first.id }) else { return }
                                proxy.scrollTo(first.id, anchor: .top)
                                let live = GuideNavigation.programme(in: first.programmes, at: Date())
                                let target = GuideFocus(channel: first.id, start: live?.startTime ?? -1)
                                retainedFocus = target
                                focus = target
                            }
                        }
                        .onChange(of: model.guideBusy) { _, busy in
                            if !busy, focus == nil, let channel = rows.first(where: { $0.id == lastChannel }) {
                                proxy.scrollTo(channel.id)
                            }
                        }
                    }
                }.padding(.vertical, 12)
            }
            .buttonStyle(GuideFilterStyle())
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    clock = Date()
                }
            }
            .confirmationDialog("Options", isPresented: $choosingOptions) {
                if let channel = focusedChannel {
                    if let programme = focusedProgramme {
                        Button("Programme details and recording") { selection = GuideSelection(channel: channel, programme: programme) }
                    }
                    Button("All programmes on \(channel.name)") { schedule = channel }
                    Button("Channel and favourites") { channelDetails = asChannel(channel) }
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
                if model.guide.isEmpty {
                    await model.loadCachedGuide()
                    if model.guide.isEmpty || model.fromCache {
                        if !model.fromCache { model.window = viewport.addingTimeInterval(-GuideNavigation.leadIn) }
                        await model.loadGuide(reset: true, keepVisible: model.fromCache)
                    }
                }
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
            .onChange(of: model.guide.count) { refreshRows() }
            .onChange(of: model.favourites.count) { refreshRows() }
            .onChange(of: search) { refreshRows() }
            .onChange(of: app.playback == nil) { _, closed in
                if closed { focus = retainedFocus }
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
            Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
            Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
            Button("Search", systemImage: "magnifyingglass") { searching = true }
            Button("Jump to…", systemImage: "calendar") { jumpDate = viewport; choosingDate = true }
        }
        // Phone layout: icon-only controls so nothing wraps.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image("PigLogo").resizable().scaledToFit().frame(width: 36, height: 30)
                Text("TV Guide").font(.headline)
                Text(viewport, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Earlier", systemImage: "chevron.left") { shift(-GuideNavigation.step) }
                Button("Later", systemImage: "chevron.right") { shift(GuideNavigation.step) }
                Button("Search", systemImage: "magnifyingglass") { searching = true }
                Button("Jump to…", systemImage: "calendar") { jumpDate = viewport; choosingDate = true }
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
            HStack(spacing: 6) {
                if filter == id { Image(systemName: "checkmark") }
                Text(title)
            }.font(GuideTypography.body).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GuideFilterStyle(selected: filter == id))
        .modifier(CategoryContentFade(width: filterStripMetrics.viewportWidth,
            leading: filterStripMetrics.fadesLeading, trailing: filterStripMetrics.fadesTrailing))
        .accessibilityAddTraits(filter == id ? .isSelected : [])
    }

    private func guideRow(_ channel: GuideChannel, channelWidth: CGFloat, width: CGFloat,
                          duration: TimeInterval, compact: Bool) -> some View {
        let recordingNow = model.recordingChannels.contains(channel.name)
        return HStack(spacing: 0) {
            Button {
                // On a phone the tile opens the channel's programme list (the grid
                // is too narrow to browse); on TV/iPad it starts the channel.
                if compact { schedule = channel } else { play(channel) }
            } label: {
                ChannelTile(name: channel.name, logo: model.logo(for: channel), client: model.client)
                    .frame(width: channelWidth, height: rowHeight)
                    .overlay(alignment: .topTrailing) {
                        if recordingNow {
                            Circle().fill(Color.red).frame(width: 12, height: 12).padding(6)
                                .accessibilityLabel("Recording now")
                        }
                    }
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false))
            .focused($focus, equals: GuideFocus(channel: channel.id, start: nil))
            .accessibilityLabel(channel.name)
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
        #if os(tvOS)
        .onMoveCommand { direction in navigate(direction, channel: channel, duration: duration) }
        #endif
    }

    #if os(tvOS)
    // Only Left/Right are intercepted: they may need to shift the viewport to a
    // programme that is not drawn yet. Up/Down are left entirely to the focus
    // engine — every cell frame is on screen (cells are clipped to the window),
    // so its geometric choice of the row above/below is already correct.
    private func navigate(_ direction: MoveCommandDirection, channel: GuideChannel, duration: TimeInterval) {
        guard direction == .left || direction == .right,
              let current = focus, current.channel == channel.id else { return }
        let baseline = GuideNavigation.rounded(clock)
        let programmes = channel.programmes.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        // A live programme while the grid is ahead of now brings the grid back
        // to the live baseline (Left) before anything else.
        let focusedProgramme = current.start.flatMap { start in programmes.first { $0.startTime == start } }
        if direction == .left, viewport > baseline,
           focusedProgramme == nil || focusedProgramme!.isLive(at: clock) {
            returnToLive(channel: channel, programmes: programmes, baseline: baseline)
            return
        }
        guard let start = current.start, let index = programmes.firstIndex(where: { $0.startTime == start }) else {
            if direction == .right, current.start == -1 { shift(GuideNavigation.step) }
            return
        }
        let visible = GuideNavigation.visible(programmes, viewport: viewport, duration: duration)
        let nextIndex = index + (direction == .right ? 1 : -1)
        guard programmes.indices.contains(nextIndex) else {
            // Nothing earlier to reveal: hand focus to the channel tile so the
            // remote can leave the timeline to the left (and reach favourites).
            if direction == .left { setFocus(GuideFocus(channel: channel.id, start: nil)) }
            else { shift(GuideNavigation.step) }
            return
        }
        let next = programmes[nextIndex]
        // Finished programmes cannot be played, so the remote never walks back
        // into them; Left instead returns to live, or drops to the channel tile
        // when already at the baseline.
        if direction == .left, next.end <= clock {
            if viewport > baseline { returnToLive(channel: channel, programmes: programmes, baseline: baseline) }
            else { setFocus(GuideFocus(channel: channel.id, start: nil)) }
            return
        }
        let destination = direction == .left
            ? GuideNavigation.revealMovingLeft(next, from: viewport, now: clock)
            : GuideNavigation.reveal(next, from: viewport, duration: duration)
        if destination == viewport, visible.contains(where: { $0.startTime == next.startTime }) { return }
        anchor = max(next.start, destination)
        move(to: destination, focusing: GuideFocus(channel: channel.id, start: next.startTime))
    }

    private func returnToLive(channel: GuideChannel, programmes: [GuideProgramme], baseline: Date) {
        let live = GuideNavigation.programme(in: programmes, at: clock)
        anchor = clock
        move(to: baseline, focusing: GuideFocus(channel: channel.id, start: live?.startTime ?? -1))
    }

    // Moves the grid and keeps focus on the chosen cell. The focus engine
    // performs its own move after the move-command handler (to the channel
    // tile when nothing is drawn to the left), so ours is re-applied once
    // that has happened.
    private func move(to destination: Date, focusing target: GuideFocus) {
        let generation = UUID()
        navigationGeneration = generation
        setViewport(destination, animated: true)
        focus = target
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard navigationGeneration == generation, viewport == destination else { return }
            if focus != target { focus = target }
        }
    }
    #endif

    // Re-applies focus after the engine's own post-handler move, without
    // touching the viewport (used by vertical steps, tile hand-off and category
    // changes). Shared so the category reset can claim focus on every platform.
    private func setFocus(_ target: GuideFocus) {
        let generation = UUID()
        navigationGeneration = generation
        focus = target
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard navigationGeneration == generation else { return }
            if focus != target { focus = target }
        }
    }

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
            logo: model.logo(for: channel), category: channel.category, now: nil, next: nil)
    }
    private func nowLineOffset(width: CGFloat, duration: TimeInterval) -> CGFloat? {
        let elapsed = clock.timeIntervalSince(viewport)
        guard elapsed >= 0, elapsed <= duration else { return nil }
        return CGFloat(elapsed / duration) * width
    }
    private func refreshRows() {
        let favourites = Set(model.favourites.map(\.id))
        let category = self.category
        let search = self.search
        let onlyFavourites = filter == "favourites"
        rows = model.guide.filter { channel in
            (!onlyFavourites || favourites.contains(channel.id)) &&
            (category.map { channel.matches($0) } ?? true) &&
            (search.isEmpty || channel.name.localizedStandardContains(search))
        }
    }
    private func goTo(_ date: Date) {
        anchor = date
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
    private func shift(_ seconds: Double) { goTo(viewport.addingTimeInterval(seconds)) }
    private func reload() { Task { await model.loadGuide() } }
    private func showOptions() {
        choosingOptions = true
    }
    private func finishDetails() {
        focus = retainedFocus
        Task { await model.loadFavourites() }
        if let channel = pendingWatch { pendingWatch = nil; app.beginPlayback(channel) }
    }
}

// Logo tile for the channel column. The logo replaces the channel name; the
// name is only drawn here when no artwork is available.
private struct ChannelTile: View {
    let name: String
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
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        }
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
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

// Chips read correctly in both appearances: the selected chip inverts the
// primary colour instead of assuming a dark background.
private struct GuideFilterStyle: ButtonStyle {
    var selected = false
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let inverted = scheme == .dark ? Color.black : Color.white
        configuration.label
            .font(GuideTypography.body)
            .foregroundStyle(focused ? Color.black : selected ? inverted : Color.primary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(focused ? Color.accentColor : selected ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
    }
}

private enum GuideTypography {
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

// One row of the grid. Only programmes overlapping the visible window are
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

    var body: some View {
        let visible = GuideNavigation.visible(channel.programmes, viewport: viewport, duration: duration)
        // Cells are clipped to the visible window so every focusable frame sits
        // on screen: that is what keeps the focus engine's Up/Down honest (an
        // off-screen frame made it drop to the logo of the row below). The
        // channel name rides the now-playing cell, not the first visible one,
        // which is often a finished programme scrolled half off the left edge.
        let captionStart = visible.first { $0.isLive(at: clock) }?.startTime ?? visible.first?.startTime
        ZStack(alignment: .leading) {
            Color.clear
            if visible.isEmpty {
                Button("No programme information — watch live", action: watch)
                    .font(GuideTypography.body).buttonStyle(PigSurfaceButtonStyle())
                    .frame(width: width, height: height)
                    .focused(focus, equals: GuideFocus(channel: channel.id, start: -1))
            }
            ForEach(visible, id: \.startTime) { programme in
                if let span = GuideGeometry.interval(start: programme.startTime, end: programme.endTime,
                    window: viewport.timeIntervalSince1970 * 1000, duration: duration * 1000) {
                    programmeButton(programme, cellWidth: max(1, width * span.width - 4),
                        caption: programme.startTime == captionStart ? caption : nil)
                        .offset(x: width * span.offset + 2)
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    private func programmeButton(_ programme: GuideProgramme, cellWidth: CGFloat, caption: String?) -> some View {
        Button { select(programme) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let caption { Text(caption).lineLimit(1).layoutPriority(1) }
                    Text(programme.start, style: .time)
                    if scheduled.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime)) {
                        Image(systemName: "record.circle.fill").foregroundStyle(Color.red)
                            .accessibilityLabel("Recording scheduled")
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
            .padding(.horizontal, 12)
            .frame(width: cellWidth, height: height - 4, alignment: .leading)
            .clipped()
        }
        .buttonStyle(PigSurfaceButtonStyle())
        // Finished programmes cannot be played or recorded: keep them for
        // context, but out of the focus path and visibly in the past.
        .disabled(programme.end <= clock)
        .opacity(programme.end <= clock ? 0.4 : 1)
        .focused(focus, equals: GuideFocus(channel: channel.id, start: programme.startTime))
        .contextMenu {
            Button("Programme details") { details(programme) }
            Button("Channel and favourites", action: channelOptions)
        }
        .accessibilityLabel("\(channel.name), \(programme.title)")
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
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.11)
    }
    // Neutral translucent logo backing: darker in light mode so the tile is
    // clearly separated from the page, lighter grey in dark mode and over video.
    static func logoTile(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.42).opacity(0.38) : Color(white: 0.30).opacity(0.30)
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
