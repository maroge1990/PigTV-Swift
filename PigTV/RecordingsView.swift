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
    static let spacing: CGFloat = PigSpacing.l
    static let kicker: Font = .system(size: PigType.secondary, weight: .bold)
    static let featuredTitle: Font = .system(size: PigType.hero, weight: .heavy)
    static let featuredMeta: Font = .system(size: PigType.body)
    static let title: Font = .system(size: PigType.body, weight: .semibold)
    static let detail: Font = .system(size: PigType.caption)
    static let strip: Font = .system(size: PigType.caption)
    static let stripLabel: Font = .system(size: PigType.caption, weight: .heavy)
    #else
    static let pagePadding: CGFloat = 20
    static let gap: CGFloat = 18
    static let featuredArtWidth: CGFloat = 500
    static let featuredArtHeight: CGFloat = 282
    static let featuredBadge: CGFloat = 120
    static let cardWidth: CGFloat = 250
    static let cardBadge: CGFloat = 46
    static let spacing: CGFloat = PigSpacing.l
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
    /// #229 (Mark, 4 Nov 2026): the iPhone's recording card, empty card and Coming up card share one edge, the page
    /// header's (PigPageHeaderMetrics.edge). Before Apple 149 they sat 28, 20 and 12 pt in: three widths.
    static let phoneEdge: CGFloat = 16
    /// The iPhone recording card's height while the first answer loads (a placeholder of the card's size, no jump).
    static let phoneCardHeight: CGFloat = 420
    /// #280: the Coming up strip's and the iPhone's Coming up card's heights, for their placeholders while loading.
    #if os(tvOS)
    static let comingUpStripHeight: CGFloat = 78
    #else
    static let comingUpStripHeight: CGFloat = 52
    #endif
    static let comingUpCardHeight: CGFloat = 84
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
    /// #17: near the live edge of the one being made.
    var fromLive = false
    var id: String { "\(recording.id)|\(fromStart)|\(fromLive)" }
}

