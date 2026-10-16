import SwiftUI

/// Sizes for the Recordings page (tvOS tiles match Home's cards).
private enum RecordingsMetrics {
    #if os(tvOS)
    static let pagePadding: CGFloat = 40
    static let tileMinWidth: CGFloat = 260
    static let tileMaxWidth: CGFloat = 320
    static let rowTileWidth: CGFloat = 260
    static let spacing: CGFloat = 30
    static let title: Font = .system(size: 22, weight: .semibold)
    static let detail: Font = .system(size: 18)
    #else
    static let pagePadding: CGFloat = 20
    static let tileMinWidth: CGFloat = 150
    static let tileMaxWidth: CGFloat = 240
    static let rowTileWidth: CGFloat = 170
    static let spacing: CGFloat = 14
    static let title: Font = .subheadline.weight(.semibold)
    static let detail: Font = .caption
    #endif
    static let radius: CGFloat = 14
    static let artRatio: CGFloat = 1.7
}

/// A failed library recording or a failed/missed schedule, for the
/// "needs attention" list.
private enum AttentionItem: Identifiable {
    case schedule(ScheduledRecording)
    case recording(Recording)
    var id: String {
        switch self {
        case .schedule(let item): "schedule-\(item.id)"
        case .recording(let item): "recording-\(item.id)"
        }
    }
}

struct RecordingsView: View {
    /// Not observed (audit R05): it draws the recordings store and the
    /// action state, and nothing else BrowseModel holds.
    let model: BrowseModel
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var selected: Recording?
    @State private var cancellation: ScheduledRecording?
    @State private var section = "library"
    @State private var search = ""
    @State private var reviewing = false
    @Environment(\.colorScheme) private var scheme

