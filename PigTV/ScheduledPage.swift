import SwiftUI

// D-44 batch 5 (Apple 119): Scheduled, opened from the Recordings tab's Coming up "All ›" (R5-Scheduled-*): what is
// scheduled, with the clash choices (#12), the recording rules and what needs attention.

private enum ScheduledMetrics {
    #if os(tvOS)
    static let pagePadding: CGFloat = 40
    static let title: Font = .system(size: 22, weight: .semibold)
    #else
    static let pagePadding: CGFloat = 20
    static let title: Font = .subheadline.weight(.semibold)
    #endif
    static let radius = PigRadius.card
}

/// A failed library recording or a failed/missed schedule, for the "needs attention" list.
enum AttentionItem: Identifiable {
    case schedule(ScheduledRecording)
    case recording(Recording)
    var id: String {
        switch self {
        case .schedule(let item): "schedule-\(item.id)"
        case .recording(let item): "recording-\(item.id)"
        }
    }
}

struct ScheduledPage: View {
    let model: BrowseModel
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var cancellation: ScheduledRecording?
    /// #12 (D-42): the losing schedule whose "Record this one instead" is being confirmed.
    @State private var choosing: ScheduledRecording?
    @State private var reviewing = false
    /// C-M: the recording rules sheet.
    @State private var showingRules = false
    @Environment(\.colorScheme) private var scheme

    init(model: BrowseModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    private var failed: [Recording] { RecordingsRows.failedRecordings(model.recordings, schedules: model.schedules) }
    private var problems: [ScheduledRecording] { RecordingsRows.problemSchedules(model.schedules) }
    private var attentionTitle: String? {
        RecordingsRows.attentionTitle(failedSchedules: problems.filter { $0.status == "failed" }.count,
                                      missedSchedules: problems.filter { $0.status == "missed" }.count,
                                      failedRecordings: failed.count)
    }

    var body: some View {
        List {
            if let title = attentionTitle {
                AttentionBanner(title: title) { reviewing = true }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: ScheduledMetrics.pagePadding, bottom: 6, trailing: ScheduledMetrics.pagePadding))
            }
            if model.rulesAvailable {
                // C-M: the rules that make schedules on their own.
                Button { showingRules = true } label: {
                    Label("Recording rules", systemImage: "repeat.circle")
                }
                .accessibilityIdentifier("recordings.rules")
                .scheduleSurface(scheme)
            }
            ForEach(model.schedules.filter { $0.isActive }) { item in
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    if item.rule_id != nil {
                        Text("From a rule").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.channel_name ?? "Channel unavailable").foregroundStyle(.secondary)
                    Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit()).fontDesign(.rounded)
                    Text(item.statusLabel).font(.caption.bold())
                    if let beaten = item.beatenText(in: model.schedules) {
                        // Server 0410 (#12, D-42): it lost its clash and waits; choosing it makes the winner wait instead.
                        Text(beaten).font(.caption).foregroundStyle(Color.pigWarning)
                            .accessibilityIdentifier("recordings.beaten.\(item.id)")
                        if item.canChoose {
                            Button("Record this one instead") { choosing = item }
                                .disabled(model.mutationBusy)
                                .accessibilityIdentifier("recordings.choose.\(item.id)")
                        }
                    } else if let clash = item.clashText(in: model.schedules) {
                        Text(clash).font(.caption).foregroundStyle(Color.pigWarning)
                            .accessibilityIdentifier("recordings.clash.\(item.id)")
                    }
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
        .navigationTitle("Scheduled")
        .pigPageBackdrop()
        .sheet(isPresented: $reviewing) { RecordingAttentionSheet(model: model) }
        .sheet(isPresented: $showingRules) { RecordingRulesSheet(model: model) }
        .closesForOutsidePlay { reviewing = false; showingRules = false } // #179
        .confirmationDialog("Cancel this recording?", isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
        ), presenting: cancellation) { item in
            Button(item.status == "recording" ? "Stop recording" : "Cancel schedule", role: .destructive) {
                Task { await model.cancel(item) }
            }
        } message: { item in
            Text("\(item.title). If it is already recording, it will stop. The recorded portion will be kept.")
        }
        .confirmationDialog(Text(choosing.map { "Record \($0.title) instead?" } ?? ""), isPresented: Binding(
            get: { choosing != nil }, set: { if !$0 { choosing = nil } }
        ), titleVisibility: .visible, presenting: choosing) { item in
            Button("Record this one") { Task { await model.choose(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.chooseMessage(in: model.schedules))
        }
        .overlay {
            if !model.schedules.contains(where: \.isActive) && !model.recordingsBusy && problems.isEmpty {
                Text("Nothing scheduled. Browse the TV Guide to choose a programme.")
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
            .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: ScheduledMetrics.radius))
            .listRowInsets(EdgeInsets(top: 6, leading: ScheduledMetrics.pagePadding, bottom: 6, trailing: ScheduledMetrics.pagePadding))
            .listRowBackground(Color.clear)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
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
                Text(title).font(ScheduledMetrics.title)
                Spacer()
                Text("Review").font(ScheduledMetrics.title).foregroundStyle(Color.pigAccentText)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: ScheduledMetrics.radius))
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
                        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: ScheduledMetrics.radius))
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

// MARK: Recording rules (C-M)

/// The rules that make schedules ("every game of", "series"), each with an
/// on/off switch and Delete. Loaded when shown.
private struct RecordingRulesSheet: View {
    let model: BrowseModel
    @ObservedObject private var actions: ActionState
    @State private var rules: [RecordingRule] = []
    @State private var loading = true
    @State private var error: String?
    @State private var deleting: RecordingRule?
    @Environment(\.dismiss) private var dismiss

    init(model: BrowseModel) {
        self.model = model
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                if !loading && rules.isEmpty && error == nil {
                    Text("No rules yet. Choose Record series on a programme, or Record every game on a Sport event.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(rule.summary).font(.headline)
                        if let setBy = rule.setBy {
                            Text(setBy).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("rules.setBy.\(rule.id)")
                        }
                        Text(rule.detail).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            Button(rule.isOn ? "Turn off" : "Turn on") {
                                Task { await model.setRule(rule, enabled: !rule.isOn); await reload() }
                            }
                            Button("Delete", role: .destructive) { deleting = rule }
                        }
                        // A3 (build 48): one change at a time.
                        .disabled(actions.mutationBusy)
                    }
                    .padding(.vertical, 6)
                }
                // A3: a rule change that failed says so (the reload after it shows the rule unchanged).
                if let failure = actions.actionError {
                    Text(failure).font(.caption).foregroundStyle(Color.pigDanger).accessibilityIdentifier("rules-action-error")
                } else if let message = actions.actionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rules-action-message")
                }
            }
            .navigationTitle("Recording rules")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .overlay { if loading { ProgressView() } }
            .task { await reload() }
            .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { rule in
                Button("Delete rule", role: .destructive) { Task { await model.deleteRule(rule); await reload() } }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("Its recordings that have not started are cancelled. Anything recorded is kept.")
            }
        }
    }

    private func reload() async {
        do {
            rules = try await model.loadRules()
            error = nil
        } catch {
            self.error = "Could not load the rules. \(error.localizedDescription)"
        }
        loading = false
    }
}
