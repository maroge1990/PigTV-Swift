import SwiftUI
import Combine

// An event's pages: the screen-level presenter that owns
// them, the details page and the channel picker.

enum SportPage: String, Sendable {
    case details, channels
}

/// An open event page or channel picker.
struct SportPresentation: Identifiable {
    let event: SportEvent
    let page: SportPage
    /// #347 (Codex review of 320): the game a recording made from the page is for (the front card's id, or a page item's
    /// `card`), sent as its `gameId`; nil: none, as before.
    var gameID: String? = nil
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

    func open(_ event: SportEvent, _ page: SportPage, gameID: String? = nil) {
        presented = SportPresentation(event: event, page: page, gameID: gameID)
    }
    func play(_ event: SportEvent) { app.playSportEvent(event, origin: origin) }

    /// #234: what a card without a listing offers (its hold menu, the record page), if anything.
    func futureOffer(_ game: SportsGame) -> SportFutureRecord.Offer? {
        SportFutureRecord.offer(game, now: Date(), answered: futureAnswers[game.id])
    }
    /// This device's answer for a card, if any.
    func futureAnswer(_ game: SportsGame) -> SportFutureRecord.Answer? { futureAnswers[game.id] }
    /// #345: an answer given on the record page (the rule added, or nil once removed), so the card says it at once.
    func noteFuture(_ game: SportsGame, rule: Int?) {
        futureAnswers[game.id] = .init(basis: game.recordWhenListed?.ruleId, rule: rule)
    }
    /// The rule this card waits on, this device's answers first.
    func futureRule(_ game: SportsGame) -> Int? { SportFutureRecord.waiting(game, answered: futureAnswers[game.id]) }
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
            // #234: a hold menu's Record when it's listed that failed
            .alert("Not saved", isPresented: Binding(get: { presenter.futureError != nil }, set: { if !$0 { presenter.futureError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presenter.futureError ?? "")
            }
            .detailCover(item: $presenter.presented, onDismiss: presenter.dismissed) { presentation in
                switch presentation.page {
                case .details:
                    SportEventDetails(event: presentation.event, app: app, browse: browse, play: presenter.close(then:),
                                      gameID: presentation.gameID)
                case .channels:
                    SportChannelPicker(event: presentation.event, app: app, browse: browse, clock: clock,
                                       play: presenter.close(then:), gameID: presentation.gameID)
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
                SportChannelTitle(channel: channel, isBest: isBest, scheduled: scheduled, ended: ended)
                Spacer(minLength: 16)
                if let chip = channel.chip { QualityBadge(chip: chip) }
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
        return text + (channel.chip.map { ", \($0.spoken)" } ?? "")
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
    /// #347: the recording's game (`SportPresentation.gameID`).
    var gameID: String? = nil

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
                    SportChannelList(event: event, app: app, browse: browse, clock: now, play: play, gameID: gameID)
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
    private let marks: ScheduleMarks
    let clock: Date
    /// Closes the covering page, then runs the action (playback or a wait).
    let play: (@escaping () -> Void) -> Void
    @State private var choosing: SportEventChannel?
    /// #347: the recording's game, sent as its `gameId` by every Record on a channel here.
    let gameID: String?

    init(event: SportEvent, app: AppModel, browse: BrowseModel, clock: Date, play: @escaping (@escaping () -> Void) -> Void,
         gameID: String? = nil) {
        self.event = event
        self.app = app
        self.browse = browse
        self.marks = browse.marks
        self.clock = clock
        self.play = play
        self.gameID = gameID
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        // D-65 (#266): one row per channel name, its copies as quality chips (display only: each copy acts as before).
        let groups = ChannelGrouping.group(event)
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                row(group, isBest: index == 0 && groups.count > 1)
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
                    play { app.record(event, onChannel: channel.id, card: gameID) }
                }
            }
            Button("Watch \(channel.name) when it starts", systemImage: "alarm") {
                choosing = nil
                play { app.watchWhenStarts(event, channel: channel, now: clock) }
            }
            Button("Cancel", role: .cancel) { choosing = nil }
        } message: { _ in
            Text(SportRows.timing(event, now: clock)).pigFigures()
        }
    }

    @ViewBuilder
    private func row(_ group: ChannelNameGroup<SportEventChannel>, isBest: Bool) -> some View {
        // #20: each copy on its own channel's airing; the row's words follow its best copy.
        let best = group.best.copy
        let action = SportRows.channelAction(event, on: best, now: clock)
        let scheduled = action != .play && group.choices.contains { browse.isScheduled(event, on: $0.copy) }
        if compact {
            #if os(iOS)
            SportChannelPhoneRow(group: group, browse: browse, isBest: isBest, scheduled: scheduled,
                                 action: { SportRows.channelAction(event, on: $0, now: clock) },
                                 startText: event.start(on: best).formatted(date: .omitted, time: .shortened),
                                 choose: phoneChoose,
                                 record: { channel in play { app.record(event, onChannel: channel.id, card: gameID) } },
                                 watchAtStart: { channel in play { app.watchWhenStarts(event, channel: channel, now: clock) } })
            #endif
        } else if group.choosesQuality {
            SportChannelChipsRow(group: group, browse: browse, isBest: isBest, scheduled: scheduled,
                                 action: { SportRows.channelAction(event, on: $0, now: clock) }, choose: choose)
        } else {
            SportChannelRow(channel: best, browse: browse, isBest: isBest, playsNow: action == .play,
                            scheduled: scheduled, ended: action == .ended) { choose(best) }
        }
    }

    #if os(iOS)
    /// D-65, iPhone: a tap plays a copy that is on (or about to start) and, before the game, records on it: no choice
    /// sheet (Watch at <time> is in the row's touch and hold). Decided again at the press.
    private func phoneChoose(_ channel: SportEventChannel) {
        switch PhoneChannelTap.of(SportRows.channelAction(event, on: channel, now: Date())) {
        case .play: play { app.playSportEvent(event, channel: channel) }
        case .record: play { app.record(event, onChannel: channel.id, card: gameID) }
        case .none: break
        }
    }
    #endif

    /// What choosing one copy does, decided again at the press (the page may have been open since before the airing
    /// ended): play it, or offer Record / Watch when it starts.
    private func choose(_ channel: SportEventChannel) {
        switch SportRows.channelAction(event, on: channel, now: Date()) {
        case .play: play { app.playSportEvent(event, channel: channel) }
        case .wait: choosing = channel
        case .ended: break
        }
    }
}

/// The row's words: name (and number), Recommended, Recording scheduled, Not on now.
private struct SportChannelTitle: View {
    let channel: SportEventChannel
    var isBest = false
    var scheduled = false
    var ended = false
    /// iPhone (D-65): the row's best quality, on the line under the name.
    var chip: QualityChip? = nil
    /// iPhone: the line under the name yields (Recommended truncates) before the name does.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                Text(channel.name).font(DetailType.rowTitle).lineLimit(1).pigMinimumScale(0.75, size: PigType.cardTitle).layoutPriority(1)
                if let number = channel.number {
                    ChannelNumberText(number: String(number), font: DetailType.rowDetail).fixedSize()
                }
            }
            if compact, chip != nil || isBest {
                HStack(spacing: PigSpacing.s) {
                    if let chip { QualityBadge(chip: chip).layoutPriority(1) }
                    if isBest {
                        Text("Recommended").font(DetailType.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if isBest {
                Text("Recommended").font(DetailType.rowDetail).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if scheduled {
                Text("Recording scheduled").font(DetailType.rowDetail).foregroundStyle(.secondary)
            }
            if ended {
                Text("Not on now").font(DetailType.rowDetail).foregroundStyle(.secondary)
            }
        }
    }
}

/// A chip's start time when its copy airs at another time than the row's (its `start`, ms), else nil.
private func chipStartText(_ group: ChannelNameGroup<SportEventChannel>, _ choice: ChannelChoice<SportEventChannel>) -> String? {
    guard group.startsDifferently(choice), let start = choice.start else { return nil }
    return Date(timeIntervalSince1970: start / 1000).formatted(date: .omitted, time: .shortened)
}

/// D-65: the icon a copy's choice shows: play, an already-scheduled recording, the choice, or nothing to do.
private func sportChannelIcon(_ action: SportRows.ChannelAction, scheduled: Bool) -> String {
    switch action {
    case .ended: "xmark.circle"
    case .play: "play.fill"
    case .wait: scheduled ? "record.circle" : "alarm"
    }
}

/// One quality chip: the badge (or "Other" for a copy with no quality at all) and what choosing it does.
private struct SportChannelChip: View {
    let choice: ChannelChoice<SportEventChannel>
    let action: SportRows.ChannelAction
    let scheduled: Bool
    /// iPhone (D-65): before the game choosing a copy records on it (no Record / Watch when it starts choice).
    var waitRecords = false
    /// The accessibility identifier's stem: the opened iPhone row's chips have their own.
    var identifier = "sport.channel"
    /// Its copy airs at another time than the row's: its start ("8:30 pm"), else nil.
    var startText: String? = nil
    let choose: (SportEventChannel) -> Void

    var body: some View {
        Button { choose(choice.copy) } label: {
            HStack(spacing: PigSpacing.xs) {
                if let chip = choice.chip {
                    QualityBadge(chip: chip)
                } else {
                    Text("Other").font(SportMetrics.detail.weight(.bold)).foregroundStyle(.secondary)
                }
                if let startText {
                    Text(startText).font(SportMetrics.detail).foregroundStyle(.secondary).pigFigures()
                }
                Image(systemName: sportChannelIcon(action, scheduled: scheduled || waitRecords)).font(SportMetrics.detail)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.compact, lift: .control))
        .disabled(action == .ended)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifier).\(choice.copy.id)")
    }

    private var label: String {
        let name = choice.copy.name
        let text = action == .ended ? "Not on now on \(name)" : action == .play ? "Watch on \(name)"
            : scheduled ? "Recording scheduled on \(name)"
            : waitRecords ? "Record on \(name)" : "Record or watch \(name) when it starts"
        return text + (choice.chip.map { ", \($0.spoken)" } ?? "") + (startText.map { ", starts \($0)" } ?? "")
    }
}

/// D-65, Apple TV and iPad: a channel name carried in several qualities: its chips on the row, best first, each one
/// focusable (left and right) and acting on its copy (play now, or the Record / Watch when it starts choice).
struct SportChannelChipsRow: View {
    /// The room a focused chip needs inside the row's clip (tvOS: its lift and ring); none on touch.
    static var focusRoom: CGFloat {
        #if os(tvOS)
        PigFocus.clearance
        #else
        0
        #endif
    }

    let group: ChannelNameGroup<SportEventChannel>
    let browse: BrowseModel
    var isBest = false
    var scheduled = false
    let action: (SportEventChannel) -> SportRows.ChannelAction
    let choose: (SportEventChannel) -> Void

    var body: some View {
        let best = group.best.copy
        HStack(alignment: .center, spacing: PigSpacing.l) {
            ChannelLogoTile(logo: browse.logo(for: best), client: browse.client, name: best.name, size: SportMetrics.rowLogo)
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                SportChannelTitle(channel: best, isBest: isBest, scheduled: scheduled, ended: action(best) == .ended)
                // The chips stay inside the card: the clip keeps room for a focused chip's lift and ring, and an end
                // with chips out of sight fades.
                ChipScroller(inset: Self.focusRoom) {
                    HStack(spacing: PigSpacing.s) {
                        ForEach(group.choices) { choice in
                            SportChannelChip(choice: choice, action: action(choice.copy), scheduled: scheduled,
                                             startText: chipStartText(group, choice), choose: choose)
                        }
                    }
                    .padding(.vertical, PigSpacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
        .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .tvFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sport.channelGroup.\(best.id)")
    }
}

#if os(iOS)
/// D-65, iPhone: one row per channel name showing its best quality. A tap acts on the best copy (plays it when it is
/// on, records on it before the game); touch and hold opens the row in place: the quality chips scrolling sideways
/// (when there is more than one), Record…, and before the game Watch at <start>. Touch and hold again closes it.
struct SportChannelPhoneRow: View {
    let group: ChannelNameGroup<SportEventChannel>
    let browse: BrowseModel
    var isBest = false
    var scheduled = false
    let action: (SportEventChannel) -> SportRows.ChannelAction
    let startText: String
    let choose: (SportEventChannel) -> Void
    let record: (SportEventChannel) -> Void
    let watchAtStart: (SportEventChannel) -> Void
    @State private var open = false

    var body: some View {
        let best = group.best.copy
        let bestAction = action(best)
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            HStack(spacing: PigSpacing.l) {
                ChannelLogoTile(logo: browse.logo(for: best), client: browse.client, name: best.name, size: SportMetrics.rowLogo)
                // The name has the room: the badge and Recommended share the line under it and yield first. The badge
                // shows only on a closed row; an open row's first chip shows it (as on the web).
                SportChannelTitle(channel: best, isBest: isBest, scheduled: scheduled, ended: bestAction == .ended,
                                  chip: open && group.choosesQuality ? nil : group.best.chip, compact: true)
                    .layoutPriority(1)
                Spacer(minLength: PigSpacing.s)
                Image(systemName: open ? "chevron.up" : sportChannelIcon(bestAction, scheduled: true))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            // A plain tap and a hold on the same row, one gesture: the hold is tried first and the tap fires only when it
            // fails (a quick release). Two separate modifiers let the live row's hold go unrecognised (nothing opened).
            .gesture(LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in withAnimation(PigMotion.standard) { open.toggle() } }
                .exclusively(before: TapGesture().onEnded {
                    if open { withAnimation(PigMotion.standard) { open = false } } else { choose(best) }
                }))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label(best, action: bestAction))
            .accessibilityAction { choose(best) }
            .accessibilityAction(named: open ? "Close" : "More choices") { withAnimation(PigMotion.standard) { open.toggle() } }
            .accessibilityIdentifier("sport.channel.\(best.id)")
            if open {
                if group.choosesQuality {
                    ChipScroller {
                        HStack(spacing: PigSpacing.s) {
                            ForEach(group.choices) { choice in
                                SportChannelChip(choice: choice, action: action(choice.copy), scheduled: scheduled,
                                                 waitRecords: true, identifier: "sport.channel.chip",
                                                 startText: chipStartText(group, choice), choose: choose)
                            }
                        }
                    }
                    .accessibilityIdentifier("sport.channel.\(best.id).chips")
                }
                if bestAction != .ended {
                    HStack(spacing: PigSpacing.m) {
                        Button("Record…", systemImage: "record.circle") { open = false; record(best) }
                            .pigSecondaryButton()
                            .accessibilityIdentifier("sport.channel.\(best.id).record")
                        if bestAction == .wait {
                            Button("Watch at \(startText)", systemImage: "alarm") { open = false; watchAtStart(best) }
                                .pigSecondaryButton()
                                .accessibilityIdentifier("sport.channel.\(best.id).watchAt")
                        }
                    }
                    .font(DetailType.rowDetail)
                }
            }
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
        .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
    }

    private func label(_ channel: SportEventChannel, action: SportRows.ChannelAction) -> String {
        let text = action == .ended ? "Not on now on \(channel.name)" : action == .play ? "Watch on \(channel.name)"
            : scheduled ? "Recording scheduled on \(channel.name)" : "Record on \(channel.name)"
        return text + (group.best.chip.map { ", \($0.spoken)" } ?? "")
    }
}

#endif

/// An upcoming event's page: Watch <channel> when it starts (plays at once
/// within five minutes), Record on the best channel, and every channel.
struct SportEventDetails: View {
    let event: SportEvent
    @ObservedObject var app: AppModel
    /// Not observed (audit R05): the page draws the schedule marks, the
    /// action state and the EPG logo fallback.
    let browse: BrowseModel
    private let marks: ScheduleMarks
    private let actions: ActionState
    /// Closes the page, then runs the action (playback).
    let play: (@escaping () -> Void) -> Void

    /// #347: the recording's game (`SportPresentation.gameID`).
    var gameID: String? = nil

    init(event: SportEvent, app: AppModel, browse: BrowseModel, play: @escaping (@escaping () -> Void) -> Void,
         gameID: String? = nil) {
        self.gameID = gameID
        self.event = event
        self.app = app
        self.browse = browse
        self.marks = browse.marks
        self.actions = browse.actions
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
                    Text(words.line).font(.subheadline).foregroundStyle(.secondary).pigFigures()
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
            SportChannelList(event: event, app: app, browse: browse, clock: now, play: play, gameID: gameID)
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
                    play { app.record(event, card: gameID) }
                }
                .pigSecondaryButton()
                .disabled(browse.mutationBusy)
                .accessibilityIdentifier("sport.record")
            }
        }
    }
}
