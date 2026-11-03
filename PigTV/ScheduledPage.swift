import SwiftUI

// D-44 batch 5 (Apple 120, R5-Scheduled-*): Scheduled, pushed from the Recordings tab's Coming up. Two columns on the
// Apple TV and the iPad: Coming up (each schedule with its day and time, the rule that made it, Cancel, and a clash's
// "Record this one instead", #12), then the recording rules (on/off and Remove) and what needs attention (missed and
// failed, each with Delete). The iPhone shows Coming up, then two tiles that open the rules and Needs attention.

private enum ScheduledMetrics {
    #if os(tvOS)
    static let pagePadding: CGFloat = 40
    static let columnGap: CGFloat = 40
    static let sideWidth: CGFloat = 640
    static let dayWidth: CGFloat = 150
    static let heading: Font = .system(size: 40, weight: .heavy)
    static let section: Font = .system(size: 24, weight: .bold)
    static let day: Font = .system(size: 21, weight: .bold)
    static let time: Font = .system(size: 18)
    static let title: Font = .system(size: 23, weight: .bold)
    static let detail: Font = .system(size: 18)
    static let chip: Font = .system(size: 15, weight: .bold)
    static let rowPadding = EdgeInsets(top: 16, leading: 22, bottom: 16, trailing: 22)
    #else
    static let pagePadding: CGFloat = 20
    static let columnGap: CGFloat = 24
    static let sideWidth: CGFloat = 420
    static let dayWidth: CGFloat = 82
    static let heading: Font = .largeTitle.weight(.heavy)
    static let section: Font = .caption.weight(.bold)
    static let day: Font = .subheadline.weight(.bold)
    static let time: Font = .footnote
    static let title: Font = .callout.weight(.bold)
    static let detail: Font = .footnote
    static let chip: Font = .caption2.weight(.bold)
    static let rowPadding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    #endif
}

/// A failed library recording or a failed/missed schedule, for Needs attention.
nonisolated enum AttentionItem: Identifiable {
    case schedule(ScheduledRecording)
    case recording(Recording)
    var id: String {
        switch self {
        case .schedule(let item): "schedule-\(item.id)"
        case .recording(let item): "recording-\(item.id)"
        }
    }
}

/// What Scheduled lists, as pure functions (RecordingsHomeTests).
nonisolated enum ScheduledRows {
    /// Coming up: every active schedule (recording now, scheduled, waiting), soonest first.
    static func upcoming(_ schedules: [ScheduledRecording], hidden: Set<String> = []) -> [ScheduledRecording] {
        schedules.filter { $0.isActive && !hidden.contains(RecordingsHome.key($0)) }
            .sorted { ($0.program_start, $0.id) < ($1.program_start, $1.id) }
    }

    /// Needs attention: missed and failed schedules, then failed recordings not already counted as their schedule.
    static func attention(recordings: [Recording], schedules: [ScheduledRecording], hidden: Set<String> = []) -> [AttentionItem] {
        let items = RecordingsRows.problemSchedules(schedules).map(AttentionItem.schedule)
            + RecordingsRows.failedRecordings(recordings, schedules: schedules).map(AttentionItem.recording)
        return items.filter { item in
            switch item {
            case .schedule(let value): !hidden.contains(RecordingsHome.key(value))
            case .recording(let value): !hidden.contains(RecordingsHome.key(value))
            }
        }
    }

    /// The chip naming the rule a schedule came from: "Series", "Every Collingwood game"; "From a rule" when the rule is
    /// not loaded; nil for a one-off.
    static func ruleChip(_ item: ScheduledRecording, rules: [RecordingRule]) -> String? {
        guard let id = item.rule_id else { return nil }
        guard let rule = rules.first(where: { $0.id == id }) else { return "From a rule" }
        switch rule.kind {
        case "series": return "Series"
        default: return "Every \(rule.match) game"
        }
    }

    /// "4 on · 1 off", the iPhone's rules tile.
    static func rulesSummary(_ rules: [RecordingRule]) -> String {
        let on = rules.filter(\.isOn).count, off = rules.count - on
        if rules.isEmpty { return "None yet" }
        return off == 0 ? "\(on) on" : "\(on) on · \(off) off"
    }

    /// "1 missed · 1 failed", the iPhone's Needs attention tile.
    static func attentionSummary(_ items: [AttentionItem]) -> String {
        let missed = items.filter { if case .schedule(let s) = $0 { s.status == "missed" } else { false } }.count
        let failed = items.count - missed
        var parts: [String] = []
        if missed > 0 { parts.append("\(missed) missed") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " · ")
    }
}