    init(model: BrowseModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    private var failed: [Recording] { RecordingsRows.failedRecordings(model.recordings, schedules: model.schedules) }

    /// Everything but the failed ones, which the banner owns.
    private var filtered: [Recording] {
        model.recordings.filter { $0.status != "failed" }.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                ($0.channel_name?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var problems: [ScheduledRecording] { RecordingsRows.problemSchedules(model.schedules) }

    private var continueWatching: [Recording] {
        search.isEmpty ? RecordingsRows.continueWatching(model.recordings) { model.progress(for: $0) } : []
    }

    private var attentionTitle: String? {
        RecordingsRows.attentionTitle(failedSchedules: problems.filter { $0.status == "failed" }.count,
                                      missedSchedules: problems.filter { $0.status == "missed" }.count,
                                      failedRecordings: failed.count)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: RecordingsMetrics.tileMinWidth, maximum: RecordingsMetrics.tileMaxWidth),
                  spacing: RecordingsMetrics.spacing, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PigPageHeader(title: "Recordings").padding(.horizontal, RecordingsMetrics.pagePadding)
                #if !os(tvOS)
                sectionPicker
                #endif
                if let error = model.recordingsError {
                    RetryBanner(message: error) { Task { await model.loadRecordings() } }
                }
                if let message = model.actionMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.actionError { Text(error).foregroundStyle(.secondary).padding(.horizontal) }
                if section == "library" { library } else { scheduled }
                if model.recordingsBusy { ProgressView("Refreshing recordings…") }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .pigPageBackdrop()
            // Build 31: only when older than a minute. The tvOS remote has no
            // pull-to-refresh, so there it reloads on every appearance
            // (anything older than 10 s).
            #if os(tvOS)
            .task { await model.loadRecordingsIfStale(maxAge: 10) }
            #else
            .task { await model.loadRecordingsIfStale() }
            #endif
            // Review F6: while the page is on screen it keeps itself current, so a
            // recording that starts, finishes or fails shows without a remote press.
            // Quiet (no spinner, unchanged rows are not republished); it stops when
            // the page is not visible.
            .whileVisible {
                while !Task.isCancelled {
                    let wait = RecordingsRows.refreshInterval(recordings: model.recordings, schedules: model.schedules, now: Date())
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    await model.loadRecordings(quietly: true)
                }
            }
            .fullScreenCover(item: $selected) { item in RecordingDetails(model: model, original: item) }
            .sheet(isPresented: $reviewing) { RecordingAttentionSheet(model: model) }
            .confirmationDialog("Cancel this recording?", isPresented: Binding(
                get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
            ), presenting: cancellation) { item in
                Button(item.status == "recording" ? "Stop recording" : "Cancel schedule", role: .destructive) {
                    Task { await model.cancel(item) }
                }
            } message: { item in
                Text("\(item.title). If it is already recording, it will stop. The recorded portion will be kept.")
            }
        }
    }

    private var sectionPicker: some View {
        Picker("View", selection: $section) {
            Text("Library").tag("library")
            Text("Scheduled").tag("scheduled")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, RecordingsMetrics.pagePadding)
    }

    // MARK: Library

    private var searchField: some View {
        TextField("Search recordings", text: $search)
            .padding(.horizontal, RecordingsMetrics.pagePadding)
    }

    private var library: some View {
        VStack(spacing: 12) {
            #if !os(tvOS)
            searchField
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    #if os(tvOS)
                    // The TV has no pull-to-refresh and its focus lifts rows
                    // under anything pinned above them, so the controls scroll
                    // away with the content.
                    VStack(spacing: 12) { sectionPicker; searchField }
                        .padding(.horizontal, -RecordingsMetrics.pagePadding)
                    #endif
                    if let title = attentionTitle {
                        AttentionBanner(title: title) { reviewing = true }
                    }
                    if !continueWatching.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            PigSectionHeader(title: "Continue watching")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: RecordingsMetrics.spacing) {
                                    ForEach(continueWatching) { item in
                                        tile(item).frame(width: RecordingsMetrics.rowTileWidth)
                                    }
                                }
                                .padding(.vertical, 12).padding(.horizontal, 4)
                            }
                            .scrollClipDisabled()
                        }
                        .tvFocusSection()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        PigSectionHeader(title: "All recordings")
                        if filtered.isEmpty && !model.recordingsBusy {
                            Text(search.isEmpty ? "No recordings yet. Choose a programme in Guide to schedule one." : "No matching recordings.")
                                .foregroundStyle(.secondary).padding(.vertical, 8)
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: RecordingsMetrics.spacing) {
                                ForEach(filtered) { item in tile(item) }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .tvFocusSection()
                }
                .padding(.horizontal, RecordingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
            #if !os(tvOS)
            .refreshable { await model.loadRecordings() }
            #endif
        }
    }

    private func tile(_ item: Recording) -> some View {
        RecordingTile(item: item, progress: model.progress(for: item), client: model.client) { selected = item }
    }

    // MARK: Scheduled

    private var scheduled: some View {
        List {
            #if os(tvOS)
            sectionPicker
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            #endif
            ForEach(model.schedules.filter { $0.isActive }) { item in
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                    Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit()).fontDesign(.rounded)
                    Text(item.statusLabel).font(.caption.bold())
                    if item.canCancel {
                        Button(item.status == "recording" ? "Stop recording" : "Cancel schedule", role: .destructive) {
                            cancellation = item
                        }.disabled(model.mutationBusy)
                    }
                }
                .scheduleSurface(scheme)
            }
            if !problems.isEmpty {
                Section("Recent problems") {
                    ForEach(problems) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title).font(.headline)
                                Spacer()
                                Text(item.status.capitalized).font(.caption.bold())
                                    .foregroundStyle(item.status == "missed" ? Color.pigWarning : Color.pigDanger)
                            }
                            Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                            Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption.monospacedDigit()).fontDesign(.rounded)
                            if let error = item.error {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .scheduleSurface(scheme)
                        #if os(tvOS)
                        // No action, but focusable so the focus engine can scroll to it.
                        .focusable()
                        #endif
                    }
                }
            }
        }
        #if !os(tvOS)
        .scrollContentBackground(.hidden) // brand 1.6: rows sit on the page canvas and corner bloom
        .refreshable { await model.loadRecordings() }
        #endif
        .overlay {
            if !model.schedules.contains(where: \.isActive) && !model.recordingsBusy && problems.isEmpty {
                Text("Nothing scheduled. Browse Guide to choose a programme.")
                    .foregroundStyle(.secondary).padding()
            }
        }
    }
}

