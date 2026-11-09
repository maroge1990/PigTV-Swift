import SwiftUI
import Combine

// An event's pages (split out of SportView.swift in build 39): the screen-level presenter that owns
// them, the details page and the channel picker.

enum SportPage: String, Sendable {
    case details, channels
}

/// An open event page or channel picker.
struct SportPresentation: Identifiable {
    let event: SportEvent
    let page: SportPage
    var id: String { "\(event.id)|\(page.rawValue)" }
}

/// Owns the event page and channel picker for a whole screen (the Sport tab,
/// Home), so a card scrolled away, or a lazy cell recycled, cannot take an
/// open page with it. Cards call `open`/`play`; the screen's `sportPages`
/// presents. `close(then:)` keeps the old behaviour: the action runs once the
/// page has closed, since the player cannot present over a cover.
@MainActor
final class SportPresenter: ObservableObject {
    @Published var presented: SportPresentation?
    /// #234: a future game with no listing yet whose card was selected: the "Record when it's listed" question.
    @Published var future: SportsGame?
    /// Apple 154 (152 Codex round 1): an answer being saved (no second one meanwhile), a failure to show, and the answers
    /// saved since the cards were drawn (game id -> its rule id, or nil once removed), so a card changes at once.
    @Published private(set) var futureSaving = false
    @Published var futureError: String?
    @Published private(set) var futureAnswers: [String: SportFutureRecord.Answer] = [:]
    private var afterDismiss: (() -> Void)?
    private let app: AppModel
    /// D-39: the tab the screen belongs to ("sport-front", "tv"), recorded with every play started here.
    let origin: String?

    init(app: AppModel, origin: String? = nil) { self.app = app; self.origin = origin }

    func open(_ event: SportEvent, _ page: SportPage) { presented = SportPresentation(event: event, page: page) }
    func play(_ event: SportEvent) { app.playSportEvent(event, origin: origin) }

    /// #234: what selecting a card without a listing offers, if anything (the server must have `game` rules).
    func futureOffer(_ game: SportsGame) -> SportFutureRecord.Offer? {
        SportFutureRecord.offer(game, now: Date(), serverCan: app.browse?.client.info?.features.recordGameRules == true,
                                answered: futureAnswers[game.id])
    }
    /// The rule this card waits on, this device's answers first.
    func futureRule(_ game: SportsGame) -> Int? { SportFutureRecord.waiting(game, answered: futureAnswers[game.id]) }
    /// Asks; true when there was something to ask.
    @discardableResult
    func askFuture(_ game: SportsGame) -> Bool {
        guard futureOffer(game) != nil else { return false }
        future = game
        return true
    }
    /// The answer: add or remove the game's `game` rule (C-M). The card says so at its next refresh.
    func answerFuture(_ game: SportsGame) {
        guard let offer = futureOffer(game), let browse = app.browse else { return }
        guard !futureSaving, !browse.mutationBusy else {
            futureError = "PigTV is still saving another change. Try again in a moment."
            return
        }
        futureSaving = true
        Task {
            defer { futureSaving = false }
            switch offer {
            case .record:
                if let rule = await browse.addGameRule(game) { futureAnswers[game.id] = .init(basis: game.recordWhenListed?.ruleId, rule: rule) }
                else { futureError = browse.actionError ?? "It couldn't be set to record. Try again." }
            case .cancel(let id):
                if await browse.deleteRule(id: id) { futureAnswers[game.id] = .init(basis: game.recordWhenListed?.ruleId, rule: nil) }
                else { futureError = browse.actionError ?? "It couldn't be changed. Try again." }
            }
        }
    }

    func close(then action: @escaping () -> Void) {
        afterDismiss = action
        presented = nil
    }

    /// The cover's `onDismiss`.
    func dismissed() {
        let action = afterDismiss
        afterDismiss = nil
        guard let action else { return }
        app.withPlayOrigin(origin, action)
    }
}

private struct SportPresenterKey: EnvironmentKey {
    static let defaultValue: SportPresenter? = nil
}

extension EnvironmentValues {
    var sportPresenter: SportPresenter? {
        get { self[SportPresenterKey.self] }
        set { self[SportPresenterKey.self] = newValue }
    }
}

private struct SportPages: ViewModifier {
    let app: AppModel
    let browse: BrowseModel
    let clock: Date
    @StateObject private var presenter: SportPresenter