struct ScheduledPage: View {
    let model: BrowseModel
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var cancellation: ScheduledRecording?
    /// #12 (D-42): the losing schedule whose "Record this one instead" is being confirmed.
    @State private var choosing: ScheduledRecording?
    @State private var deleting: AttentionItem?
    @State private var removing: RecordingRule?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: BrowseModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    private var upcoming: [ScheduledRecording] { ScheduledRows.upcoming(model.schedules) }
    private var attention: [AttentionItem] { ScheduledRows.attention(recordings: model.recordings, schedules: model.schedules) }
    private var rules: [RecordingRule] { store.rules }
    private var showsRules: Bool { model.rulesAvailable || !rules.isEmpty }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(tvOS)
                Text("Scheduled").font(ScheduledMetrics.heading).accessibilityAddTraits(.isHeader)
                #endif
                status
                if compact {
                    VStack(alignment: .leading, spacing: 12) {
                        comingUp
                        HStack(spacing: 8) {
                            if showsRules {
                                ScheduledTile(title: "Recording rules", detail: "\(ScheduledRows.rulesSummary(rules)) ›",
                                              warning: false, route: .rules)
                            }
                            ScheduledTile(title: "Needs attention", detail: "\(ScheduledRows.attentionSummary(attention)) ›",
                                          warning: !attention.isEmpty, route: .attention)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: ScheduledMetrics.columnGap) {
                        comingUp.frame(maxWidth: .infinity, alignment: .leading).tvFocusSection()
                        VStack(alignment: .leading, spacing: 26) {
                            if showsRules { rulesSection }
                            attentionSection
                        }
                        .frame(width: ScheduledMetrics.sideWidth, alignment: .leading)
                        .tvFocusSection()
                    }
                }
            }
            .padding(.horizontal, ScheduledMetrics.pagePadding)
            .padding(.bottom, 24)
        }
        #if os(iOS)
        .refreshable { await model.loadRecordings(); await model.reloadRules() }
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.large)
        #endif
        .pigPageBackdrop()
        .accessibilityIdentifier("scheduled.page")
        .task { await model.reloadRules() }
        .modifier(ScheduledDialogs(model: model, cancellation: $cancellation, choosing: $choosing, deleting: $deleting,
                                   removing: $removing))
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.recordingsError {
            RetryBanner(message: error) { Task { await model.loadRecordings() } }
        }
        if let error = actions.actionError {
            Text(error).font(ScheduledMetrics.detail).foregroundStyle(Color.pigDanger).accessibilityIdentifier("scheduled.error")
        } else if let message = actions.actionMessage {
            Text(message).font(ScheduledMetrics.detail).foregroundStyle(.secondary)
        }
    }

    // MARK: Coming up

    private var comingUp: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScheduledSectionTitle(text: upcoming.isEmpty ? "Coming up" : "Coming up · \(upcoming.count)")
            if upcoming.isEmpty {
                Text("Nothing scheduled. Choose a programme in the TV Guide, or a game in Sport, and record it.")
                    .font(ScheduledMetrics.detail).foregroundStyle(.secondary)
                    .accessibilityIdentifier("scheduled.empty")
            }
            ForEach(upcoming) { item in
                ScheduleRow(item: item, all: model.schedules, rule: ScheduledRows.ruleChip(item, rules: rules),
                            compact: compact, busy: actions.mutationBusy,
                            cancel: { cancellation = item }, choose: { choosing = item })
            }
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        ScheduledRulesList(model: model, rules: rules, remove: { removing = $0 })
    }

    // MARK: Needs attention

    private var attentionSection: some View {
        ScheduledAttentionList(items: attention, busy: actions.mutationBusy, delete: { deleting = $0 })
    }
}

/// The page's confirmations (Apple 120); Cancel, Delete and Remove move to the Undo toast next.
private struct ScheduledDialogs: ViewModifier {
    let model: BrowseModel
    @Binding var cancellation: ScheduledRecording?
    @Binding var choosing: ScheduledRecording?
    @Binding var deleting: AttentionItem?
    @Binding var removing: RecordingRule?

    func body(content: Content) -> some View {
        content
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
            .confirmationDialog("Delete this item?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { item in
                Button("Delete", role: .destructive) {
                    Task {
                        switch item {
                        case .schedule(let value): await model.deleteSchedule(value)
                        case .recording(let value): await model.delete(value)
                        }
                    }
                }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("This removes it and any partial file from the server.")
            }
            .confirmationDialog("Remove this rule?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { rule in
                Button("Remove rule", role: .destructive) { Task { await model.deleteRule(rule) } }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("Its recordings that have not started are cancelled. Anything recorded is kept.")
            }
    }
}

// MARK: Rows

