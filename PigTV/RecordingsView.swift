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
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadRecordings() } }
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
                                        .foregroundStyle(Color.accentColor)
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
                                }.padding(.vertical, 10)
                            }
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
                            }.padding(.vertical, 12)
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
            .task { await model.loadRecordings() }
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
    @Environment(\.dismiss) private var dismiss
    @State private var markers: RecordingMarkers?
    @State private var markerError: String?
    @State private var loading = false
    @State private var deleting = false
    @State private var playing = false
    private var item: Recording { model.recordings.first { $0.id == original.id } ?? original }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(item.title).font(.largeTitle.bold())
                    Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                    Label(item.status.capitalized, systemImage: item.status == "recording" ? "record.circle" : "video")
                        .foregroundStyle(Color.accentColor)
                    if let date = item.started { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    if let duration = item.duration_sec {
                        Text("Duration: \(Int(max(0, duration) / 60)) minutes")
                    }
                    if let bytes = item.file_size_bytes, bytes >= 0, bytes < Double(Int64.max) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    }
                    if item.is_partial == 1 {
                        Label("Partial recording", systemImage: "clock.badge.exclamationmark")
                        Text("The beginning of the programme may be missing.").foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Playback").font(.headline)
                    if item.status == "completed" {
                        Button("Play recording", systemImage: "play.fill") { playing = true }.pigPrimaryButton()
                        if UserDefaults.standard.double(forKey: "pigtv.resume.\(item.id)") > 10 {
                            Text("Resumes where you left off.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Playback is available once the recording has finished.").foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Commercial breaks").font(.headline)
                    Text("Analysis: \((markers?.status ?? item.ad_detect_status ?? "not analysed").capitalized)")
                    if loading { ProgressView("Loading break information…") }
                    if let error = markerError { Text(error).foregroundStyle(.secondary) }
                    if let markers {
                        let valid = markers.markers.filter { $0.valid && $0.type == "ad" }
                        if valid.isEmpty { Text("No detected breaks available.").foregroundStyle(.secondary) }
                        ForEach(valid) { marker in
                            Text("\(time(marker.startMs)) – \(time(marker.endMs))").monospacedDigit()
                        }
                    }
                    if item.status == "completed" {
                        Button("Analyse commercial breaks", systemImage: "wand.and.stars") {
                            Task { await model.detectAds(item); await loadMarkers() }
                        }.disabled(model.mutationBusy || item.ad_detect_status == "running" || item.ad_detect_status == "pending")
                    }
                    Button("Refresh details", systemImage: "arrow.clockwise") {
                        Task { await model.loadRecordings(); await loadMarkers() }
                    }.disabled(loading || model.recordingsBusy)
                    if let message = model.actionMessage { Text(message).foregroundStyle(.secondary) }
                    if let error = model.actionError { Text(error).foregroundStyle(.secondary) }
                    Divider()
                    Button("Delete recording", role: .destructive) { deleting = true }
                        .disabled(model.mutationBusy)
                    Button("Done") { dismiss() }.disabled(model.mutationBusy)
                }.padding(40).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Recording")
            .presentationBackground { PigPageBackground() }
            .interactiveDismissDisabled(model.mutationBusy)
            .task { await loadMarkers() }
            .fullScreenCover(isPresented: $playing) { RecordingPlayerScreen(recording: item, client: model.client) }
            .confirmationDialog("Permanently delete this recording?", isPresented: $deleting) {
                Button("Delete recording and file", role: .destructive) {
                    Task {
                        await model.delete(item)
                        if !model.recordings.contains(where: { $0.id == original.id }) { dismiss() }
                    }
                }
            } message: {
                Text("This removes \(item.title) and its file from the server. If recording is in progress it will stop first.")
            }
        }
    }

    private func time(_ milliseconds: Double) -> String {
        let total = Int(min(milliseconds / 1000, Double(Int.max / 2)))
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private func loadMarkers() async {
        guard !loading else { return }
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