    init(app: AppModel, browse: BrowseModel, clock: Date, origin: String?) {
        self.app = app
        self.browse = browse
        self.clock = clock
        _presenter = StateObject(wrappedValue: SportPresenter(app: app, origin: origin))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.sportPresenter, presenter)
            // #234: a future game the guide does not list yet
            .confirmationDialog(presenter.future?.title ?? "", isPresented: Binding(get: { presenter.future != nil },
                                                                                  set: { if !$0 { presenter.future = nil } }),
                                titleVisibility: .visible, presenting: presenter.future) { game in
                let offer = presenter.futureOffer(game)
                Button(offer == .record ? SportFutureRecord.recordTitle : SportFutureRecord.cancelTitle,
                       role: offer == .record ? nil : .destructive) { presenter.answerFuture(game) }
                Button("Cancel", role: .cancel) {}
            } message: { game in
                Text(presenter.futureOffer(game) == .record
                     ? "It isn't in the TV guide yet. PigTV records it on its best channel as soon as it's listed."
                     : "It's set to record once it's listed in the TV guide.")
            }
            .alert("Not saved", isPresented: Binding(get: { presenter.futureError != nil }, set: { if !$0 { presenter.futureError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presenter.futureError ?? "")
            }
            .detailCover(item: $presenter.presented, onDismiss: presenter.dismissed) { presentation in
                switch presentation.page {
                case .details:
                    SportEventDetails(event: presentation.event, app: app, browse: browse, play: presenter.close(then:))
                case .channels:
                    SportChannelPicker(event: presentation.event, app: app, browse: browse, clock: clock,
                                       play: presenter.close(then:))
                }
            }
    }
}

extension View {
    /// Presents the Sport event page and channel picker for the cards below.
    /// `origin`: the tab, recorded with the plays started from these pages (D-39).
    func sportPages(app: AppModel, browse: BrowseModel, clock: Date, origin: String? = nil) -> some View {
        modifier(SportPages(app: app, browse: browse, clock: clock, origin: origin))
    }
}

/// One of an event's channels: logo, name (and number), quality. A live (or
/// about-to-start) event plays on select; an upcoming one on another channel
/// offers a choice (Record / Watch when it starts) instead of tuning at
/// once (build 33: Mark, live testing — a secondary channel used to tune
/// straight away on an upcoming event). The icon and accessibility label
/// say which: play, an already-scheduled recording, or the choice.
struct SportChannelRow: View {
    let channel: SportEventChannel
    let browse: BrowseModel
    var isBest = false
    var playsNow = true
    var scheduled = false
    /// Its airing has ended: nothing to play or wait for.
    var ended = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PigSpacing.l) {
                ChannelLogoTile(logo: browse.logo(for: channel), client: browse.client, name: channel.name,
                                size: SportMetrics.rowLogo)
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                        Text(channel.name).font(DetailType.rowTitle).lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                        if browse.showsChannelNumbers, let number = channel.number {
                            // never broken over lines; the name shrinks first (#243: "beIN Sp…" at phone width)
                            ChannelNumberText(number: String(number), font: DetailType.rowDetail).fixedSize()
                        }
                    }
                    if isBest {
                        Text("Recommended").font(DetailType.rowDetail).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    if scheduled {
                        Text("Recording scheduled").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                    if ended {
                        Text("Not on now").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if let quality = channel.quality { QualityBadge(quality: quality) }
                Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            #else
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            #endif
            .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sport.channel.\(channel.id)")
    }

    private var icon: String {
        if ended { return "xmark.circle" }
        if playsNow { return "play.fill" }
        return scheduled ? "record.circle" : "alarm"
    }

    private var accessibilityLabel: String {
        let text = ended ? "Not on now on \(channel.name)" : playsNow ? "Watch on \(channel.name)"
            : scheduled ? "Recording scheduled on \(channel.name)" : "Record or watch \(channel.name) when it starts"
        return text + (channel.quality.map { ", \($0.spoken)" } ?? "")
    }
}

/// The channel picker (long press → Choose a channel). Behaves like the
/// event page's channel list (`SportChannelList`): the same rule decides
/// whether a row plays or offers a choice.
struct SportChannelPicker: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    let browse: BrowseModel
    let clock: Date
    /// Closes the picker, then runs the action (playback or a wait).
    let play: (@escaping () -> Void) -> Void

    var body: some View {
        DetailPage(title: "Choose a channel") {
            // The clock moves while the picker is open (it may have been presented minutes ago).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = max(context.date, clock)
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    VStack(alignment: .leading, spacing: PigSpacing.s) {
                        Eyebrow(text: event.league)
                        Text(event.title).font(DetailType.channel)
                        Text(SportRows.timing(event, now: now)).font(DetailType.meta).foregroundStyle(.secondary)
                    }
                    SportChannelList(event: event, app: app, browse: browse, clock: now, play: play)
                }
            }
        }
    }
}