private extension View {
    /// A scheduled-recording row: the same raised surface and corner radius as a
    /// recording tile, sitting straight on the page canvas.
    func scheduleSurface(_ scheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: RecordingsMetrics.radius))
            .listRowInsets(EdgeInsets(top: 6, leading: RecordingsMetrics.pagePadding, bottom: 6, trailing: RecordingsMetrics.pagePadding))
            .listRowBackground(Color.clear)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
    }
}

// MARK: Poster tile

/// One recording as a poster: the channel's logo on the guide's tile colour
/// (never a frame grab, which could spoil a result), the title, "Channel ·
/// duration", and a progress bar when partly watched.
private struct RecordingTile: View {
    let item: Recording
    let progress: RecordingProgress
    let client: APIClient
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var detail: String {
        var parts = [item.channel_name ?? "Channel unavailable"]
        if let duration = item.duration_sec, duration > 0 { parts.append(DetailText.duration(duration)) }
        return parts.joined(separator: " · ")
    }

    private var label: String {
        var parts = [item.title, item.channel_name ?? "channel unavailable"]
        if let duration = item.duration_sec, duration > 0 { parts.append(DetailText.duration(duration)) }
        if item.status == "recording" { parts.append("recording now") }
        else if item.isPreparingForPlayback { parts.append("preparing for playback") }
        else if progress.watched { parts.append("watched") }
        else if let fraction = progress.fraction { parts.append("\(Int((fraction * 100).rounded())) percent watched") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                art
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(RecordingsMetrics.title).lineLimit(1)
                    PigProgressBar(fraction: progress.fraction ?? 0)
                        .opacity(progress.fraction == nil ? 0 : 1)
                    if item.isPreparingForPlayback {
                        Text("Preparing for playback…").font(RecordingsMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(detail).font(RecordingsMetrics.detail.monospacedDigit()).fontDesign(.rounded)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(12)
                .opacity(progress.watched ? 0.6 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: RecordingsMetrics.radius))
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: RecordingsMetrics.radius))
        .accessibilityLabel(label)
    }