/// One schedule: its day and time, title with the rule's chip, channel and state, Cancel (Stop while it records), and a
/// clash's reason and "Record this one instead".
private struct ScheduleRow: View {
    let item: ScheduledRecording
    let all: [ScheduledRecording]
    let rule: String?
    let compact: Bool
    let busy: Bool
    let cancel: () -> Void
    let choose: () -> Void

    private var when: String { RecordingsHome.when(item.start, now: Date()) }
    private var state: String { item.status == "recording" ? "Recording now" : item.statusLabel }
    private var clash: Bool { RecordingsHome.clashes(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecordingsHome.day(item.start, now: Date())).font(ScheduledMetrics.day)
                        Text(item.start.formatted(date: .omitted, time: .shortened)).font(ScheduledMetrics.time)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit().fontDesign(.rounded)
                    .frame(width: ScheduledMetrics.dayWidth, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if compact {
                        Text(when).font(ScheduledMetrics.chip).monospacedDigit().fontDesign(.rounded).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text(item.title).font(ScheduledMetrics.title).lineLimit(1)
                        if let rule, !compact { RuleChip(text: rule) }
                    }
                    Text([item.channel_name ?? "Channel unavailable", compact ? rule : state].compactMap { $0 }.joined(separator: " · "))
                        .font(ScheduledMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: cancel) {
                    if compact { Image(systemName: "xmark") } else { Text(item.status == "recording" ? "Stop" : "Cancel") }
                }
                .disabled(busy || !item.canCancel)
                .accessibilityLabel(item.status == "recording" ? "Stop recording \(item.title)" : "Cancel \(item.title)")
                .accessibilityIdentifier("scheduled.cancel.\(item.id)")
            }
            .accessibilityElement(children: .contain)
            if let beaten = item.beatenText(in: all) {
                // Server 0410 (#12, D-42): it lost its clash and waits; choosing it makes the winner wait instead. The
                // button sits at the row's trailing edge, under Cancel, so Down from Cancel reaches it on the TV.
                if compact {
                    clashLine(beaten, id: "recordings.beaten.\(item.id)")
                    if item.canChoose { chooseButton.frame(maxWidth: .infinity) }
                } else {
                    HStack(spacing: 16) {
                        clashLine(beaten, id: "recordings.beaten.\(item.id)").frame(maxWidth: .infinity, alignment: .leading)
                        if item.canChoose { chooseButton }
                    }
                }
            } else if let text = item.clashText(in: all) {
                clashLine(text, id: "recordings.clash.\(item.id)")
            }
        }
        .padding(ScheduledMetrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay {
            if clash { RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigWarning, lineWidth: 2) }
        }
    }

    private var chooseButton: some View {
        Button("Record this one instead", action: choose)
            .pigPrimaryButton()
            .disabled(busy)
            .accessibilityIdentifier("recordings.choose.\(item.id)")
    }

    private func clashLine(_ text: String, id: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(ScheduledMetrics.detail.weight(.semibold)).foregroundStyle(Color.pigWarning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, compact ? 0 : ScheduledMetrics.dayWidth + 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier(id)
    }
}

/// "Series", "Every Collingwood game".
private struct RuleChip: View {
    let text: String
    var body: some View {
        Text(text).font(ScheduledMetrics.chip).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.inner))
    }
}

/// The recording rules: name, what it has scheduled (and who set it), an on/off switch and Remove.
struct ScheduledRulesList: View {
    let model: BrowseModel
    let rules: [RecordingRule]
    let remove: (RecordingRule) -> Void
    @ObservedObject private var actions: ActionState
    @ObservedObject private var store: RecordingsStore

    init(model: BrowseModel, rules: [RecordingRule], remove: @escaping (RecordingRule) -> Void) {
        self.model = model
        self.rules = rules
        self.remove = remove
        _actions = ObservedObject(wrappedValue: model.actions)
        _store = ObservedObject(wrappedValue: model.recordingStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScheduledSectionTitle(text: rules.isEmpty ? "Recording rules" : "Recording rules · \(rules.count)")
            if let error = store.rulesError { Text(error).font(ScheduledMetrics.detail).foregroundStyle(.secondary) }
            if rules.isEmpty && store.rulesError == nil {
                Text("No rules yet. Choose Record every episode on a programme, or Record every game on a Sport card.")
                    .font(ScheduledMetrics.detail).foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.summary).font(ScheduledMetrics.title).lineLimit(1)
                        Text([rule.detail, rule.setBy].compactMap { $0 }.joined(separator: " · "))
                            .font(ScheduledMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("rules.setBy.\(rule.id)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(isOn: Binding(get: { rule.isOn },
                                         set: { on in Task { await model.setRule(rule, enabled: on) } })) {
                        Text(rule.isOn ? "On" : "Off")
                    }
                    .labelsHidden()
                    .accessibilityLabel("\(rule.summary), \(rule.isOn ? "on" : "off")")
                    .accessibilityIdentifier("rules.toggle.\(rule.id)")
                    Button("Remove") { remove(rule) }
                        .accessibilityLabel("Remove the rule \(rule.summary)")
                        .accessibilityIdentifier("rules.remove.\(rule.id)")
                }
                // A3 (build 48): one change at a time.
                .disabled(actions.mutationBusy)
                .padding(ScheduledMetrics.rowPadding)
                .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            }
        }
        .tvFocusSection()
    }
}

