import SwiftUI

// D-44 batch 5 (Apple 119, R5-Recordings-*): the Recordings tab. No library: the featured recording across the top
// (Continue, else the newest), the rest as large cards, and Coming up as a slim strip at the bottom whose "All ›" opens
// Scheduled. The iPhone draws the same recordings as a swipeable card stack, with Coming up as a fixed card at the
// bottom that opens Scheduled. What it lists is `RecordingsHome` (pure, tested).

/// Sizes for the Recordings tab.
enum RecordingsMetrics {
    #if os(tvOS)
    static let pagePadding: CGFloat = 40
    static let gap: CGFloat = 28
    static let featuredArtWidth: CGFloat = 760
    static let featuredArtHeight: CGFloat = 428
    static let featuredBadge: CGFloat = 170
    static let cardWidth: CGFloat = 330
    static let cardBadge: CGFloat = 70
    static let spacing: CGFloat = 22
    static let kicker: Font = .system(size: 19, weight: .bold)
    static let featuredTitle: Font = .system(size: 56, weight: .heavy)
    static let featuredMeta: Font = .system(size: 23)
    static let title: Font = .system(size: 22, weight: .semibold)
    static let detail: Font = .system(size: 18)
    static let strip: Font = .system(size: 18)
    static let stripLabel: Font = .system(size: 16, weight: .heavy)
    #else
    static let pagePadding: CGFloat = 20
    static let gap: CGFloat = 18
    static let featuredArtWidth: CGFloat = 500
    static let featuredArtHeight: CGFloat = 282
    static let featuredBadge: CGFloat = 120
    static let cardWidth: CGFloat = 250
    static let cardBadge: CGFloat = 46
    static let spacing: CGFloat = 14
    static let kicker: Font = .caption.weight(.bold)
    static let featuredTitle: Font = .largeTitle.weight(.heavy)
    static let featuredMeta: Font = .callout
    static let title: Font = .subheadline.weight(.semibold)
    static let detail: Font = .caption
    static let strip: Font = .subheadline
    static let stripLabel: Font = .caption.weight(.bold)
    #endif
    static let radius = PigRadius.card
    static let artRatio: CGFloat = 16 / 9
}

/// Where the Recordings tab's stack goes: Scheduled, or a recording (by id, so a refreshed list keeps the page).
enum RecordingsRoute: Hashable {
    case scheduled
    /// The iPhone's pages under Scheduled's tiles.
    case rules
    case attention
    case recording(Int)
}

/// A recording to play: resumed (the player asks), or the one being made from its start (C-L).
struct RecordingPlay: Identifiable {
    let recording: Recording
    var fromStart = false
    var id: String { "\(recording.id)|\(fromStart)" }
}

