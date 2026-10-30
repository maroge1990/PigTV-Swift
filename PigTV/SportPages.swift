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
    private var afterDismiss: (() -> Void)?
    private let app: AppModel

    init(app: AppModel) { self.app = app }

    func open(_ event: SportEvent, _ page: SportPage) { presented = SportPresentation(event: event, page: page) }
    func play(_ event: SportEvent) { app.playSportEvent(event) }

    func close(then action: @escaping () -> Void) {
        afterDismiss = action
        presented = nil
    }

    /// The cover's `onDismiss`.
    func dismissed() {
        let action = afterDismiss
        afterDismiss = nil
        action?()
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

    init(app: AppModel, browse: BrowseModel, clock: Date) {
        self.app = app
        self.browse = browse
        self.clock = clock
        _presenter = StateObject(wrappedValue: SportPresenter(app: app))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.sportPresenter, presenter)
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
    func sportPages(app: AppModel, browse: BrowseModel, clock: Date) -> some View {
        modifier(SportPages(app: app, browse: browse, clock: clock))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                ChannelLogoTile(logo: browse.logo(for: channel), client: browse.client, name: channel.name,
                                size: SportMetrics.rowLogo)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(channel.name).font(DetailType.rowTitle).lineLimit(1)
                        if browse.showsChannelNumbers, let number = channel.number {
                            ChannelNumberText(number: String(number), font: DetailType.rowDetail)
                        }
                    }
                    if isBest {
                        Text("Recommended").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                    if scheduled {
                        Text("Recording scheduled").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if let quality = channel.quality { QualityBadge(quality: quality) }
                Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, 24).padding(.vertical, 16)
            #else
            .padding(.horizontal, 14).padding(.vertical, 10)
            #endif
            .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 16))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sport.channel.\(channel.id)")
    }

    private var icon: String {
        if playsNow { return "play.fill" }
        return scheduled ? "record.circle" : "alarm"
    }

    private var accessibilityLabel: String {
        let text = playsNow ? "Watch on \(channel.name)"
            : scheduled ? "Recording scheduled on \(channel.name)" : "Record or watch \(channel.name) when it starts"
        return text + (channel.quality.map { ", \($0.rawValue)" } ?? "")
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
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: event.league)
                Text(event.title).font(DetailType.channel)
                Text(SportRows.timing(event, now: clock)).font(DetailType.meta).foregroundStyle(.secondary)
            }
            SportChannelList(event: event, app: app, browse: browse, clock: clock, play: play)
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
    @State private var recording: SportEventChannel?

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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(event.channels.enumerated()), id: \.element.id) { index, channel in
                // #20: each row on its own channel's airing.
                let playsNow = SportRows.playsChannelNow(event, on: channel, now: clock)
                let scheduled = !playsNow && browse.isScheduled(event, on: channel)
                SportChannelRow(channel: channel, browse: browse, isBest: index == 0 && event.channels.count > 1,
                                 playsNow: playsNow, scheduled: scheduled) {
                    if playsNow { play { app.playSportEvent(event, channel: channel) } }
                    else { choosing = channel }
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
                    recording = channel
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
        .detailCover(item: $recording) { channel in
            RecordSheet(model: browse, channel: browse.recordingRow(event, on: channel), programme: event.programme(on: channel)) { _ in
                recording = nil
            }
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
    @State private var recordSheet = false
    /// C-M: choosing what "Record every game" follows.
    @State private var ruleChoices = false
    @State private var ruleAdded = false

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

    var body: some View {
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                content(now: now)
            }
        }
        .onAppear { browse.actionError = nil; browse.actionMessage = nil }
        .confirmationDialog("Record every game of", isPresented: $ruleChoices, titleVisibility: .visible) {
            ForEach(RuleChoices.sport(title: event.title, league: event.league), id: \.self) { choice in
                Button(choice) {
                    Task { ruleAdded = await browse.addRule(RuleBody(kind: "sport", match: choice)) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Live games only, never replays, on the best channel showing them.")
        }
        .detailCover(isPresented: $recordSheet) {
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme(on: best)) { _ in
                    recordSheet = false
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let live = event.isLive(at: now)
        let playsNow = SportRows.playsChannelNow(event, now: now)
        let pending = app.pendingWatch?.eventID == event.id
        let best = event.best
        VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
            DetailHero(logo: best.flatMap { browse.logo(for: $0) }, client: browse.client) {
                HStack(alignment: .top) {
                    Eyebrow(text: "\(event.league) · \(live ? "Live" : DetailText.day(event.start, now: now))")
                    Spacer(minLength: 20)
                    if live { StatusBadge(text: "LIVE", colour: .pigDanger) }
                    else if let best, browse.isScheduled(event, on: best) {
                        StatusBadge(text: "Recording scheduled", systemImage: "record.circle")
                    }
                }
                Text(event.title).font(DetailType.title).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.programme.timeRange) · \(live ? SportRows.endsIn(event, now: now) : SportRows.startsIn(event, now: now))")
                    .font(DetailType.meta).foregroundStyle(.secondary).monospacedDigit().fontDesign(.rounded)
                if live {
                    PigProgressBar(fraction: SportRows.progress(event, now: now), height: 6).frame(maxWidth: 640)
                }
            }
            if let best {
                DetailActions {
                    if pending {
                        Button("Don't watch at \((app.pendingWatch?.at ?? event.start).formatted(date: .omitted, time: .shortened))",
                               systemImage: "xmark") { app.cancelPendingWatch() }
                            .focused($focus, equals: .watch)
                    } else if playsNow {
                        Button("Watch \(best.name)", systemImage: "play.fill") {
                            play { app.playSportEvent(event) }
                        }
                        .pigPrimaryButton()
                        .focused($focus, equals: .watch)
                        .accessibilityIdentifier("sport.watch")
                    } else {
                        // Closes the page (the wait shows as a banner on
                        // the Sport tab and Home), so nothing is covering
                        // the player when the event starts.
                        Button("Watch \(best.name) when it starts", systemImage: "alarm") {
                            play { app.watchWhenStarts(event, now: now) }
                        }
                        .pigPrimaryButton()
                        .focused($focus, equals: .watch)
                        .accessibilityIdentifier("sport.watch")
                    }
                    if event.end(on: best) > now && !browse.isScheduled(event, on: best) {
                        Button("Record", systemImage: "record.circle") { recordSheet = true }
                            .disabled(browse.mutationBusy)
                            .accessibilityIdentifier("sport.record")
                    }
                    if browse.rulesAvailable && !ruleAdded && !RuleChoices.sport(title: event.title, league: event.league).isEmpty {
                        Button("Record every game", systemImage: "repeat.circle") { ruleChoices = true }
                            .disabled(browse.mutationBusy)
                            .accessibilityIdentifier("sport.recordEvery")
                    }
                }
                .defaultFocus($focus, .watch)
                if ruleAdded, let message = browse.actionMessage {
                    Text(message).font(DetailType.meta).foregroundStyle(.secondary)
                }
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
}