    private var art: some View {
        Color.logoTile(scheme)
            .aspectRatio(RecordingsMetrics.artRatio, contentMode: .fit)
            .overlay {
                Group {
                    if item.channel_logo != nil {
                        ChannelArtwork(logo: item.channel_logo, client: client).padding(.horizontal, 24).padding(.vertical, 14)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.pigAccent)
                    }
                }
                .opacity(progress.watched ? 0.45 : 1)
            }
            .overlay(alignment: .topLeading) {
                if item.status == "recording" {
                    CardBadge(text: "Live", systemImage: "record.circle.fill", colour: .pigDanger).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if progress.watched {
                    CardBadge(text: "Watched", systemImage: "checkmark", colour: .gray).padding(8)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Needs attention

/// "N recordings failed" with a Review action.
private struct AttentionBanner: View {
    let title: String
    let review: () -> Void
    var body: some View {
        Button(action: review) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.pigWarning)
                Text(title).font(RecordingsMetrics.title)
                Spacer()
                Text("Review").font(RecordingsMetrics.title).foregroundStyle(Color.pigAccentText)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: RecordingsMetrics.radius))
        .accessibilityLabel("\(title). Review")
    }
}

/// The failed and missed items, each with a Delete (confirmed).
private struct RecordingAttentionSheet: View {
    let model: BrowseModel
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var deleting: AttentionItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(model: BrowseModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    private var items: [AttentionItem] {
        RecordingsRows.problemSchedules(model.schedules).map(AttentionItem.schedule)
            + RecordingsRows.failedRecordings(model.recordings, schedules: model.schedules).map(AttentionItem.recording)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    row(item)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: RecordingsMetrics.radius))
                        .listRowBackground(Color.clear)
                        #if os(iOS)
                        .listRowSeparator(.hidden)
                        #endif
                }
                if items.isEmpty {
                    Text("Nothing needs attention.").foregroundStyle(.secondary)
                }
                if let error = model.actionError { Text(error).font(.callout).foregroundStyle(.secondary) }
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .navigationTitle("Needs attention")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .pigPageBackdrop()
            .toolbar {
                #if !os(tvOS)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                #endif
            }
            .confirmationDialog("Delete this item?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { item in
                Button("Delete", role: .destructive) { Task { await delete(item) } }
                Button("Keep it", role: .cancel) {}
            } message: { item in
                Text("This removes \(title(item)) and any partial file from the server.")
            }
        }
    }

    private func title(_ item: AttentionItem) -> String {
        switch item {
        case .schedule(let value): value.title
        case .recording(let value): value.title
        }
    }

    private func delete(_ item: AttentionItem) async {
        switch item {
        case .schedule(let value): await model.deleteSchedule(value)
        case .recording(let value): await model.delete(value)
        }
        if items.isEmpty { dismiss() }
    }

    @ViewBuilder
    private func row(_ item: AttentionItem) -> some View {
        let heading = title(item)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading).font(.headline)
                Spacer()
                switch item {
                case .schedule(let value):
                    Text(value.status.capitalized).font(.caption.bold())
                        .foregroundStyle(value.status == "missed" ? Color.pigWarning : Color.pigDanger)
                case .recording:
                    Text("Failed").font(.caption.bold()).foregroundStyle(Color.pigDanger)
                }
            }
            switch item {
            case .schedule(let value):
                Text(value.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                Text("\(value.start.formatted(date: .abbreviated, time: .shortened)) – \(value.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit()).fontDesign(.rounded)
                if let error = value.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            case .recording(let value):
                Text(value.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                if let date = value.started { Text(date, style: .date).font(.caption) }
                if let error = value.native_error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Button(role: .destructive) { deleting = item } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.mutationBusy)
            #if !os(tvOS)
            .buttonStyle(.borderless)
            #endif
        }
    }
}

struct RecordingDetails: View {
    /// Not observed (audit R05): the stores this page draws from are below.
    let model: BrowseModel
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    // The channel's logo comes from the guide row and the EPG artwork.
    @ObservedObject private var guideStore: GuideStore
    @ObservedObject private var artwork: ArtworkStore
    let original: Recording
    @State private var deleting = false
    @State private var playing = false
    /// C-L: playing the in-progress recording from its start.
    @State private var watchingFromStart = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playFocused: Bool
    init(model: BrowseModel, original: Recording) {
        self.model = model
        self.original = original
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
        _guideStore = ObservedObject(wrappedValue: model.guideStore)
        _artwork = ObservedObject(wrappedValue: model.artwork)
    }

    private var item: Recording { model.recordings.first { $0.id == original.id } ?? original }

    /// The channel's logo, found by name in the loaded guide.
    private var logo: String? {
        guard let name = item.channel_name, let row = model.guide.first(where: { $0.name == name }) else { return nil }
        return model.logo(for: row)
    }

    private var resumeFraction: Double? {
        model.progress(for: item).fraction
    }

    /// C-L: still recording, and the server can play it from its start.
    private var canWatchFromStart: Bool {
        item.canWatchFromStart && model.client.info?.features.recordingWatchLive == true
    }