struct RecordingsView: View {
    /// Not observed (audit R05): it draws the recordings store and the action state, and nothing else BrowseModel holds.
    let model: BrowseModel
    /// The app's presentation layer: its Undo toast (Apple 122).
    let presenter: AppPresenter
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var path: [RecordingsRoute] = RecordingsView.initialPath
    @State private var playing: RecordingPlay?
    /// The iPhone's card stack: the recording shown.
    @State private var page: Int?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: BrowseModel, presenter: AppPresenter) {
        self.model = model
        self.presenter = presenter
        _store = ObservedObject(wrappedValue: model.recordingStore)
        _actions = ObservedObject(wrappedValue: model.actions)
    }

    /// The offline fixture can open on Scheduled (PIGTV_UI_TEST_RECORDINGS_SECTION=scheduled, DEBUG only).
    private static var initialPath: [RecordingsRoute] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_RECORDINGS_SECTION"] == "scheduled" { return [.scheduled] }
        #endif
        return []
    }

    private var shelf: [Recording] { RecordingsHome.shelf(model.recordings, hidden: store.pendingRemovals) }
    private var featured: Recording? { RecordingsHome.featured(shelf) { model.progress(for: $0) } }
    private var cards: [Recording] { RecordingsHome.cards(shelf, featured: featured) }
    private var comingUp: [ScheduledRecording] { RecordingsHome.comingUp(model.schedules, hidden: store.pendingRemovals) }
    /// The game recordings' teams come from the Sport data already loaded (C-R cards).
    private var games: [SportsGame] { model.sportFront.front?.games ?? [] }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if compact { stack } else { wide }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .pigPageBackdrop()
            .navigationDestination(for: RecordingsRoute.self) { route in
                switch route {
                case .scheduled: ScheduledPage(model: model, presenter: presenter)
                case .rules, .attention: ScheduledSubpage(model: model, presenter: presenter, route: route)
                case .recording(let id):
                    if let item = model.recordings.first(where: { $0.id == id }) { RecordingView(model: model, presenter: presenter, original: item) }
                }
            }
            // Build 31: only when older than a minute. The tvOS remote has no pull-to-refresh, so there it reloads on
            // every appearance (anything older than 10 s).
            #if os(tvOS)
            .task { await model.loadRecordingsIfStale(maxAge: 10) }
            #else
            .task { await model.loadRecordingsIfStale() }
            #endif
            // Review F6: while the page is on screen it keeps itself current, quietly; it stops when it is not visible.
            .whileVisible {
                while !Task.isCancelled {
                    let wait = RecordingsRows.refreshInterval(recordings: model.recordings, schedules: model.schedules, now: Date())
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    await model.loadRecordings(quietly: true)
                }
            }
            .fullScreenCover(item: $playing) { play in
                RecordingPlayerScreen(recording: play.recording, client: model.client, fromStart: play.fromStart) {
                    Task { await model.loadRecordings() }
                }
            }
            .closesForOutsidePlay { playing = nil } // #179
        }
    }

    /// Apple 121: View recording is a page on the tab's stack.
    private func open(_ item: Recording) { path.append(.recording(item.id)) }

    @ViewBuilder
    private var status: some View {
        if let error = model.recordingsError {
            RetryBanner(message: error) { Task { await model.loadRecordings() } }
        }
        if let message = model.actionMessage {
            Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal, RecordingsMetrics.pagePadding)
        }
        if let error = model.actionError {
            Text(error).foregroundStyle(.secondary).padding(.horizontal, RecordingsMetrics.pagePadding)
        }
    }

    // MARK: Apple TV and iPad

    private var wide: some View {
        VStack(alignment: .leading, spacing: 12) {
            PigPageHeader(title: "Recordings")
            status
            ScrollView {
                VStack(alignment: .leading, spacing: RecordingsMetrics.gap) {
                    if let featured {
                        FeaturedRecording(item: featured, progress: model.progress(for: featured),
                                          teams: RecordingTeams.match(title: featured.title, games: games),
                                          client: model.client, canWatchFromStart: canWatchFromStart(featured),
                                          play: { playing = RecordingPlay(recording: featured, fromStart: $0) },
                                          details: { open(featured) },
                                          delete: { model.deleteWithUndo(featured, presenter: presenter) })
                            .tvFocusSection()
                    } else if !model.recordingsBusy {
                        RecordingsEmpty()
                    }
                    if !cards.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            PigSectionHeader(title: "Ready to watch")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: RecordingsMetrics.spacing) {
                                    ForEach(cards) { item in
                                        RecordingCard(item: item, progress: model.progress(for: item),
                                                      teams: RecordingTeams.match(title: item.title, games: games),
                                                      client: model.client) { open(item) }
                                            .frame(width: RecordingsMetrics.cardWidth)
                                    }
                                }
                                .padding(.vertical, 12).padding(.horizontal, 4)
                            }
                            .scrollClipDisabled()
                        }
                        .tvFocusSection()
                    }
                    #if os(tvOS)
                    ComingUpStrip(items: comingUp, now: Date()) { path.append(.scheduled) }
                        .tvFocusSection()
                    #endif
                    if model.recordingsBusy { ProgressView("Refreshing recordings…") }
                }
                .padding(.horizontal, RecordingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
            #if !os(tvOS)
            .refreshable { await model.loadRecordings() }
            #endif
        }
        #if !os(tvOS)
        .safeAreaInset(edge: .bottom) {
            ComingUpStrip(items: comingUp, now: Date()) { path.append(.scheduled) }
                .padding(.horizontal, RecordingsMetrics.pagePadding).padding(.bottom, 8)
        }
        #endif
    }

    private func canWatchFromStart(_ item: Recording) -> Bool {
        item.canWatchFromStart && model.client.info?.features.recordingWatchLive == true
    }

    // MARK: iPhone

    private var all: [Recording] { featured.map { [$0] + cards } ?? cards }

    @ViewBuilder
    private var stack: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 8) {
            PigPageHeader(title: "Recordings") {
                if all.count > 1 {
                    Text("\((all.firstIndex { $0.id == page } ?? 0) + 1) of \(all.count)")
                        .font(.subheadline.monospacedDigit()).fontDesign(.rounded).foregroundStyle(.secondary)
                        .accessibilityIdentifier("recordings.stack.position")
                }
            }
            status
            if all.isEmpty {
                if !model.recordingsBusy { RecordingsEmpty().padding(.horizontal, RecordingsMetrics.pagePadding) }
                Spacer()
            } else {
                TabView(selection: Binding(get: { page ?? all.first?.id }, set: { page = $0 })) {
                    ForEach(all) { item in
                        RecordingStackCard(item: item, progress: model.progress(for: item),
                                           teams: RecordingTeams.match(title: item.title, games: games), client: model.client,
                                           canWatchFromStart: canWatchFromStart(item),
                                           play: { playing = RecordingPlay(recording: item, fromStart: $0) },
                                           details: { open(item) })
                            .padding(.horizontal, 28).padding(.bottom, 40)
                            .tag(Optional(item.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .accessibilityIdentifier("recordings.stack")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComingUpCard(items: comingUp, now: Date()) { path.append(.scheduled) }
        }
        .refreshable { await model.loadRecordings() }
        #endif
    }
}

/// Nothing recorded yet (always drawn: Mark's rule for every page).
private struct RecordingsEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No recordings yet").font(RecordingsMetrics.title)
            Text("Choose a programme in the TV Guide, or a game in Sport, and record it. It shows here once it starts.")
                .font(RecordingsMetrics.detail).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recordings.empty")
    }
}

// MARK: Art

/// A recording's art: the two teams' badges for a game ("A v B"), else the programme's artwork (C-N), else the channel's
/// logo, else the channel's name. Never a frame grab, which could spoil a result.
struct RecordingArt: View {
    let item: Recording
    let teams: [RecordTeam]?
    let client: APIClient
    var badge: CGFloat = RecordingsMetrics.cardBadge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.logoTile(scheme)
            if let teams, teams.count == 2 {
                HStack(spacing: badge * 0.3) {
                    SportBadge(name: teams[0].name, logo: teams[0].logo, league: "", client: client, size: badge)
                    Text("v").font(.system(size: badge * 0.3, weight: .heavy)).foregroundStyle(.secondary)
                    SportBadge(name: teams[1].name, logo: teams[1].logo, league: "", client: client, size: badge)
                }
            } else if item.image != nil {
                ChannelArtwork(logo: item.image, client: client, fill: true)
            } else if item.channel_logo != nil {
                ChannelArtwork(logo: item.channel_logo, client: client).padding(.horizontal, badge * 0.5).padding(.vertical, badge * 0.3)
            } else {
                Text(item.channel_name ?? item.title).font(.system(size: badge * 0.4, weight: .heavy))
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "REC · NOW" on a recording being made.
private struct RecNowBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.pigDanger).frame(width: 9, height: 9)
            Text("REC · NOW")
        }
        .font(CardBadgeFont.font)
        .foregroundStyle(Color.pigDanger)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.pigCanvas, in: RoundedRectangle(cornerRadius: PigRadius.inner))
    }
}

