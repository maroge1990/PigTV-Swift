import SwiftUI
import Combine

// D-43 (1 Nov): what the Apple TV front page and the sport pages share below and inside the banner: a game card (the
// mock-up's 334 × 132: two team rows with badges and scores, or a session's kicker and title, then the state and the
// channel), the hero's buttons, and Record's channel choice (#204). A followed team's card has the pink outline and its
// team a star; spoiler-free hides scores and situations (`SportFrontText.drawn`). Every play started here keeps the
// front page's origin ("sport-front").

enum SportCardMetrics {
    #if os(tvOS)
    static let width: CGFloat = 334
    static let height: CGFloat = 132
    static let spacing: CGFloat = 14
    static let radius: CGFloat = 18
    static let padding = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
    static let badge: CGFloat = 32
    static let team: Font = .system(size: 21, weight: .bold)
    static let score: Font = .system(size: 24, weight: .heavy)
    static let detail: Font = .system(size: 17)
    static let kicker: Font = .system(size: 15, weight: .bold)
    static let title: Font = .system(size: 20, weight: .bold)
    static let small: Font = .system(size: 16)
    #else
    static let width: CGFloat = 260
    static let height: CGFloat = 112
    static let spacing: CGFloat = 12
    static let radius: CGFloat = 14
    static let padding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    static let badge: CGFloat = 26
    static let team: Font = .subheadline.weight(.bold)
    static let score: Font = .headline.weight(.heavy)
    static let detail: Font = .caption
    static let kicker: Font = .caption2.weight(.bold)
    static let title: Font = .subheadline.weight(.bold)
    static let small: Font = .caption
    #endif
}

/// Type shared by the front page and the sport pages.
enum SportSectionMetrics {
    #if os(tvOS)
    static let sectionTitle: Font = .system(size: 25, weight: .heavy)
    static let sectionLine: Font = .system(size: 18)
    #else
    static let sectionTitle: Font = .title3.bold()
    static let sectionLine: Font = .subheadline
    #endif
}

/// Record on one of a game's channels (#204): one channel opens the record sheet; more ask which first.
@MainActor
final class SportRecordFlow: ObservableObject {
    @Published var recording: SportRecordTarget?
    @Published var choosing: SportEvent?

    func record(_ event: SportEvent) {
        let choices = SportFrontText.recordChoices(event, now: Date())
        if choices.count > 1 { choosing = event }
        else if let channel = choices.first ?? event.best { recording = SportRecordTarget(event: event, channel: channel) }
    }
}

extension View {
    /// The channel choice and the record sheet for `flow`.
    func sportRecordFlow(_ flow: SportRecordFlow, browse: BrowseModel) -> some View {
        modifier(SportRecordFlowModifier(flow: flow, browse: browse))
    }
}

private struct SportRecordFlowModifier: ViewModifier {
    @ObservedObject var flow: SportRecordFlow
    let browse: BrowseModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Record on which channel?", isPresented: Binding(
                get: { flow.choosing != nil }, set: { if !$0 { flow.choosing = nil } }
            ), titleVisibility: .visible, presenting: flow.choosing) { event in
                ForEach(SportFrontText.recordChoices(event, now: Date()), id: \.id) { channel in
                    Button(SportFrontText.recordChoiceLabel(event, on: channel, now: Date()), systemImage: "record.circle") {
                        flow.choosing = nil
                        flow.recording = SportRecordTarget(event: event, channel: channel)
                    }
                }
                Button("Cancel", role: .cancel) { flow.choosing = nil }
            } message: { _ in
                Text("Each channel shows it at its own times.")
            }
            .detailCover(item: $flow.recording) { target in
                RecordSheet(model: browse, channel: browse.recordingRow(target.event, on: target.channel),
                            programme: target.event.programme(on: target.channel)) { _ in
                    flow.recording = nil
                }
            }
    }
}

