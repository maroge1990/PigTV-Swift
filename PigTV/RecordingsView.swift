import SwiftUI

struct RecordingsView: View {
    @ObservedObject var model: BrowseModel
    @State private var selected: Recording?
    @State private var cancellation: ScheduledRecording?
    @State private var section = "library"
    @State private var search = ""

    private var filtered: [Recording] {
        model.recordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.channel_name?.localizedCaseInsensitiveContains(search) ?? false) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Picker("View", selection: $section) {
                        Text("Library").tag("library")
                        Text("Scheduled").tag("scheduled")
                    }.pickerStyle(.segmented)
                    Button { Task { await model.loadRecordings() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 24).padding(.vertical, 12)
                    }
                        .buttonStyle(PigSurfaceButtonStyle())
                        .disabled(model.recordingsBusy)
                }.padding(.horizontal, 32)
                if let error = model.recordingsError {
                    RetryBanner(message: error) { Task { await model.loadRecordings() } }
                }
                if let message = model.actionMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.actionError { Text(error).foregroundStyle(.secondary).padding(.horizontal) }
                if section == "library" {
                    TextField("Search recordings", text: $search).padding(.horizontal, 32)
                    List {
                        ForEach(filtered) { item in
                            Button { selected = item } label: {
                                HStack(spacing: 20) {
                                    Image(systemName: item.status == "recording" ? "record.circle" : "play.rectangle")
                                        .foregroundStyle(Color.pigAccent)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(item.title).font(.headline)
                                        Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                                        if let date = item.started { Text(date, style: .date).font(.caption) }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        Text(item.status.capitalized).font(.caption.bold())
                                        if item.is_partial == 1 { Text("Partial recording").font(.caption) }
                                    }
                                }
                                .padding(.horizontal, 24).padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PigSurfaceButtonStyle())
                            .listRowInsets(EdgeInsets(top: 6, leading: 32, bottom: 6, trailing: 32))
                        }
                    }
                    if filtered.isEmpty && !model.recordingsBusy {
                        Text(search.isEmpty ? "No recordings yet. Choose a programme in Guide to schedule one." : "No matching recordings.")
                            .foregroundStyle(.secondary).padding()
                    }
                } else {
                    List {
                        ForEach(model.schedules) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.headline)
                                Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                                Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                Text(item.statusLabel).font(.caption.bold())
                                if item.canCancel {
                                    Button(item.status == "recording" ? "Stop recording" : "Cancel schedule", role: .destructive) {
                                        cancellation = item
                                    }.disabled(model.mutationBusy)
                                }
                            }
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 6, leading: 32, bottom: 6, trailing: 32))
                        }
                    }
                    if model.schedules.isEmpty && !model.recordingsBusy {
                        Text("Nothing scheduled. Browse Guide to choose a programme.")
                            .foregroundStyle(.secondary).padding()
                    }
                }
                if model.recordingsBusy { ProgressView("Refreshing recordings…") }
            }
            .navigationTitle("Recordings")
            .background(PigPageBackground())
            // Build 31: only when older than a minute (Refresh reloads at once).
            .task { await model.loadRecordingsIfStale() }
            .fullScreenCover(item: $selected) { item in RecordingDetails(model: model, original: item) }
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
}

struct RecordingDetails: View {
    @ObservedObject var model: BrowseModel
    let original: Recording
    @State private var markers: RecordingMarkers?
    @State private var markerError: String?
    @State private var loading = false
    @State private var deleting = false
    @State private var playing = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playFocused: Bool
    private var item: Recording { model.recordings.first { $0.id == original.id } ?? original }

    /// The channel's logo, found by name in the loaded guide.
    private var logo: String? {
        guard let name = item.channel_name, let row = model.guide.first(where: { $0.name == name }) else { return nil }
        return model.logo(for: row)
    }

    private var resumeFraction: Double? {
        guard item.status == "completed" else { return nil }
        return HomeRows.resumeFraction(position: UserDefaults.standard.double(forKey: "pigtv.resume.\(item.id)"),
                                       duration: item.duration_sec)
    }

    var body: some View {
        let playLabel = item.playLabel(recordingHls: model.client.info?.features.recordingHls == true)
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
                if item.is_partial == 1 {
                    HStack(spacing: 14) {
                        StatusBadge(text: "Partial recording", systemImage: "clock.badge.exclamationmark", colour: .orange)
                        Text("The beginning of the programme may be missing.").font(DetailType.meta).foregroundStyle(.secondary)
                    }
                }
            }
            DetailActions {
                if let playLabel {
                    Button(resumeFraction == nil ? playLabel : "Resume", systemImage: "play.fill") { playing = true }
                        .pigPrimaryButton()
                        .focused($playFocused)
                }
                if item.status == "completed" {
                    Button("Find breaks", systemImage: "wand.and.stars") {
                        Task { await model.detectAds(item); await loadMarkers() }
                    }
                    .disabled(model.mutationBusy || item.ad_detect_status == "running" || item.ad_detect_status == "pending")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.loadRecordings(); await loadMarkers() }
                }
                .disabled(loading || model.recordingsBusy)
                Button(role: .destructive) { deleting = true } label: {
                    Label("Delete", systemImage: "trash").foregroundStyle(.red)
                }
                .disabled(model.mutationBusy)
            }
            .defaultFocus($playFocused, true)
            if playLabel == nil {
                Text("Playback is available once the recording has finished.").font(DetailType.meta).foregroundStyle(.secondary)
            }
            if let message = model.actionMessage { Text(message).font(DetailType.meta).foregroundStyle(.secondary) }
            if let error = model.actionError { Text(error).font(DetailType.meta).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 14) {
                PigSectionHeader(title: "Commercial breaks")
                Text("Analysis: \((markers?.status ?? item.ad_detect_status ?? "not analysed").capitalized)")
                    .font(DetailType.meta).foregroundStyle(.secondary)
                if loading { ProgressView("Loading break information…") }
                if let error = markerError { Text(error).font(DetailType.meta).foregroundStyle(.secondary) }
                if let markers {
                    let valid = markers.markers.filter { $0.valid && $0.type == "ad" }
                    if valid.isEmpty {
                        Text("No detected breaks.").font(DetailType.meta).foregroundStyle(.secondary)
                    } else {
                        BreakList(breaks: valid)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.mutationBusy)
        .task { await loadMarkers() }
        .fullScreenCover(isPresented: $playing) { RecordingPlayerScreen(recording: item, client: model.client) }
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
        case "recording": StatusBadge(text: "Recording now", systemImage: "record.circle.fill", colour: .red)
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

    private func loadMarkers() async {
        guard !loading else { return }
        #if DEBUG
        if model.isFixture { markers = GuideFixtures.markers(); return }
        #endif
        loading = true
        markerError = nil
        defer { loading = false }
        do { markers = try await model.client.request("recordings/\(original.id)/markers") }
        catch {
            markerError = error as? PigTVError == .http(404)
                ? "Break information is unavailable on this server or this recording no longer exists."
                : error.localizedDescription
        }
    }
}

/// Detected breaks as time-range chips on the guide's surface.
private struct BreakList: View {
    let breaks: [CommercialBreak]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 14) {
            ForEach(breaks) { marker in
                Text("\(RecordingTimeline.clock(marker.startMs / 1000)) – \(RecordingTimeline.clock(marker.endMs / 1000))")
                    .font(DetailType.rowDetail.monospacedDigit())
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Color.guideCell(scheme), in: Capsule())
            }
        }
        .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(breaks.count) breaks")
    }
}