private enum CardBadgeFont {
    #if os(tvOS)
    static let font: Font = .system(size: 15, weight: .heavy)
    #else
    static let font: Font = .caption2.weight(.heavy)
    #endif
}

/// The accessibility label shared by a recording's card and featured block.
nonisolated enum RecordingLabel {
    static func text(_ item: Recording, progress: RecordingProgress) -> String {
        var parts = [item.title, item.channel_name ?? "channel unavailable"]
        if let duration = item.duration_sec, duration > 0 { parts.append(DetailText.duration(duration)) }
        if item.status == "recording" { parts.append("recording now") }
        else if item.isPreparingForPlayback { parts.append("preparing for playback") }
        else if progress.watched { parts.append("watched") }
        else if let fraction = progress.fraction { parts.append("\(Int((fraction * 100).rounded())) percent watched") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Featured

/// The featured recording (Apple TV, iPad): its art with the resume bar, the kicker, title and line, and its actions.
private struct FeaturedRecording: View {
    let item: Recording
    let progress: RecordingProgress
    let teams: [RecordTeam]?
    let client: APIClient
    let canWatchFromStart: Bool
    let play: (_ fromStart: Bool) -> Void
    let details: () -> Void
    /// Apple 122: at once, with Undo.
    let delete: () -> Void
    @FocusState private var primaryFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: RecordingsMetrics.gap * 1.6) {
            RecordingArt(item: item, teams: teams, client: client, badge: RecordingsMetrics.featuredBadge)
                .frame(width: RecordingsMetrics.featuredArtWidth, height: RecordingsMetrics.featuredArtHeight)
                .clipShape(RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let fraction = progress.fraction {
                        PigProgressBar(fraction: fraction, height: 8).padding(24)
                    }
                }
                .overlay(alignment: .topLeading) { if item.status == "recording" { RecNowBadge().padding(16) } }
            VStack(alignment: .leading, spacing: 12) {
                Text(RecordingsHome.kicker(item, progress: progress, now: Date()))
                    .font(RecordingsMetrics.kicker).tracking(1).foregroundStyle(Color.pigAccentText)
                Text(item.title).font(RecordingsMetrics.featuredTitle).lineLimit(2).minimumScaleFactor(0.7)
                Text(RecordingsHome.meta(item, progress: progress))
                    .font(RecordingsMetrics.featuredMeta.monospacedDigit()).fontDesign(.rounded).foregroundStyle(.secondary)
                if item.isPreparingForPlayback {
                    Text("Preparing for playback…").font(RecordingsMetrics.featuredMeta).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if let label = item.playLabel {
                        Button(progress.fraction == nil ? "Play" : "Resume", systemImage: "play.fill") { play(false) }
                            .pigPrimaryButton()
                            .focused($primaryFocused)
                            .accessibilityLabel(progress.fraction == nil ? label : "Resume \(item.title)")
                            .accessibilityIdentifier("recordings.featured.play")
                    } else if canWatchFromStart {
                        Button("Watch from start", systemImage: "play.fill") { play(true) }
                            .pigPrimaryButton()
                            .focused($primaryFocused)
                            .accessibilityIdentifier("recordings.featured.watchFromStart")
                    }
                    Button("Details") { details() }
                        .accessibilityLabel("Details of \(item.title)")
                        .accessibilityIdentifier("recordings.featured.details")
                    Button { delete() } label: { Text("Delete").foregroundStyle(Color.pigDanger) }
                        .accessibilityLabel("Delete \(item.title)")
                        .accessibilityIdentifier("recordings.featured.delete")
                }
                .padding(.top, 14)
                .defaultFocus($primaryFocused, true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecordingLabel.text(item, progress: progress))
        .accessibilityIdentifier("recordings.featured")
    }
}

// MARK: Cards

/// A recording as a large card: its art (REC · NOW, Watched), title, line and resume bar.
private struct RecordingCard: View {
    let item: Recording
    let progress: RecordingProgress
    let teams: [RecordTeam]?
    let client: APIClient
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RecordingArt(item: item, teams: teams, client: client)
                    .aspectRatio(RecordingsMetrics.artRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
                    .overlay(alignment: .topLeading) { if item.status == "recording" { RecNowBadge().padding(8) } }
                    .overlay(alignment: .topTrailing) {
                        if progress.watched {
                            Text("Watched").font(CardBadgeFont.font).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.pigCanvas, in: RoundedRectangle(cornerRadius: PigRadius.inner))
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(RecordingsMetrics.title).lineLimit(1)
                    if item.isPreparingForPlayback {
                        Text("Preparing for playback…").font(RecordingsMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(RecordingsHome.meta(item, progress: progress))
                            .font(RecordingsMetrics.detail.monospacedDigit()).fontDesign(.rounded)
                            .foregroundStyle(item.status == "recording" ? Color.pigDanger : Color.pigSecondary).lineLimit(1)
                    }
                    PigProgressBar(fraction: progress.fraction ?? 0, height: 5)
                        .opacity(progress.fraction == nil ? 0 : 1)
                }
                .padding(.horizontal, 2)
            }
            .padding(10)
            .opacity(progress.watched ? 0.55 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: RecordingsMetrics.radius))
        .accessibilityLabel(RecordingLabel.text(item, progress: progress))
    }
}

// MARK: Coming up

/// The slim strip at the bottom (Apple TV, iPad): COMING UP, the next few schedules (a clash outlined in amber), and
/// "All ›", which opens Scheduled; so does every chip.
private struct ComingUpStrip: View {
    let items: [ScheduledRecording]
    let now: Date
    let open: () -> Void

    #if os(tvOS)
    private let shown = 4
    #else
    private let shown = 3
    #endif

    var body: some View {
        HStack(spacing: 10) {
            Text("COMING UP").font(RecordingsMetrics.stripLabel).tracking(1.2).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text("Nothing scheduled").font(RecordingsMetrics.strip).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(shown)) { item in
                let clash = RecordingsHome.clashes(item)
                Button(action: open) {
                    HStack(spacing: 10) {
                        Text(RecordingsHome.chip(item, now: now))
                            .monospacedDigit().fontDesign(.rounded)
                            .foregroundStyle(clash ? Color.pigWarning : Color.pigSecondary)
                        Text(item.title).fontWeight(.bold).lineLimit(1)
                    }
                    .font(RecordingsMetrics.strip)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay {
                        if clash { RoundedRectangle(cornerRadius: PigRadius.compact).strokeBorder(Color.pigWarning, lineWidth: 2) }
                    }
                }
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.compact))
                .accessibilityLabel("\(item.title), \(RecordingsHome.chip(item, now: now))")
                .accessibilityIdentifier("recordings.comingUp.item")
            }
            Spacer(minLength: 0)
            Button(action: open) {
                Text(items.isEmpty ? "All ›" : "All \(items.count) ›").font(RecordingsMetrics.strip.weight(.bold))
                    .foregroundStyle(Color.pigAccentText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: PigRadius.compact))
            .accessibilityLabel("All scheduled recordings")
            .accessibilityIdentifier("recordings.comingUp.all")
        }
        .padding(.leading, 22).padding(.trailing, 10).padding(.vertical, 10)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.comingUp")
    }
}