/// What pressing a game does, revalidated at the press (C-R): Watch only while its channel airs it, else its details.
@MainActor
enum SportGamePress {
    static func select(_ game: SportsGame, app: AppModel, presenter: SportPresenter?) {
        guard let event = SportFrontText.event(game) else { return }
        switch SportFrontText.action(game, now: Date()) {
        case .watch: watch(game, event: event, app: app, presenter: presenter)
        case .remind, .details: presenter?.open(event, .details)
        case .none: break
        }
    }

    /// An answer drawn earlier (or kept after a failed refresh) may describe an airing that has ended, and the player
    /// would tune the channel whatever it shows now: then the details instead.
    static func watch(_ game: SportsGame, event: SportEvent, app: AppModel, presenter: SportPresenter?) {
        guard let live = SportFrontText.playable(game, at: Date()) else { presenter?.open(event, .details); return }
        if let presenter { presenter.play(live) } else { app.playSportEvent(live, origin: SportFrontView.origin) }
    }
}

/// The hero's buttons: Watch (on now) or Remind me (before), Record, and a way to the hero's sport page.
struct SportHeroButtons: View {
    let game: SportsGame?
    let now: Date
    let app: AppModel
    let flow: SportRecordFlow
    /// "Open Football" (the front page); nil on a sport page.
    var open: (label: String, action: () -> Void)? = nil
    /// The page's default focus: the first button (Watch or Remind me, else Record, else the sport's page).
    var focus: FocusState<Bool>.Binding? = nil
    @Environment(\.sportPresenter) private var presenter

    var body: some View {
        let event = game.flatMap { $0.terminal ? nil : SportFrontText.event($0) }
        let action = game.map { SportFrontText.action($0, now: now) } ?? .none
        let primary = event != nil && (action == .watch || action == .remind)
        if let game, let event {
            switch action {
            case .watch:
                Button("Watch", systemImage: "play.fill") {
                    SportGamePress.watch(game, event: event, app: app, presenter: presenter)
                }
                .pigPrimaryButton()
                .modifier(HeroFocus(focus: focus))
                .accessibilityIdentifier("sport.banner.hero.watch")
            case .remind:
                Button("Remind me", systemImage: "bell") { app.watchWhenStarts(event, now: Date()) }
                    .pigPrimaryButton()
                    .modifier(HeroFocus(focus: focus))
                    .accessibilityIdentifier("sport.banner.hero.remind")
            case .details, .none:
                EmptyView()
            }
            Button("Record", systemImage: "record.circle") { flow.record(event) }
                .modifier(HeroFocus(focus: primary ? nil : focus))
                .accessibilityIdentifier("sport.banner.hero.record")
        }
        if let open {
            Button(open.label, systemImage: "chevron.right") { open.action() }
                .modifier(HeroFocus(focus: event == nil ? focus : nil))
                .accessibilityIdentifier("sport.banner.hero.open")
        }
    }
}

private struct HeroFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}

/// A game card in a rail or a league's games.
struct SportGameCard: View {
    let game: SportsGame
    let front: SportFront
    let hidden: Bool
    let now: Date
    let client: APIClient?
    let onSelect: () -> Void
    /// Long press "Make this the hero" (the front page).
    var onPin: (() -> Void)? = nil

    var body: some View {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let followed = game.followed == true
        let live = SportFrontHero.ongoing.contains(game.status)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                if game.competitors.count == 2 { teams(drawn) } else { session(drawn) }
                Spacer(minLength: 0)
                if let mark = game.recordingMark { recordingMark(mark) }
                bottom(drawn, live: live)
            }
            .padding(SportCardMetrics.padding)
            .frame(width: SportCardMetrics.width, alignment: .leading)
            .frame(minHeight: SportCardMetrics.height, alignment: .topLeading)
            .overlay {
                // Your team: the pink outline (D-43); another game on now: a thin live outline.
                if followed || live {
                    RoundedRectangle(cornerRadius: SportCardMetrics.radius, style: .continuous)
                        .strokeBorder(followed ? Color.pigAccent : Color.pigDanger.opacity(0.8), lineWidth: followed ? 3 : 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportCardMetrics.radius))
        .contextMenu {
            if let onPin { Button("Make this the hero", systemImage: "star") { onPin() } }
        }
        .accessibilityIdentifier("sport.front.game.\(game.id)")
    }