struct RecordingsView: View {
    /// Not observed (audit R05): it draws the recordings store and the action state, and nothing else BrowseModel holds.
    let model: BrowseModel
    /// The app's presentation layer: its Undo toast (Apple 122).
    let presenter: AppPresenter
    /// #280: the empty pages' one action, Open the TV Guide (the tab bar's Guide tab).
    var openGuide: () -> Void = {}
    @ObservedObject private var store: RecordingsStore
    @ObservedObject private var actions: ActionState
    @State private var path: [RecordingsRoute] = RecordingsView.initialPath
    @State private var playing: RecordingPlay?
    /// The iPhone's card stack: the recording shown.
    @State private var page: Int?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: BrowseModel, presenter: AppPresenter, openGuide: @escaping () -> Void = {}) {
        self.model = model
        self.presenter = presenter
        self.openGuide = openGuide
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
                case .scheduled: ScheduledPage(model: model, presenter: presenter, openGuide: openGuide)
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
                    model.notePolls(recordingsAfter: .seconds(wait), guideAfter: nil) // #280: a failed page's countdown
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    // #239: through the shared staleness check (AppFreshness may have just loaded them)
                    await model.loadRecordingsIfStale(maxAge: max(1, wait - 1), quietly: true)
                }
            }
            .fullScreenCover(item: $playing) { play in
                RecordingPlayerScreen(recording: play.recording, client: model.client, fromStart: play.fromStart, fromLive: play.fromLive) {
                    Task { await model.loadRecordings() }
                }
            }
            .closesForOutsidePlay { playing = nil } // #179
        }
    }

    /// Apple 121: View recording is a page on the tab's stack.
    private func open(_ item: Recording) { path.append(.recording(item.id)) }

    /// #280: what the page shows (the model's answer, not worked out here): the list is empty when nothing is recorded.
    private var state: PageState { model.recordingsState(isEmpty: shelf.isEmpty) }

    @ViewBuilder
    private var status: some View {
        if case .stale(let since) = state {
            PigStaleNotice(since: since, retry: { await model.loadRecordings() }, identifier: "recordings.stale")
                .padding(.horizontal, compact ? RecordingsMetrics.phoneEdge : RecordingsMetrics.pagePadding)
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
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            PigPageHeader(title: "Recordings")
            status
            ScrollView {
                VStack(alignment: .leading, spacing: RecordingsMetrics.gap) {
                    switch state {
                    case .loading:
                        RecordingsPlaceholder()
                        #if os(tvOS)
                        ComingUpPlaceholder()
                        #endif
                    case .failed(let failure):
                        PigErrorState(failure: failure, retry: { await model.loadRecordings() }, identifier: "recordings.error",
                                      schedule: store.schedule)
                            .pigStateFillsPage()
                    case .empty:
                        RecordingsEmpty(openGuide: openGuide).pigStateFillsPage()
                        #if os(tvOS)
                        ComingUpStrip(items: comingUp, now: Date()) { path.append(.scheduled) }
                            .tvFocusSection()
                        #endif
                    case .content, .stale:
                        wideContent
                    }
                }
                .padding(.horizontal, RecordingsMetrics.pagePadding)
                .padding(.bottom, PigSpacing.l)
            }
            #if !os(tvOS)
            .refreshable { await model.loadRecordings() }
            #endif
        }
        #if !os(tvOS)
        .safeAreaInset(edge: .bottom) {
            Group {
                switch state {
                case .loading: ComingUpPlaceholder()
                case .failed: EmptyView()
                default: ComingUpStrip(items: comingUp, now: Date()) { path.append(.scheduled) }
                }
            }
            .padding(.horizontal, RecordingsMetrics.pagePadding).padding(.bottom, PigSpacing.s)
        }
        #endif
    }

    /// The recordings (the layout batch K settled), current or with the stale notice above.
    @ViewBuilder
    private var wideContent: some View {
                    if let featured {
                        FeaturedRecording(item: featured, progress: model.progress(for: featured),
                                          teams: RecordingTeams.match(title: featured.title, games: games),
                                          client: model.client, canWatchFromStart: featured.canWatchFromStart,
                                          play: { playing = RecordingPlay(recording: featured, fromStart: $0) },
                                          playFromLive: { playing = RecordingPlay(recording: featured, fromLive: true) },
                                          details: { open(featured) },
                                          delete: { model.deleteWithUndo(featured, presenter: presenter) })
                            .tvFocusSection()
                    }
                    if !cards.isEmpty {
                        VStack(alignment: .leading, spacing: PigSpacing.s) {
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
                                .padding(.vertical, PigSpacing.s).padding(.horizontal, PigSpacing.xs)
                            }
                            .scrollClipDisabled()
                        }
                        .tvFocusSection()
                    }
                    #if os(tvOS)
                    ComingUpStrip(items: comingUp, now: Date()) { path.append(.scheduled) }
                        .tvFocusSection()
                    #endif
    }

    // MARK: iPhone

    private var all: [Recording] { featured.map { [$0] + cards } ?? cards }

    @ViewBuilder
    private var stack: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            PigPageHeader(title: "Recordings") {
                if all.count > 1 {
                    Text("\((all.firstIndex { $0.id == page } ?? 0) + 1) of \(all.count)")
                        .font(.subheadline).pigFigures().foregroundStyle(.secondary)
                        .accessibilityIdentifier("recordings.stack.position")
                }
            }
            status
            switch state {
            case .loading:
                // #229, #280: while the first answer loads, the recording card's shape where it will be, so nothing jumps;
                // then the recordings, E1 or the error, faded in.
                RecordingsPhonePlaceholder().padding(.horizontal, RecordingsMetrics.phoneEdge).transition(.opacity)
                Spacer()
            case .failed(let failure):
                ScrollView {
                    PigErrorState(failure: failure, retry: { await model.loadRecordings() }, identifier: "recordings.error",
                                  schedule: store.schedule)
                        .pigStateFillsPage()
                }
                .transition(.opacity)
            case .empty:
                ScrollView {
                    RecordingsEmpty(openGuide: openGuide).pigStateFillsPage()
                }
                .transition(.opacity)
            case .content, .stale:
                TabView(selection: Binding(get: { page ?? all.first?.id }, set: { page = $0 })) {
                    ForEach(all) { item in
                        RecordingStackCard(item: item, progress: model.progress(for: item),
                                           teams: RecordingTeams.match(title: item.title, games: games), client: model.client,
                                           canWatchFromStart: item.canWatchFromStart,
                                           play: { playing = RecordingPlay(recording: item, fromStart: $0) },
                                           details: { open(item) })
                            .padding(.horizontal, RecordingsMetrics.phoneEdge).padding(.bottom, PigSpacing.section)
                            .tag(Optional(item.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .accessibilityIdentifier("recordings.stack")
                .transition(.opacity)
            }
        }
        .pigAnimation(value: all.isEmpty)
        .pigAnimation(value: store.loaded)
        .safeAreaInset(edge: .bottom) {
            switch state {
            case .loading:
                ComingUpPlaceholder(card: true).padding(.horizontal, RecordingsMetrics.phoneEdge).padding(.bottom, PigSpacing.s)
            case .failed: EmptyView()
            default: ComingUpCard(items: comingUp, now: Date()) { path.append(.scheduled) }
            }
        }
        .refreshable { await model.loadRecordings() }
        #endif
    }
}

/// Nothing recorded yet (E1, #280): the pig, the words and Open the TV Guide, the page's one action.
private struct RecordingsEmpty: View {
    let openGuide: () -> Void
    var body: some View {
        PigEmptyState(title: PageWords.noRecordingsTitle, text: PageWords.noRecordingsText,
                      action: PigStateAction(label: PageWords.openGuide, run: openGuide), identifier: "recordings.empty")
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
                    Text("v").font(.system(size: max(PigType.minimum, badge * 0.3), weight: .heavy)).foregroundStyle(.secondary)
                    SportBadge(name: teams[1].name, logo: teams[1].logo, league: "", client: client, size: badge)
                }
            } else if item.image != nil {
                ChannelArtwork(logo: item.image, client: client, fill: true)
            } else if item.channel_logo != nil {
                ChannelArtwork(logo: item.channel_logo, client: client).padding(.horizontal, badge * 0.5).padding(.vertical, badge * 0.3)
            } else {
                Text(item.channel_name ?? item.title).font(.system(size: badge * 0.4, weight: .heavy))
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(PigSpacing.s)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "REC · NOW" on a recording being made.
private struct RecNowBadge: View {
    var body: some View {
        HStack(spacing: PigSpacing.xs) {
            Circle().fill(Color.pigDanger).frame(width: 9, height: 9)
            Text("REC · NOW")
        }
        .font(CardBadgeFont.font)
        .foregroundStyle(Color.pigDanger)
        .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
        .background(Color.pigCanvas, in: RoundedRectangle(cornerRadius: PigRadius.inner))
    }
}

private enum CardBadgeFont {
    #if os(tvOS)
    static let font: Font = .system(size: PigType.caption, weight: .heavy)
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
    /// #17: Play from live, beside Watch from start.
    let playFromLive: () -> Void
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
                        PigProgressBar(fraction: fraction, height: 8).padding(PigSpacing.l)
                    }
                }
                .overlay(alignment: .topLeading) { if item.status == "recording" { RecNowBadge().padding(PigSpacing.m) } }
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Text(RecordingsHome.kicker(item, progress: progress, now: Date()))
                    .font(RecordingsMetrics.kicker).tracking(1).foregroundStyle(Color.pigAccentText)
                Text(item.title).font(RecordingsMetrics.featuredTitle).lineLimit(2).pigMinimumScale(0.7, size: PigType.hero)
                Text(RecordingsHome.meta(item, progress: progress))
                    .font(RecordingsMetrics.featuredMeta).pigFigures().foregroundStyle(.secondary)
                if item.isPreparingForPlayback {
                    Text("Preparing for playback…").font(RecordingsMetrics.featuredMeta).foregroundStyle(.secondary)
                }
                HStack(spacing: PigSpacing.m) {
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
                        Button(RecordingLiveEdge.title, systemImage: "dot.radiowaves.left.and.right") { playFromLive() }
                            .accessibilityIdentifier("recordings.featured.playFromLive")
                    }
                    Button("Details") { details() }
                        .pigSecondaryButton()
                        .accessibilityLabel("Details of \(item.title)")
                        .accessibilityIdentifier("recordings.featured.details")
                    Button { delete() } label: { Text("Delete").foregroundStyle(Color.pigDanger) }
                        .pigSecondaryButton()
                        .accessibilityLabel("Delete \(item.title)")
                        .accessibilityIdentifier("recordings.featured.delete")
                }
                .padding(.top, PigSpacing.m)
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
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                RecordingArt(item: item, teams: teams, client: client)
                    .aspectRatio(RecordingsMetrics.artRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
                    .overlay(alignment: .topLeading) { if item.status == "recording" { RecNowBadge().padding(PigSpacing.s) } }
                    .overlay(alignment: .topTrailing) {
                        if progress.watched {
                            Text("Watched").font(CardBadgeFont.font).foregroundStyle(.secondary)
                                .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                                .background(Color.pigCanvas, in: RoundedRectangle(cornerRadius: PigRadius.inner))
                                .padding(PigSpacing.s)
                        }
                    }
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    Text(item.title).font(RecordingsMetrics.title).lineLimit(1)
                    if item.isPreparingForPlayback {
                        Text("Preparing for playback…").font(RecordingsMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(RecordingsHome.meta(item, progress: progress))
                            .font(RecordingsMetrics.detail).pigFigures()
                            .foregroundStyle(item.status == "recording" ? Color.pigDanger : Color.pigSecondary).lineLimit(1)
                    }
                    PigProgressBar(fraction: progress.fraction ?? 0, height: 5)
                        .opacity(progress.fraction == nil ? 0 : 1)
                }
                .padding(.horizontal, PigSpacing.xxs)
            }
            .padding(PigSpacing.s)
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
        HStack(spacing: PigSpacing.s) {
            Text("COMING UP").font(RecordingsMetrics.stripLabel).tracking(1.2).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text("Nothing scheduled").font(RecordingsMetrics.strip).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(shown)) { item in
                let clash = RecordingsHome.clashes(item)
                Button(action: open) {
                    HStack(spacing: PigSpacing.s) {
                        Text(RecordingsHome.chip(item, now: now))
                            .pigFigures()
                            .foregroundStyle(clash ? Color.pigWarning : Color.pigSecondary)
                        Text(item.title).fontWeight(.bold).lineLimit(1)
                    }
                    .font(RecordingsMetrics.strip)
                    .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
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
                Text(items.isEmpty ? "All ›" : "All \(items.count) ›").font(RecordingsMetrics.strip.weight(.bold)).pigFigures()
                    .foregroundStyle(Color.pigAccentText)
                    .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: PigRadius.compact))
            .accessibilityLabel("All scheduled recordings")
            .accessibilityIdentifier("recordings.comingUp.all")
        }
        .padding(.leading, PigSpacing.l).padding(.trailing, PigSpacing.s).padding(.vertical, PigSpacing.s)
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
            VStack(alignment: .leading, spacing: PigSpacing.s) {
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
                    HStack(spacing: PigSpacing.m) {
                        Text(RecordingsHome.when(next.start, now: now)).font(.subheadline).pigFigures()
                            .foregroundStyle(.secondary)
                        Text(next.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    }
                } else {
                    Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.pigText)
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
            .shadow(color: Color.pigShadow.opacity(0.3), radius: 14, y: -6)
        }
        .pigPressable()
        .padding(.horizontal, RecordingsMetrics.phoneEdge).padding(.bottom, PigSpacing.s)
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
                            RecNowBadge().padding(PigSpacing.l)
                        } else if let fraction = progress.fraction, let duration = item.duration_sec {
                            Text("Continue · \(DetailText.duration(duration * (1 - fraction))) left")
                                .font(.caption.weight(.bold)).foregroundStyle(Color.pigAccentText)
                                .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.xs)
                                .background(Color.pigAccent.opacity(0.18), in: Capsule())
                                .padding(PigSpacing.l)
                        }
                    }
            }
            .pigPressable()
            .accessibilityLabel(RecordingLabel.text(item, progress: progress))
            .accessibilityHint("Opens the recording")
            PigProgressBar(fraction: progress.fraction ?? 0, height: 4).opacity(progress.fraction == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                Text(kicker).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).lineLimit(1)
                Text(item.title).font(.title3.weight(.heavy)).lineLimit(2)
                HStack(spacing: PigSpacing.s) {
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
                    .pigSecondaryButton()
                    .accessibilityLabel("Details of \(item.title)")
                }
                .padding(.top, PigSpacing.s)
            }
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pigSurface)
        }
        .background(Color.pigRaised)
        .clipShape(RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .shadow(color: Color.pigShadow.opacity(0.4), radius: 20, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.stack.card")
    }
}
#endif