#if os(iOS)
/// The iPhone's Coming up: a fixed card at the bottom; a tap opens Scheduled.
private struct ComingUpCard: View {
    let items: [ScheduledRecording]
    let now: Date
    let open: () -> Void

    private var clashes: Int { items.filter(RecordingsHome.clashes).count }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(items.isEmpty ? "Coming up" : "Coming up · \(items.count)").font(.headline.weight(.heavy))
                    Spacer()
                    if clashes > 0 {
                        Text(clashes == 1 ? "1 clash" : "\(clashes) clashes").font(.footnote.weight(.bold))
                            .foregroundStyle(Color.pigWarning)
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let next = items.first {
                    HStack(spacing: 10) {
                        Text(RecordingsHome.when(next.start, now: now)).font(.subheadline.monospacedDigit()).fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                        Text(next.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    }
                } else {
                    Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color("PigText"))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
            .shadow(color: Color.pigShadow.opacity(0.3), radius: 14, y: -6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .accessibilityLabel(items.first.map { "Coming up, \(items.count) scheduled. Next: \($0.title), \(RecordingsHome.when($0.start, now: now))" }
                            ?? "Coming up, nothing scheduled")
        .accessibilityHint("Opens Scheduled")
        .accessibilityIdentifier("recordings.comingUp.card")
    }
}

/// One card of the iPhone's stack: the art with Continue, the resume bar, the kicker and title, and Play/Resume and
/// a More menu.
private struct RecordingStackCard: View {
    let item: Recording
    let progress: RecordingProgress
    let teams: [RecordTeam]?
    let client: APIClient
    let canWatchFromStart: Bool
    let play: (_ fromStart: Bool) -> Void
    let details: () -> Void

    private var kicker: String {
        var parts: [String] = []
        if let started = item.started { parts.append(started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        if let channel = item.channel_name { parts.append(channel) }
        return parts.joined(separator: " · ").uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: details) {
                RecordingArt(item: item, teams: teams, client: client, badge: 110)
                    .overlay(alignment: .topLeading) {
                        if item.status == "recording" {
                            RecNowBadge().padding(14)
                        } else if let fraction = progress.fraction, let duration = item.duration_sec {
                            Text("Continue · \(DetailText.duration(duration * (1 - fraction))) left")
                                .font(.caption.weight(.bold)).foregroundStyle(Color.pigAccentText)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.pigAccent.opacity(0.18), in: Capsule())
                                .padding(14)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(RecordingLabel.text(item, progress: progress))
            .accessibilityHint("Opens the recording")
            PigProgressBar(fraction: progress.fraction ?? 0, height: 4).opacity(progress.fraction == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).lineLimit(1)
                Text(item.title).font(.title3.weight(.heavy)).lineLimit(2)
                HStack(spacing: 8) {
                    if item.playLabel != nil {
                        Button { play(false) } label: {
                            Label(progress.fraction == nil ? "Play" : "Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .pigPrimaryButton()
                    } else if canWatchFromStart {
                        Button { play(true) } label: {
                            Label("Watch from start", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .pigPrimaryButton()
                    } else {
                        Text(item.isPreparingForPlayback ? "Preparing for playback…" : "Plays once it has finished")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: details) {
                        Image(systemName: "ellipsis").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Details of \(item.title)")
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface)
        }
        .background(Color.pigRaised)
        .clipShape(RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .shadow(color: Color.pigShadow.opacity(0.4), radius: 20, y: 12)
    }
}
#endif