/// Needs attention: missed (amber) and failed (red) schedules and recordings, each with Delete.
struct ScheduledAttentionList: View {
    let items: [AttentionItem]
    let busy: Bool
    let delete: (AttentionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScheduledSectionTitle(text: items.isEmpty ? "Needs attention" : "Needs attention · \(items.count)")
            if items.isEmpty {
                Text("Nothing needs attention.").font(ScheduledMetrics.detail).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let (kind, title, detail) = Self.text(item)
                HStack(spacing: 14) {
                    Text(kind).font(ScheduledMetrics.chip)
                        .foregroundStyle(kind == "Missed" ? Color.pigWarning : Color.pigDanger)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background((kind == "Missed" ? Color.pigWarning : Color.pigDanger).opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: PigRadius.inner))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(ScheduledMetrics.title).lineLimit(1)
                        Text(detail).font(ScheduledMetrics.detail).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { delete(item) } label: { Text("Delete").foregroundStyle(Color.pigDanger) }
                        .disabled(busy)
                        .accessibilityLabel("Delete \(title)")
                        .accessibilityIdentifier("scheduled.delete.\(item.id)")
                }
                .padding(ScheduledMetrics.rowPadding)
                .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            }
        }
        .tvFocusSection()
    }

    /// The badge, title and line: "ABC TV · Sun 2 Nov · <the server's reason>".
    static func text(_ item: AttentionItem) -> (String, String, String) {
        switch item {
        case .schedule(let value):
            let parts = [value.channel_name ?? "Channel unavailable",
                         value.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), value.error]
            return (value.status == "missed" ? "Missed" : "Failed", value.title, parts.compactMap { $0 }.joined(separator: " · "))
        case .recording(let value):
            let parts = [value.channel_name ?? "Channel unavailable",
                         value.started?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), value.native_error]
            return ("Failed", value.title, parts.compactMap { $0 }.joined(separator: " · "))
        }
    }
}

private struct ScheduledSectionTitle: View {
    let text: String
    var body: some View {
        #if os(tvOS)
        Text(text).font(ScheduledMetrics.section).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
        #else
        Text(text.uppercased()).font(ScheduledMetrics.section).tracking(1.2).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
        #endif
    }
}

/// The iPhone's tiles under Coming up: the rules and Needs attention, each its own page.
private struct ScheduledTile: View {
    let title: String
    let detail: String
    let warning: Bool
    let route: RecordingsRoute

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Color("PigText"))
                Text(detail).font(.caption).foregroundStyle(warning ? Color.pigWarning : Color.pigSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .overlay {
                if warning {
                    RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigWarning, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scheduled.tile.\(title)")
    }
}

/// The iPhone's rules page and Needs attention page (Scheduled's tiles).
struct ScheduledSubpage: View {
    let model: BrowseModel
    let route: RecordingsRoute
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var deleting: AttentionItem?
    @State private var removing: RecordingRule?
    @State private var cancellation: ScheduledRecording?
    @State private var choosing: ScheduledRecording?

    init(model: BrowseModel, route: RecordingsRoute) {
        self.model = model
        self.route = route
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = actions.actionError {
                    Text(error).font(ScheduledMetrics.detail).foregroundStyle(Color.pigDanger)
                }
                if route == .rules {
                    ScheduledRulesList(model: model, rules: store.rules, remove: { removing = $0 })
                } else {
                    ScheduledAttentionList(items: ScheduledRows.attention(recordings: model.recordings, schedules: model.schedules),
                                           busy: actions.mutationBusy, delete: { deleting = $0 })
                }
            }
            .padding(.horizontal, ScheduledMetrics.pagePadding).padding(.bottom, 24)
        }
        #if os(iOS)
        .navigationTitle(route == .rules ? "Recording rules" : "Needs attention")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .pigPageBackdrop()
        .modifier(ScheduledDialogs(model: model, cancellation: $cancellation, choosing: $choosing, deleting: $deleting,
                                   removing: $removing))
    }
}