/// One event's channels, each row deciding for itself (build 33): live, or
/// starting within `SportRows.watchNowWindow`, plays on select; otherwise
/// select opens a choice — Record on that channel (unless already
/// scheduled), or Watch it when it starts — via `confirmationDialog`, not
/// another full-screen cover (tvOS focus: stacked covers can strand focus;
/// Record still needs one, same as the event page's own Record button).
/// Shared by the event page (`SportEventDetails`) and the long-press
/// channel picker (`SportChannelPicker`).
struct SportChannelList: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    /// Not observed (audit R05): the list marks scheduled recordings and
    /// draws the EPG logo fallback.
    let browse: BrowseModel
    @ObservedObject private var marks: ScheduleMarks
    @ObservedObject private var artwork: ArtworkStore
    let clock: Date
    /// Closes the covering page, then runs the action (playback or a wait).
    let play: (@escaping () -> Void) -> Void
    @State private var choosing: SportEventChannel?

    init(event: SportEvent, app: AppModel, browse: BrowseModel, clock: Date, play: @escaping (@escaping () -> Void) -> Void) {
        self.event = event
        self.app = app
        self.browse = browse
        _marks = ObservedObject(wrappedValue: browse.marks)
        _artwork = ObservedObject(wrappedValue: browse.artwork)
        self.clock = clock
        self.play = play
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            ForEach(Array(event.channels.enumerated()), id: \.element.id) { index, channel in
                // #20: each row on its own channel's airing.
                let action = SportRows.channelAction(event, on: channel, now: clock)
                let scheduled = action != .play && browse.isScheduled(event, on: channel)
                SportChannelRow(channel: channel, browse: browse, isBest: index == 0 && event.channels.count > 1,
                                 playsNow: action == .play, scheduled: scheduled, ended: action == .ended) {
                    // Decided again at the press: the page may have been open since before the airing ended.
                    switch SportRows.channelAction(event, on: channel, now: Date()) {
                    case .play: play { app.playSportEvent(event, channel: channel) }
                    case .wait: choosing = channel
                    case .ended: break
                    }
                }
            }
        }
        .tvFocusSection()
        .confirmationDialog(choosing?.name ?? "", isPresented: Binding(
            get: { choosing != nil }, set: { if !$0 { choosing = nil } }
        ), titleVisibility: .visible, presenting: choosing) { channel in
            if !browse.isScheduled(event, on: channel) {
                Button("Record on \(channel.name)", systemImage: "record.circle") {
                    choosing = nil
                    // Apple 114: the record page, on this channel (it lists the others too); this page closes first.
                    play { app.record(event, onChannel: channel.id) }
                }
            }
            Button("Watch \(channel.name) when it starts", systemImage: "alarm") {
                choosing = nil
                play { app.watchWhenStarts(event, channel: channel, now: clock) }
            }
            Button("Cancel", role: .cancel) { choosing = nil }
        } message: { _ in
            Text(SportRows.timing(event, now: clock))
        }
    }
}

