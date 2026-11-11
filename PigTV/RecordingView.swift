import SwiftUI

// D-44 batch 5 (Apple 121, R5-View-*): View recording, pushed on the Recordings tab's stack (and hosted by the app's
// presentation layer). Full-width art (a game's two teams' badges, else the programme's artwork or the channel's logo),
// the state as a pill, then an info bar: the eyebrow (day · time · channel), the title, where it was left, the actions
// (Resume / Play, Watch from start while it records, Find breaks, Delete) and the facts the feeds give (length and size,
// channel, a partial recording). No score: a recording never shows one (#192).

private enum ViewMetrics {
    #if os(tvOS)
    static let artShare: CGFloat = 0.6
    static let badge: CGFloat = 300
    static let padding = EdgeInsets(top: 36, leading: 96, bottom: 48, trailing: 96)
    static let factsWidth: CGFloat = 560
    static let eyebrow: Font = .system(size: PigType.caption, weight: .bold)
    static let title: Font = .system(size: PigType.hero, weight: .heavy)
    static let detail: Font = .system(size: PigType.secondary)
    static let fact: Font = .system(size: PigType.secondary)
    static let pill: Font = .system(size: PigType.secondary, weight: .bold)
    static let barWidth: CGFloat = 640
    static let pillTop: CGFloat = 40
    #else
    static let artShare: CGFloat = 0.55
    static let badge: CGFloat = 200
    static let padding = EdgeInsets(top: 22, leading: 28, bottom: 24, trailing: 28)
    static let factsWidth: CGFloat = 320
    static let eyebrow: Font = .caption.weight(.bold)
    static let title: Font = .title.weight(.heavy)
    static let detail: Font = .footnote
    static let fact: Font = .subheadline
    static let pill: Font = .footnote.weight(.bold)
    static let barWidth: CGFloat = .infinity
    static let pillTop: CGFloat = 56
    #endif
    static let phoneArtHeight: CGFloat = 300
    static let phoneBadge: CGFloat = 120
}