    var body: some View {
        let playLabel = item.playLabel
        DetailPage {
            DetailHero(logo: logo, client: model.client) {
                HStack(alignment: .top) {
                    ChannelLine(logo: logo, client: model.client, name: item.channel_name ?? "Channel unavailable",
                                number: nil, detail: "Recording")
                    Spacer(minLength: 20)
                    statusBadge
                }
                .padding(.bottom, 12)
                if let date = item.started {
                    Eyebrow(text: "\(DetailText.day(date, now: Date())) · \(date.formatted(date: .omitted, time: .shortened))")
                }
                Text(item.title).font(DetailType.title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty {
                    Text(meta).font(DetailType.meta).foregroundStyle(.secondary)
                }
                if let resumeFraction {
                    HStack(spacing: 18) {
                        PigProgressBar(fraction: resumeFraction, height: 6).frame(maxWidth: 640)
                        Text("Resumes where you left off").font(DetailType.meta).foregroundStyle(.secondary)
                    }
                }
                if item.isPreparingForPlayback {
                    Text("Preparing for playback…").font(DetailType.meta).foregroundStyle(.secondary)
                }
                if item.is_partial == 1 {
                    HStack(spacing: 14) {
                        StatusBadge(text: "Partial recording", systemImage: "clock.badge.exclamationmark", colour: .pigWarning)
                        Text("The beginning of the programme may be missing.").font(DetailType.meta).foregroundStyle(.secondary)
                    }
                }
            }
            DetailActions {
                if let playLabel {
                    Button(resumeFraction == nil ? playLabel : "Resume", systemImage: "play.fill") { playing = true }
                        .pigPrimaryButton()
                        .focused($playFocused)
                } else if canWatchFromStart {
                    Button("Watch from start", systemImage: "play.fill") { watchingFromStart = true }
                        .pigPrimaryButton()
                        .focused($playFocused)
                        .accessibilityIdentifier("recording.watchFromStart")
                }
                if item.status == "completed" {
                    Button("Find breaks", systemImage: "wand.and.stars") {
                        Task { await model.detectAds(item) }
                    }
                    .disabled(model.mutationBusy || item.ad_detect_status == "running" || item.ad_detect_status == "pending")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.loadRecordings() }
                }
                .disabled(model.recordingsBusy)
                Button(role: .destructive) { deleting = true } label: {
                    Label("Delete", systemImage: "trash").foregroundStyle(Color.pigDanger)
                }
                .disabled(model.mutationBusy)
            }
            .defaultFocus($playFocused, true)
            if playLabel == nil {
                Text(canWatchFromStart ? "Still recording: watch it from the start while the rest records."
                     : "Playback is available once the recording has finished.").font(DetailType.meta).foregroundStyle(.secondary)
            }
            if let message = model.actionMessage { Text(message).font(DetailType.meta).foregroundStyle(.secondary) }
            if let error = model.actionError { Text(error).font(DetailType.meta).foregroundStyle(.secondary) }
            // 16 Oct (Mark): the break times are not listed here. Breaks are
            // still detected, skipped in the player and marked on its scrub bar.
        }
        .interactiveDismissDisabled(model.mutationBusy)
        .fullScreenCover(isPresented: $playing) { RecordingPlayerScreen(recording: item, client: model.client) { Task { await model.loadRecordings() } } }
        .fullScreenCover(isPresented: $watchingFromStart) {
            RecordingPlayerScreen(recording: item, client: model.client, fromStart: true) { Task { await model.loadRecordings() } }
        }
        .confirmationDialog("Delete this recording?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete recording and file", role: .destructive) {
                Task {
                    await model.delete(item)
                    if !model.recordings.contains(where: { $0.id == original.id }) { dismiss() }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes \(item.title) and its file from the server. If it is still recording, recording stops first.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case "recording": StatusBadge(text: "Recording now", systemImage: "record.circle.fill", colour: .pigDanger)
        case "completed": StatusBadge(text: "Recorded", systemImage: "checkmark.circle.fill")
        case "failed": StatusBadge(text: "Failed", systemImage: "exclamationmark.triangle.fill", colour: .gray)
        default: StatusBadge(text: item.status.capitalized, colour: .gray)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let duration = item.duration_sec, duration > 0 { parts.append(DetailText.duration(duration)) }
        if let bytes = item.file_size_bytes, bytes >= 0, bytes < Double(Int64.max) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