/// An upcoming event's page: Watch <channel> when it starts (plays at once
/// within five minutes), Record on the best channel, and every channel.
struct SportEventDetails: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    /// Not observed (audit R05): the page draws the schedule marks, the
    /// action state and the EPG logo fallback.
    let browse: BrowseModel
    @ObservedObject private var marks: ScheduleMarks
    @ObservedObject private var actions: ActionState
    @ObservedObject private var artwork: ArtworkStore
    /// Closes the page, then runs the action (playback).
    let play: (@escaping () -> Void) -> Void

    init(event: SportEvent, app: AppModel, browse: BrowseModel, play: @escaping (@escaping () -> Void) -> Void) {
        self.event = event
        self.app = app
        self.browse = browse
        _marks = ObservedObject(wrappedValue: browse.marks)
        _actions = ObservedObject(wrappedValue: browse.actions)
        _artwork = ObservedObject(wrappedValue: browse.artwork)
        self.play = play
    }
    private enum Control: Hashable { case watch }
    @FocusState private var focus: Control?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                content(now: now)
            }
        }
        .onAppear { browse.actionError = nil; browse.actionMessage = nil }
    }

    /// #243 (Apple 169): the page opens with the Sport pages' own banner (D-43) on Apple TV and iPad, its actions inside;
    /// on iPhone with a card in the touch league page's style, the actions below. Neither takes the logo's colour (the
    /// old hero was tinted by it, so an event on beIN Sports was purple).
    private var usesBanner: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    /// The banner's words: "LIVE · NRL" or "NRL · TODAY"; "1:15 pm – 3:15 pm · starts in 22 min".
    private func hero(now: Date) -> SportBannerHero {
        let live = event.isLive(at: now)
        let scheduled = event.best.map { browse.isScheduled(event, on: $0) } ?? false
        let league = event.league.uppercased()
        return SportBannerHero(
            kicker: live ? "LIVE · \(league)" : "\(league) · \(DetailText.day(event.start, now: now).uppercased())",
            live: live, title: event.title,
            line: "\(event.programme.timeRange) · \(live ? SportRows.endsIn(event, now: now) : SportRows.startsIn(event, now: now))"
                + (scheduled && !live ? " · Recording scheduled" : ""))
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pending = app.pendingWatch?.eventID == event.id
        let best = event.best
        let words = hero(now: now)
        VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
            if usesBanner {
                SportBanner(hero: words, items: [], listTitle: "", selected: nil, backdrop: nil, client: browse.client,
                            onSelect: { _ in }) {
                    if best != nil { actions(now: now) }
                }
                .defaultFocus($focus, .watch)
            } else {
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    HStack(spacing: PigSpacing.s) {
                        if words.live { Circle().fill(Color.pigDanger).frame(width: 8, height: 8).accessibilityHidden(true) }
                        Text(words.kicker).font(SportBannerMetrics.kicker).tracking(1).lineLimit(1)
                            .foregroundStyle(words.live ? Color.pigDanger : Color.pigAccentText)
                    }
                    Text(words.title).font(.title2.weight(.heavy)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(words.line).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    if words.live {
                        PigProgressBar(fraction: SportRows.progress(event, now: now), height: 6).padding(.top, PigSpacing.xs)
                    }
                }
                .padding(PigSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sport.event.card")
                if best != nil {
                    DetailActions { actions(now: now) }
                        .defaultFocus($focus, .watch)
                }
            }
            if let best {
                if let error = browse.actionError {
                    Text(error).font(DetailType.meta).foregroundStyle(.secondary)
                }
                if pending {
                    Text("PigTV will start \(best.name) at \(event.start(on: best).formatted(date: .omitted, time: .shortened)) while the app stays open.")
                        .font(DetailType.meta).foregroundStyle(.secondary)
                }
            }
            PigSectionHeader(title: event.channels.count == 1 ? "Channel" : "Channels")
            SportChannelList(event: event, app: app, browse: browse, clock: now, play: play)
        }
    }

    /// Watch (or Watch when it starts, or Don't watch) and Record: in the banner, or under the iPhone's card.
    @ViewBuilder
    private func actions(now: Date) -> some View {
        if let best = event.best {
            let action = SportRows.channelAction(event, now: now)
            if app.pendingWatch?.eventID == event.id {
                Button("Don't watch at \((app.pendingWatch?.at ?? event.start).formatted(date: .omitted, time: .shortened))",
                       systemImage: "xmark") { app.cancelPendingWatch() }
                    .pigSecondaryButton()
                    .focused($focus, equals: .watch)
            } else if action == .ended {
                // Apple 89 (Codex round 2): the airing is over; the channel shows something else now.
                Button("Not on now", systemImage: "xmark.circle") {}
                    .pigSecondaryButton()
                    .disabled(true)
                    .focused($focus, equals: .watch)
                    .accessibilityIdentifier("sport.notOnNow")
            } else if action == .play {
                Button("Watch \(best.name)", systemImage: "play.fill") {
                    // Decided again at the press (the page may have been open since before the airing ended).
                    let at = Date()
                    switch SportRows.channelAction(event, now: at) {
                    case .play: play { app.playSportEvent(event) }
                    case .wait: play { app.watchWhenStarts(event, now: at) }
                    case .ended: break
                    }
                }
                .pigPrimaryButton()
                .focused($focus, equals: .watch)
                .accessibilityIdentifier("sport.watch")
            } else {
                // Closes the page (the wait shows as a banner on the Sport tab), so nothing is covering the player when
                // the event starts.
                Button("Watch \(best.name) when it starts", systemImage: "alarm") {
                    play { app.watchWhenStarts(event, now: now) }
                }
                .pigPrimaryButton()
                .focused($focus, equals: .watch)
                .accessibilityIdentifier("sport.watch")
            }
            if event.end(on: best) > now {
                // Apple 114: one Record (the record page: this game, every game of a side or the league, the channel);
                // Change recording when it is scheduled. This page closes first (one page at a time).
                Button(browse.isScheduled(event, on: best) ? "Change recording" : "Record", systemImage: "record.circle") {
                    play { app.record(event) }
                }
                .pigSecondaryButton()
                .disabled(browse.mutationBusy)
                .accessibilityIdentifier("sport.record")
            }
        }
    }
}