/// What View recording says, as pure functions (RecordingsHomeTests).
nonisolated enum RecordingFacts {
    /// "SAT 1 NOV · 11:30 PM · OPTUS SPORT 1".
    static func eyebrow(_ item: Recording) -> String {
        var parts: [String] = []
        if let started = item.started {
            parts.append(started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            parts.append(started.formatted(date: .omitted, time: .shortened))
        }
        if let channel = item.channel_name { parts.append(channel) }
        return parts.joined(separator: " · ").uppercased()
    }

    /// "1:12:40 of 2:05:00" where it was left; nil when it was not.
    static func position(_ item: Recording, progress: RecordingProgress) -> String? {
        guard let fraction = progress.fraction, let duration = item.duration_sec, duration > 0 else { return nil }
        return "\(RecordingResume.clock(duration * fraction)) of \(RecordingResume.clock(duration))"
    }

    /// The facts: Length ("2 h 30 min · 4.8 GB"), Channel, and a partial recording's note.
    static func facts(_ item: Recording) -> [(String, String)] {
        var out: [(String, String)] = []
        var length: [String] = []
        if let duration = item.duration_sec, duration > 0 { length.append(DetailText.duration(duration)) }
        if let bytes = item.file_size_bytes, bytes >= 0, bytes < Double(Int64.max) {
            length.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if !length.isEmpty { out.append(("Length", length.joined(separator: " · "))) }
        out.append(("Channel", item.channel_name ?? "Channel unavailable"))
        if item.is_partial == 1 { out.append(("Partial", "The beginning may be missing")) }
        return out
    }

    /// The state pill: "Recorded", "Recording now", "Preparing", "Failed".
    static func state(_ item: Recording) -> String {
        switch item.status {
        case "recording": "Recording now"
        case "completed": item.isPreparingForPlayback ? "Preparing" : "Recorded"
        case "failed": "Failed"
        default: item.status.capitalized
        }
    }
}

struct RecordingView: View {
    /// Not observed (audit R05): the stores this page draws from are below.
    let model: BrowseModel
    /// The app's presentation layer: its Undo toast (Apple 122).
    let presenter: AppPresenter
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    let original: Recording
    @State private var playing: RecordingPlay?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: BrowseModel, presenter: AppPresenter, original: Recording) {
        self.model = model
        self.presenter = presenter
        self.original = original
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    private var item: Recording { model.recordings.first { $0.id == original.id } ?? original }
    private var progress: RecordingProgress { model.progress(for: item) }
    private var teams: [RecordTeam]? { RecordingTeams.match(title: item.title, games: model.sportFront.front?.games ?? []) }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if compact { phone } else { wide }
        }
        .background(PigPageBackground())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.view")
        .fullScreenCover(item: $playing) { play in
            RecordingPlayerScreen(recording: play.recording, client: model.client, fromStart: play.fromStart, fromLive: play.fromLive) {
                Task { await model.loadRecordings() }
            }
        }
        .closesForOutsidePlay { playing = nil } // #179
    }

    // MARK: Layouts

    /// Apple TV and iPad: the art over the top of the page, the info bar under it.
    private var wide: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                art(badge: ViewMetrics.badge)
                    .frame(height: geometry.size.height * ViewMetrics.artShare)
                    .overlay(alignment: .topTrailing) { statePill.padding(.top, ViewMetrics.pillTop).padding(.trailing, ViewMetrics.padding.trailing) }
                HStack(alignment: .center, spacing: PigSpacing.empty) {
                    VStack(alignment: .leading, spacing: PigSpacing.s) {
                        header
                        actionRow
                        messages
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    facts.frame(width: ViewMetrics.factsWidth, alignment: .leading)
                }
                .padding(ViewMetrics.padding)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        // The art runs edge to edge; the info bar keeps its own margins (the TV's title-safe 96 pt).
        #if os(tvOS)
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(edges: .top)
        #endif
    }

    /// iPhone: the art, then one column.
    private var phone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                art(badge: ViewMetrics.phoneBadge)
                    .frame(height: ViewMetrics.phoneArtHeight)
                    .overlay(alignment: .bottomTrailing) { statePill.padding(PigSpacing.s) }
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    header
                    primary.frame(maxWidth: .infinity)
                    HStack(spacing: PigSpacing.s) { secondary }
                    messages
                    facts.padding(.top, PigSpacing.xs)
                }
                .padding(.horizontal, PigSpacing.m)
            }
            .padding(.bottom, PigSpacing.l)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Parts

    private func art(badge: CGFloat) -> some View {
        RecordingArt(item: item, teams: teams, client: model.client, badge: badge)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    private var statePill: some View {
        Text(RecordingFacts.state(item)).font(ViewMetrics.pill)
            .foregroundStyle(item.status == "recording" ? Color.pigDanger : Color.pigSecondary)
            .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            .pigTranslucentBackground(Capsule())
            .accessibilityIdentifier("recording.state")
    }

    @ViewBuilder
    private var header: some View {
        let eyebrow = RecordingFacts.eyebrow(item)
        if !eyebrow.isEmpty {
            Text(eyebrow).font(ViewMetrics.eyebrow).tracking(1.2).foregroundStyle(.secondary)
                .pigFigures().lineLimit(2)
        }
        Text(item.title).font(ViewMetrics.title).lineLimit(2).pigMinimumScale(0.7, size: PigType.hero)
            .accessibilityAddTraits(.isHeader)
        if let fraction = progress.fraction {
            HStack(spacing: PigSpacing.m) {
                PigProgressBar(fraction: fraction, height: 8).frame(maxWidth: ViewMetrics.barWidth)
                if let position = RecordingFacts.position(item, progress: progress) {
                    Text(compact ? "\(DetailText.duration((item.duration_sec ?? 0) * (1 - fraction))) left" : position)
                        .font(ViewMetrics.detail).pigFigures().foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Int((fraction * 100).rounded())) percent watched")
        }
        if item.isPreparingForPlayback {
            Text("Preparing for playback…").font(ViewMetrics.detail).foregroundStyle(.secondary)
        } else if item.playLabel == nil {
            Text(item.canWatchFromStart ? "Still recording: watch it from the start while the rest records."
                 : "Playback is available once the recording has finished.").font(ViewMetrics.detail).foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: PigSpacing.m) {
            primary
            secondary
        }
        .padding(.top, PigSpacing.m)
        .defaultFocus($playFocused, true)
        .tvFocusSection()
    }

    @ViewBuilder
    private var primary: some View {
        if item.playLabel != nil {
            Button { playing = RecordingPlay(recording: item) } label: {
                Label(progress.fraction == nil ? "Play" : "Resume", systemImage: "play.fill").frame(maxWidth: compact ? .infinity : nil)
            }
            .pigPrimaryButton()
            .focused($playFocused)
            .accessibilityIdentifier("recording.play")
        } else if item.canWatchFromStart {
            Button { playing = RecordingPlay(recording: item, fromStart: true) } label: {
                Label("Watch from start", systemImage: "play.fill").frame(maxWidth: compact ? .infinity : nil)
            }
            .pigPrimaryButton()
            .focused($playFocused)
            .accessibilityIdentifier("recording.watchFromStart")
            // #17: the same recording, joined near its live edge, with everything before it to rewind into.
            Button { playing = RecordingPlay(recording: item, fromLive: true) } label: {
                Label(RecordingLiveEdge.title, systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: compact ? .infinity : nil)
            }
            .accessibilityIdentifier("recording.playFromLive")
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if item.status == "completed" {
            Button { Task { await model.detectAds(item) } } label: {
                Text("Find breaks").frame(maxWidth: compact ? .infinity : nil)
            }
            .disabled(model.mutationBusy || item.ad_detect_status == "running" || item.ad_detect_status == "pending")
            .accessibilityIdentifier("recording.findBreaks")
        }
        // Apple 122 (D-44 point 9): at once, with the 10 s Undo; the page closes. The server stops a recording still
        // being made before deleting it.
        Button(role: .destructive) {
            model.deleteWithUndo(item, presenter: presenter)
            dismiss()
        } label: {
            Text("Delete").foregroundStyle(Color.pigDanger).frame(maxWidth: compact ? .infinity : nil)
        }
        .disabled(model.mutationBusy)
        .accessibilityLabel("Delete \(item.title)")
        .accessibilityIdentifier("recording.delete")
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.actionError {
            Text(error).font(ViewMetrics.detail).foregroundStyle(Color.pigDanger)
        } else if let message = model.actionMessage {
            Text(message).font(ViewMetrics.detail).foregroundStyle(.secondary)
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
            ForEach(RecordingFacts.facts(item), id: \.0) { fact in
                GridRow {
                    Text(fact.0).foregroundStyle(.secondary)
                    Text(fact.1).fontWeight(.semibold).pigFigures()
                }
                .font(ViewMetrics.fact)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("recording.facts")
    }
}
