import SwiftUI
import Combine

// D-43 (1 Nov): what the Apple TV front page and the sport pages share below and inside the banner: a game card (the
// mock-up's 334 × 132: two team rows with badges and scores, or a session's kicker and title, then the state and the
// channel), the hero's buttons, and Record's channel choice (#204). A followed team is marked by its star alone (brand
// 1.8); spoiler-free hides scores and situations (`SportFrontText.drawn`). Every play started here keeps the
// front page's origin ("sport-front").

enum SportCardMetrics {
    #if os(tvOS)
    static let width: CGFloat = 334
    static let height: CGFloat = 132
    static let spacing: CGFloat = PigSpacing.s
    static let radius = PigRadius.card
    static let padding = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
    static let badge: CGFloat = 32
    static let team: Font = .system(size: PigType.secondary, weight: .bold)
    static let score: Font = .system(size: PigType.body, weight: .heavy)
    static let detail: Font = .system(size: PigType.caption)
    static let kicker: Font = .system(size: PigType.kicker, weight: .bold)
    static let title: Font = .system(size: PigType.secondary, weight: .bold)
    static let small: Font = .system(size: PigType.caption)
    #else
    static let width: CGFloat = 260
    static let height: CGFloat = 112
    static let spacing: CGFloat = PigSpacing.m
    static let radius = PigRadius.card
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
    static let sectionTitle: Font = .system(size: PigType.cardTitle, weight: .heavy)
    static let sectionLine: Font = .system(size: PigType.caption)
    #else
    static let sectionTitle: Font = .title3.bold()
    static let sectionLine: Font = .subheadline
    #endif
}

/// D-44 batch 5 (Apple 114–115): a Sport screen's recording. Record opens the record page (every channel carrying the
/// game, best first, each on its own airing: #204, C-I #20) through the app's presentation layer; a card's long press
/// offers the one menu's RECORD section (this game or Change recording, every <team> game, More options…).
@MainActor
final class SportRecordFlow: ObservableObject {
    private weak var app: AppModel?

    func attach(_ app: AppModel) { self.app = app }

    /// #257: play the event on the chosen channel.
    func watch(_ event: SportEvent, on channel: SportEventChannel) {
        guard let current = WatchOn.play(event, on: channel, now: Date()) else { return } // its airing ended meanwhile
        app?.playSportEvent(current, channel: channel, origin: "Sport")
    }

    /// The record page (Change recording when one of its channels has it scheduled).
    func record(_ event: SportEvent, game: SportsGame? = nil, team: String? = nil) { app?.record(event, game: game, team: team) }

    /// The menu's RECORD items for a card: the same items as the Guide's (`ProgrammeMenu`), for its best channel.
    /// `team`: the follow the menu is for (#49), so "Record every <team> game" is that team's.
    func menuItems(_ event: SportEvent, game: SportsGame?, team: String? = nil, now: Date = Date()) -> [ProgrammeMenuItem] {
        guard let browse = app?.browse else { return [] }
        return Self.menuItems(browse.recordRequest(event: event, game: game, team: team, now: now), now: now)
    }

    /// Pure; tested (SportRecordMenuTests).
    nonisolated static func menuItems(_ request: RecordRequest?, now: Date) -> [ProgrammeMenuItem] {
        guard let request, let first = request.airings.first else { return [] }
        let subject = ProgrammeMenuSubject(channelName: first.channel.name, programme: first.programme,
                                           recordingStatus: request.schedule?.statusWord,
                                           everyGameTeam: request.everyGameTeam, isGame: true)
        return ProgrammeMenu.items(subject, now: now).filter(\.isRecordSection)
    }

    /// A menu item chosen: Record this game at once on the best channel (with the game's id, the usual padding), a team
    /// rule, or the record page. A quick one that fails opens the page with its error.
    func run(_ item: ProgrammeMenuItem, event: SportEvent, game: SportsGame?, team: String? = nil) {
        guard let app, let browse = app.browse, let request = browse.recordRequest(event: event, game: game, team: team),
              let first = request.airings.first else { return }
        switch item {
        case .recordThis:
            Task {
                guard await browse.schedule(channel: first.channel, programme: first.programme, before: nil, after: nil,
                                            gameId: request.gameId) else {
                    app.record(event, game: game, error: browse.actionError ?? "The recording could not be scheduled.")
                    return
                }
            }
        case .recordEvery:
            guard let team = request.everyGameTeam,
                  let rule = RecordPlan.rule(.everyTeam(team), request: request, before: nil, after: nil) else { return }
            Task {
                guard await browse.addRule(rule) else {
                    app.record(event, game: game, team: team, error: browse.actionError ?? "The rule could not be added.")
                    return
                }
            }
        default:
            app.record(event, game: game, team: team)
        }
    }
}