    private func teams(_ drawn: SportFrontText.Drawn) -> some View {
        let star = SportFrontLayout.followedSide(game, names: front.follows.map(\.name))
        return ForEach(Array(game.competitors.prefix(2).enumerated()), id: \.offset) { index, team in
            HStack(spacing: 12) {
                SportBadge(name: team.name, logo: team.cachedLogo, league: game.league, client: client,
                           size: SportCardMetrics.badge)
                if game.followed == true && star == index {
                    Image(systemName: "star.fill").font(SportCardMetrics.small).foregroundStyle(Color.pigAccentText)
                        .accessibilityLabel("Your team")
                }
                Text(team.name).font(SportCardMetrics.team).lineLimit(1)
                Spacer(minLength: 6)
                if let scores = drawn.scores, scores.indices.contains(index) {
                    Text(scores[index]).font(SportCardMetrics.score).monospacedDigit()
                }
            }
            .frame(height: 40)
        }
    }

    private func session(_ drawn: SportFrontText.Drawn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((game.session ?? drawn.kicker).uppercased()).font(SportCardMetrics.kicker).tracking(1.4)
                .foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if game.followed == true {
                    Image(systemName: "star.fill").font(SportCardMetrics.small).foregroundStyle(Color.pigAccentText)
                        .accessibilityLabel("Your team")
                }
                Text(game.title).font(SportCardMetrics.title).lineLimit(1)
            }
            Text([game.status == "scheduled" ? SportFrontText.when(SportFrontText.date(game.start), now: now) : nil,
                  game.channels.first?.name].compactMap { $0 }.joined(separator: " · "))
                .font(SportCardMetrics.small).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// The state on the left (live: the red dot and the neutral progress; a result; the start time) and the channel or
    /// the action on the right.
    @ViewBuilder
    private func bottom(_ drawn: SportFrontText.Drawn, live: Bool) -> some View {
        HStack(spacing: 8) {
            if live {
                Circle().fill(Color.pigDanger).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(drawn.situation ?? drawn.status).font(SportCardMetrics.detail.weight(.bold))
                    .foregroundStyle(Color.pigDanger).lineLimit(1).layoutPriority(1)
            } else if game.terminal {
                Text(drawn.status).font(SportCardMetrics.detail.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            } else if game.competitors.count == 2 {
                Text(SportFrontText.when(SportFrontText.date(game.start), now: now)).font(SportCardMetrics.detail.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if game.competitors.count == 2 {
                Text(game.channels.first?.name ?? (game.terminal ? "" : "No TV listing found"))
                    .font(SportCardMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(SportFrontText.actionLabel(game, now: now)).font(SportCardMetrics.small.weight(.bold))
                    .foregroundStyle(Color.pigAccentText).lineLimit(1)
            }
        }
    }

    /// "Recording" (a red dot) or "Set to record" (a red ring), and "Clashes with …" when it loses its clash (C-R since
    /// 0415, #198): not a score, so shown with spoilers hidden too.
    private func recordingMark(_ mark: SportsGame.RecordingMark) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(mark.isRecording ? Color.pigDanger : Color.clear)
                    .overlay { Circle().strokeBorder(Color.pigDanger, lineWidth: 2) }
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(mark.label).font(SportCardMetrics.small.weight(.semibold))
                    .foregroundStyle(mark.isRecording ? Color.pigDanger : Color.secondary).lineLimit(1)
            }
            if let clash = mark.clashLine {
                Text(clash).font(SportCardMetrics.small).foregroundStyle(Color.pigWarning).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sport.card.recording.\(game.id)")
    }
}