/// A card's long-press RECORD section (put inside its `contextMenu`).
struct SportRecordMenu: View {
    let flow: SportRecordFlow
    let event: SportEvent
    var game: SportsGame? = nil

    var body: some View {
        let items = flow.menuItems(event, game: game)
        if !items.isEmpty {
            Section("Record") {
                ForEach(items) { item in
                    Button { flow.run(item, event: event, game: game) } label: {
                        Label {
                            Text(item.title)
                            if let detail = item.detail { Text(detail) }
                        } icon: { Image(systemName: item.systemImage) }
                    }
                    .accessibilityIdentifier("menu.\(item.id)")
                }
            }
        }
    }
}

extension View {
    /// Attaches the screen's record flow to the app (its presentation layer and models).
    func sportRecordFlow(_ flow: SportRecordFlow, app: AppModel) -> some View {
        onAppear { flow.attach(app) }
    }
}

/// What pressing a game does, revalidated at the press (C-R): Watch only while its channel airs it, else its details.
@MainActor
enum SportGamePress {
    static func select(_ game: SportsGame, app: AppModel, presenter: SportPresenter?) {
        // #234: a future game the guide does not list yet: offer to record it once it is (else, as before, nothing)
        guard let event = SportFrontText.event(game) else { presenter?.askFuture(game); return }
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
    /// #49: the follow the hero shows (the front page's flipped follow), so Record's team rules are that team's.
    var team: String? = nil
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
            Button("Record", systemImage: "record.circle") { flow.record(event, game: game, team: team) }
                .pigSecondaryButton()
                .modifier(HeroFocus(focus: primary ? nil : focus))
                .accessibilityIdentifier("sport.banner.hero.record")
        }
        if let open {
            Button(open.label, systemImage: "chevron.right") { open.action() }
                .pigSecondaryButton()
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
/// #234: "Records when it's listed" (a dashed red ring) while a `game` rule waits for the guide; follows this device's
/// answers at once (Apple 154), the card's `recordWhenListed` otherwise.
struct SportFutureMark: View {
    let game: SportsGame
    @ObservedObject var presenter: SportPresenter

    var body: some View {
        if presenter.futureRule(game) != nil { Self.mark(game) }
    }

    static func mark(_ game: SportsGame) -> some View {
        HStack(spacing: PigSpacing.s) {
            Circle().strokeBorder(Color.pigDanger, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                .frame(width: 12, height: 12).accessibilityHidden(true)
            Text(SportFutureRecord.waitingLabel).font(SportCardMetrics.small.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sport.card.recordWhenListed.\(game.id)")
    }
}

struct SportGameCard: View {
    /// #234: this device's "Record when it's listed" answers (Apple 154).
    @Environment(\.sportPresenter) private var presenter
    let game: SportsGame
    let front: SportFront
    let hidden: Bool
    let now: Date
    let client: APIClient?
    let onSelect: () -> Void
    /// Long press "Make this the hero" (the front page).
    var onPin: (() -> Void)? = nil
    /// Apple 115: the long press's RECORD section (nil: none, e.g. a finished game).
    var flow: SportRecordFlow? = nil

    var body: some View {
        let drawn = SportFrontText.drawn(game, in: front, hidden: hidden)
        let followed = game.followed == true
        let live = SportFrontHero.ongoing.contains(game.status)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                if game.competitors.count == 2 { teams(drawn) } else { session(drawn) }
                Spacer(minLength: 0)
                if let mark = game.recordingMark { recordingMark(mark) }
                else if let presenter { SportFutureMark(game: game, presenter: presenter) }
                else if game.recordWhenListed != nil { SportFutureMark.mark(game) }
                bottom(drawn, live: live)
            }
            .padding(SportCardMetrics.padding)
            .frame(width: SportCardMetrics.width, alignment: .leading)
            .frame(minHeight: SportCardMetrics.height, alignment: .topLeading)
            .overlay {
                #if os(tvOS)
                // Another game on now: a thin live outline. Your team is marked by its star alone (brand 1.8, #279: the
                // pink outline it had read as focus).
                if live && !followed {
                    RoundedRectangle(cornerRadius: SportCardMetrics.radius, style: .continuous)
                        .strokeBorder(Color.pigDanger.opacity(0.8), lineWidth: 2)
                        .accessibilityHidden(true)
                }
                #else
                // Your team: the pink outline (D-43); another game on now: a thin live outline.
                if followed || live {
                    RoundedRectangle(cornerRadius: SportCardMetrics.radius, style: .continuous)
                        .strokeBorder(followed ? Color.pigAccent : Color.pigDanger.opacity(0.8), lineWidth: followed ? 3 : 2)
                        .accessibilityHidden(true)
                }
                #endif
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportCardMetrics.radius))
        .contextMenu {
            if let flow, !game.terminal, let event = SportFrontText.event(game) {
                // #257: on air on several channels: choose one before the player opens.
                let onAir = WatchOn.onAir(event, now: Date())
                if onAir.channels.count > 1, !event.isReplay {
                    Menu("Watch on… (\(onAir.channels.count) channels)", systemImage: "play.rectangle.on.rectangle") {
                        ForEach(onAir.channels) { channel in
                            Button(WatchOn.label(channel)) { flow.watch(event, on: channel) }
                        }
                    }
                }
                SportRecordMenu(flow: flow, event: event, game: game)
            }
            if let onPin { Button("Make this the hero", systemImage: "star") { onPin() } }
        }
        .accessibilityIdentifier("sport.front.game.\(game.id)")
    }

    private func teams(_ drawn: SportFrontText.Drawn) -> some View {
        // 176 Codex round 1 (high): every followed side is starred (both, when both teams are followed).
        #if os(tvOS)
        let stars = SportFrontLayout.cardStars(game, names: front.follows.map(\.name), firstWhenUnknown: true)
        #else
        let stars = SportFrontLayout.cardStars(game, names: front.follows.map(\.name), firstWhenUnknown: false)
        #endif
        return ForEach(Array(game.competitors.prefix(2).enumerated()), id: \.offset) { index, team in
            HStack(spacing: PigSpacing.s) {
                SportBadge(name: team.name, logo: team.cachedLogo, league: game.league, client: client,
                           size: SportCardMetrics.badge)
                if stars.sides.contains(index) {
                    Image(systemName: "star.fill").font(SportCardMetrics.small).foregroundStyle(Color.pigAccentText)
                        .accessibilityLabel(stars.unknown ? "Following" : "Your team")
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
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            Text((game.session ?? drawn.kicker).uppercased()).font(SportCardMetrics.kicker).tracking(1.4)
                .foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: PigSpacing.xs) {
                if game.followed == true {
                    Image(systemName: "star.fill").font(SportCardMetrics.small).foregroundStyle(Color.pigAccentText)
                        .accessibilityLabel("Your team")
                }
                Text(game.title).font(SportCardMetrics.title).lineLimit(1)
            }
            Text([game.status == "scheduled" ? SportFrontText.startLine(game, now: now) : nil,
                  SportFrontText.isNextRound(game) ? nil : game.channels.first?.name].compactMap { $0 }.joined(separator: " · "))
                .font(SportCardMetrics.small).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// The state on the left (live: the red dot and the neutral progress; a result; the start time) and the channel or
    /// the action on the right.
    @ViewBuilder
    private func bottom(_ drawn: SportFrontText.Drawn, live: Bool) -> some View {
        HStack(spacing: PigSpacing.s) {
            if live {
                // #211: the card's clock is short ("Q4 0:17", "OT1 10:00"); the situation is the banner's.
                Circle().fill(Color.pigDanger).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(SportFrontText.cardClock(game, in: front, hidden: hidden)).font(SportCardMetrics.detail.weight(.bold))
                    .foregroundStyle(Color.pigDanger).lineLimit(1).pigMinimumScale(0.75, size: PigType.caption).layoutPriority(1)
            } else if game.terminal {
                Text(drawn.status).font(SportCardMetrics.detail.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            } else if game.competitors.count == 2 {
                Text(SportFrontText.startLine(game, now: now)).font(SportCardMetrics.detail.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if game.competitors.count == 2 {
                Text(SportFrontText.channelLine(game))
                    .font(SportCardMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(SportFrontText.actionLabel(game, now: now)).font(SportCardMetrics.small.weight(.bold))
                    .foregroundStyle(Color.pigAccentText).lineLimit(1).fixedSize().layoutPriority(2)
            }
        }
    }

    /// "Recording" (a red dot) or "Set to record" (a red ring), and "Clashes with …" when it loses its clash (C-R since
    /// 0415, #198): not a score, so shown with spoilers hidden too.
    private func recordingMark(_ mark: SportsGame.RecordingMark) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
            HStack(spacing: PigSpacing.s) {
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
