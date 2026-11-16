import SwiftUI

// Build 29: player pieces shared by the tvOS custom player and the iOS/iPadOS
// AVKit player, so iPhone and iPad look like the TV (Mark: the iPad showed no
// "Tuning…" and the old channel sheet). Sizes differ per platform
// (`PlayerMetrics`); behaviour and wording are the same.

enum PlayerMetrics {
    #if os(tvOS)
    static let tuningLogo = CGSize(width: 200, height: 110)
    // Brand 1.8 §15 (#279): no text under 23 pt on the television (rowIcon is a symbol).
    static let tuningName: CGFloat = 24, tuningTitle: CGFloat = 32, tuningDetail: CGFloat = 23
    static let tuningNext: CGFloat = 23, tuningBar: CGFloat = 360, tuningPadding: CGFloat = 48, tuningWidth: CGFloat = 720
    static let rowLogo = CGSize(width: 120, height: 66)
    static let rowName: CGFloat = 23, rowNumber: CGFloat = 23, rowTitle: CGFloat = 24, rowIcon: CGFloat = 16
    static let rowPadding = CGSize(width: 16, height: 10), rowRadius = PigRadius.compact, rowBar: CGFloat = 4
    /// #334: a live game row's score bug, in fixed columns (badge, team code, score) so the divider after it is at the
    /// same x on every row.
    static let gameBadge: CGFloat = 28, gameCode: CGFloat = 72, gameScore: CGFloat = 52, gameDivider: CGFloat = 2
    #else
    static let tuningLogo = CGSize(width: 150, height: 84)
    static let tuningName: CGFloat = 17, tuningTitle: CGFloat = 22, tuningDetail: CGFloat = 14
    static let tuningNext: CGFloat = 13, tuningBar: CGFloat = 260, tuningPadding: CGFloat = 28, tuningWidth: CGFloat = 440
    static let rowLogo = CGSize(width: 92, height: 52)
    static let rowName: CGFloat = 14, rowNumber: CGFloat = 12, rowTitle: CGFloat = 17, rowIcon: CGFloat = 13
    static let rowPadding = CGSize(width: 12, height: 8), rowRadius = PigRadius.compact, rowBar: CGFloat = 3
    static let gameBadge: CGFloat = 20, gameCode: CGFloat = 44, gameScore: CGFloat = 32, gameDivider: CGFloat = 1
    #endif
    /// The score bug's width: its three columns and the two gaps between them.
    static var gameBug: CGFloat { gameBadge + gameCode + gameScore + 2 * PigSpacing.s }
}

/// Pure text and numbers for the player's overlays (tested in
/// `PlayerSharedTests`).
nonisolated enum PlayerInfoText {
    /// "6:35 am – 9:35 am".
    static func timeRange(_ programme: GuideProgramme) -> String {
        "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
    }

    /// "Next: NRL 360 at 9:35 am", or nil.
    static func next(_ programme: GuideProgramme?) -> String? {
        programme.map { "Next: \($0.title) at \($0.start.formatted(date: .omitted, time: .shortened))" }
    }

    /// Share of the programme elapsed at `now`, 0…1.
    static func progress(_ programme: GuideProgramme, at now: Date) -> Double {
        PlayerTimeMath.fraction(of: now, from: programme.start, to: programme.end)
    }

    /// "29 min left" (at least one minute).
    static func remaining(_ programme: GuideProgramme, at now: Date) -> String {
        let minutes = max(1, Int((programme.end.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

// Neutral translucent logo tile shared by the player overlays (matches the
// guide's tile treatment, R04). Moved here from CustomPlayer.swift in build 29
// so the iOS tuning card, channel panel and info overlay use it too.
struct LogoTile: View {
    let logo: String?
    let client: APIClient?
    let name: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PigRadius.compact).fill(Color.logoTile(.dark))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client).padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            } else {
                Text(name).font(.system(size: PigType.secondary, weight: .semibold)).lineLimit(2)
                    .multilineTextAlignment(.center).pigMinimumScale(0.6, size: PigType.secondary).padding(PigSpacing.s)
            }
        }
    }
}

// A1.2 (tvOS), build 29 (iOS too): shown centred over black while resolving
// media or reconnecting, so a channel change reads as "tuning to something"
// rather than a blank wait. Built entirely from cached guide data
// (`playback.programme()`/`nextProgramme()`), so there is no network wait.
/// What the tuning card says while a start takes longer than usual (16 Oct: the iPhone sat on "Tuning…" with no
/// explanation while the provider was busy with a recording). The server answers a known conflict with a 409 and the
/// player asks; this covers the cases where it can't tell yet.
nonisolated enum TuningText {
    static let slowAfter: TimeInterval = 20

    static func hint(elapsed: TimeInterval) -> String? {
        guard elapsed >= slowAfter else { return nil }
        return "This is taking longer than usual. The provider may be busy with a recording or another device. You can cancel and try again."
    }
}

/// #6: a mid-play wait for data, so a stall reads as buffering rather than a frozen app.
struct BufferingPill: View {
    var body: some View {
        HStack(spacing: PigSpacing.s) {
            ProgressView()
            Text("Buffering…").font(.headline)
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        .background(Color.pigMediaPanel, in: Capsule())
        .foregroundStyle(.white)
        .padding(.top, PigSpacing.section)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Buffering")
    }
}

struct TuningCard: View {
    @ObservedObject var playback: PlaybackModel
    let browse: BrowseModel?
    let message: String
    @State private var shownAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let programme = playback.programme(at: context.date)
            let next = playback.nextProgramme(after: context.date)
            VStack(spacing: PlayerMetrics.tuningPadding * 0.375) {
                LogoTile(logo: browse?.logo(for: playback.channel) ?? playback.channel.logo,
                         client: browse?.client, name: playback.channel.name)
                    .frame(width: PlayerMetrics.tuningLogo.width, height: PlayerMetrics.tuningLogo.height)
                Text(playback.channel.name).font(.system(size: PlayerMetrics.tuningName, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(programme?.title ?? "No programme information")
                    .font(.system(size: PlayerMetrics.tuningTitle, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                if let programme {
                    Text(PlayerInfoText.timeRange(programme))
                        .font(.system(size: PlayerMetrics.tuningDetail, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: geometry.size.width * PlayerInfoText.progress(programme, at: context.date))
                        }
                    }.frame(width: PlayerMetrics.tuningBar, height: 6)
                }
                if let next = PlayerInfoText.next(next) {
                    Text(next).font(.system(size: PlayerMetrics.tuningNext)).foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: PigSpacing.s) {
                    ProgressView().tint(.white)
                    Text(message).font(.system(size: PlayerMetrics.tuningNext, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.top, PigSpacing.xs)
                if let hint = TuningText.hint(elapsed: context.date.timeIntervalSince(shownAt)) {
                    Text(hint).font(.system(size: PlayerMetrics.tuningNext)).foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tuning.slow")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(PlayerMetrics.tuningPadding)
        .frame(maxWidth: PlayerMetrics.tuningWidth)
        .background(Color.pigMediaPanel, in: RoundedRectangle(cornerRadius: PigRadius.hero))
        .accessibilityElement(children: .combine)
    }
}

/// One row of the player's channel list: logo tile, name (and a muted
/// number), what is on now and its progress. The TV's side list and the
/// iOS channel panel (build 29) both draw it.
struct PlayerChannelRow: View {
    let channel: Channel
    let browse: BrowseModel?
    let highlighted: Bool
    let playing: Bool
    let now: Date

    var body: some View {
        let programmes = browse?.programmes(for: channel) ?? []
        let current = GuideNavigation.programme(in: programmes, at: now)
        HStack(spacing: PlayerMetrics.rowPadding.width) {
            LogoTile(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client, name: channel.name)
                .frame(width: PlayerMetrics.rowLogo.width, height: PlayerMetrics.rowLogo.height)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(channel.name).font(.system(size: PlayerMetrics.rowName)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    if let number = channel.numberText {
                        ChannelNumberText(number: number, font: .system(size: PlayerMetrics.rowNumber, weight: .medium), onDark: true)
                    }
                    if playing {
                        Image(systemName: "play.fill").font(.system(size: PlayerMetrics.rowIcon)).foregroundStyle(Color.pigMediaAccent)
                    }
                }
                Text(current?.title ?? "No programme information")
                    .font(.system(size: PlayerMetrics.rowTitle, weight: .semibold)).lineLimit(1)
                if let current {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.pigMediaAccent)
                                .frame(width: geometry.size.width * PlayerInfoText.progress(current, at: now))
                        }
                    }.frame(height: PlayerMetrics.rowBar)
                }
            }
            Spacer(minLength: 0)
            // D-67: the channel's measured quality, small and trailing (nothing when it has not been measured).
            if let chip = PlayerQualityTag.chip(measured: browse?.measured(for: channel) ?? channel.measured) {
                QualityBadge(chip: chip, font: .system(size: PlayerMetrics.rowNumber, weight: .bold), onDark: true)
            }
        }
        .modifier(PlayerRowPanel(highlighted: highlighted, playing: playing))
    }
}

/// D-67 (#265): the players' quality tag: the playing channel's measured badge when the server has measured it, else
/// the decoded picture's height ("1080p"), else nothing (before the first frame is sized).
struct PlayerQualityBadge: View {
    let measured: MeasuredQuality?
    let decodedHeight: CGFloat
    let font: Font

    var body: some View {
        if let chip = PlayerQualityTag.chip(measured: measured) {
            QualityBadge(chip: chip, font: font, onDark: true)
        } else if let tag = PlayerQualityTag.decoded(height: decodedHeight) {
            Text(tag).font(font).foregroundStyle(.white)
                .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xxs)
                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: PigRadius.inner))
        }
    }
}

/// The panel every row of the player's list sits on (#334: the channel rows and the live game rows share it, so the two
/// lists look the same): padding, the black panel, the accent tint and stroke when highlighted, the TV's lift.
struct PlayerRowPanel: ViewModifier {
    /// The TV's lift of the highlighted row, anchored at its leading edge (so it grows to the right).
    static let lift: CGFloat = 1.03

    /// The room a list of these rows keeps on its trailing side, so the lifted row (its quality badge last) ends a focus
    /// clearance inside a list `width` wide instead of touching or being clipped by its edge. None on touch (no lift).
    static func trailingRoom(listWidth width: CGFloat) -> CGFloat {
        #if os(tvOS)
        ((width * (lift - 1) + PigFocus.clearance) / lift).rounded(.up)
        #else
        0
        #endif
    }

    let highlighted: Bool
    let playing: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, PlayerMetrics.rowPadding.width).padding(.vertical, PlayerMetrics.rowPadding.height)
            .background(highlighted ? Color.pigMediaAccent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: PlayerMetrics.rowRadius))
            .background(Color.pigMediaPanel,
                        in: RoundedRectangle(cornerRadius: PlayerMetrics.rowRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PlayerMetrics.rowRadius)
                    .strokeBorder(highlighted ? Color.pigMediaAccent : .clear, lineWidth: 3)
            }
            #if os(tvOS)
            .scaleEffect(highlighted ? Self.lift : 1, anchor: .leading)
            #endif
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(playing ? .isSelected : [])
    }
}

/// #334 (D-67): one live game in the player's list, as drawn. Pure (`PlayerGames`, tests `PlayerGamesTests`).
nonisolated struct PlayerGame: Equatable, Identifiable, Sendable {
    struct Side: Equatable, Sendable {
        let name: String
        /// The competitor's abbreviation, else the first three letters of its name in capitals.
        let code: String
        /// A same-server logo path, or nil (the monogram disc).
        let logo: String?
        /// Nil: no score drawn (hidden, recording, no scores feed, or none sent).
        let score: String?
    }

    let game: SportsGame
    let league: String
    /// Where the game is up to ("Q4 0:17", "2nd half 67'", "On air · starts 3:10 pm", "LIVE").
    let clock: String
    /// Both competitors in the server's order; nil for a game without two (a race): its title and clock only.
    let sides: [Side]?
    /// Someone in the household is recording it: "Recording" shows and no score does (D-66).
    let recording: Bool

    var id: String { game.id }
    var title: String { game.title }
}

/// #334 (D-67): a live play started from Sport lists the live games instead of the channels: the Sport front page's
/// games that are under way (live, at a break, suspended) or on air before play, with a channel to play them on,
/// followed games first, each group in the answer's order. Scores follow D-66: hidden when the household hides them
/// (or the preference is unknown), when the game is being recorded, without the scores feed, or when the server sent
/// none (fail closed).
nonisolated enum PlayerGames {
    static let header = "Live games"
    static let channelsHeader = "Channels"
    static let noOthers = "No other games live"
    static let recordingTag = "Recording"

    /// A game picked from the list is no longer on air on its channel.
    static func notOnAir(_ title: String) -> String { "\(title) isn’t on air now" }

    /// `hidden`: the screen's decision (`SportSpoilers.hidden`, from the account's preference); the answer's own switch
    /// still hides here. `labels`: the catalogue's league names.
    /// `now`: a game whose preferred channel no longer airs it (a cached answer) is left out (`SportFrontText.playable`).
    static func list(_ front: SportFront?, hidden: Bool, labels: [String: String] = [:],
                     calendar: Calendar = .current, now: Date = Date()) -> [PlayerGame] {
        guard let front else { return [] }
        let live = front.games.filter {
            SportFrontText.showsLive($0) && !$0.channels.isEmpty && SportFrontText.playable($0, at: now) != nil
        }
        let ordered = live.filter { $0.followed == true } + live.filter { $0.followed != true }
        let withheld = SportSpoilers.hidden(preference: hidden, answer: front.spoilerFree, page: false)
        return ordered.map { row($0, in: front, hidden: withheld, labels: labels, calendar: calendar) }
    }

    static func row(_ game: SportsGame, in front: SportFront, hidden: Bool, labels: [String: String] = [:],
                    calendar: Calendar = .current) -> PlayerGame {
        let recording = game.recording != nil
        let withheld = hidden || recording
        let scores = SportFrontText.drawn(game, in: front, hidden: withheld).scores
        var sides: [PlayerGame.Side]?
        if game.competitors.count == 2, game.family != .motorsport {
            sides = game.competitors.enumerated().map { index, team in
                PlayerGame.Side(name: team.name, code: code(team), logo: team.cachedLogo,
                                score: scores.flatMap { $0.indices.contains(index) ? $0[index] : nil })
            }
        }
        return PlayerGame(game: game, league: labels[game.league] ?? game.league,
                          clock: SportFrontText.cardClock(game, in: front, hidden: withheld, calendar: calendar),
                          sides: sides, recording: recording)
    }

    /// The competitor's abbreviation, else the first three letters (or digits) of its name in capitals.
    static func code(_ team: SportsGame.Competitor) -> String {
        if let abbreviation = team.abbreviation { return abbreviation }
        let letters = String(team.name.filter { $0.isLetter || $0.isNumber }.prefix(3)).uppercased()
        return letters.isEmpty ? "?" : letters
    }

    /// A badge without a logo shows the team code ("GB"), as the row does, not the name's initials ("GP").
    static func monogram(_ side: PlayerGame.Side) -> String { side.code }

    /// The row of the game playing: the event the play began with, else the game whose preferred channel is the one
    /// playing, else one that is on it at all.
    static func playing(_ games: [PlayerGame], eventID: String?, channelID: String?) -> Int? {
        if let eventID, let index = games.firstIndex(where: { $0.id == eventID || SportFrontText.event($0.game)?.id == eventID }) {
            return index
        }
        guard let channelID else { return nil }
        return games.firstIndex { $0.game.channels.first?.id == channelID }
            ?? games.firstIndex { $0.game.channels.contains { $0.id == channelID } }
    }

    /// Whether there is another game to go to: with only the one playing (or none), the list does not open and the player
    /// says `noOthers`.
    static func hasOthers(_ games: [PlayerGame], playing: Int?) -> Bool {
        games.indices.contains { $0 != playing }
    }
}

/// #334: reads the live games for the player's list from the Sport front page's model and the account's preference,
/// observing both (a refreshed answer or a changed Hide scores redraws the rows).
struct PlayerGamesReader<Content: View>: View {
    @ObservedObject var front: SportFrontModel
    @ObservedObject var preferences: F1PageModel
    @ViewBuilder let content: ([PlayerGame]) -> Content

    var body: some View { content(PlayerGames.current(front: front, preferences: preferences)) }
}

extension PlayerGames {
    /// The list from the models as they are now (the TV player's remote reads it at the moment of a press).
    @MainActor static func current(front: SportFrontModel, preferences: F1PageModel) -> [PlayerGame] {
        let hidden = SportSpoilers.hidden(preference: preferences.hidesSpoilers, answer: front.front?.spoilerFree, page: false)
        return list(front.front, hidden: hidden, labels: front.labels)
    }
}

/// #334 (D-67): one row of the player's live games list. The channel row's panel exactly (`PlayerRowPanel`); only the
/// content differs: a score bug in fixed columns (badge, code, score for each side, two lines), a divider at the same x
/// on every row, then the league, the Recording tag and the playing marker, and where the game is up to. A game without
/// two sides (a race) has its title in the bug's place.
struct PlayerGameRow: View {
    let game: PlayerGame
    let client: APIClient?
    let highlighted: Bool
    let playing: Bool

    var body: some View {
        HStack(spacing: PlayerMetrics.rowPadding.width) {
            Group {
                if let sides = game.sides {
                    VStack(alignment: .leading, spacing: PigSpacing.xs) {
                        ForEach(Array(sides.enumerated()), id: \.offset) { _, side in sideLine(side) }
                    }
                } else {
                    Text(game.title).font(.system(size: PlayerMetrics.rowName, weight: .semibold)).lineLimit(2)
                }
            }
            .frame(width: PlayerMetrics.gameBug, height: PlayerMetrics.rowLogo.height, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.3))
                .frame(width: PlayerMetrics.gameDivider, height: PlayerMetrics.rowLogo.height)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                    Text(game.league).font(.system(size: PlayerMetrics.rowName)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    if game.recording {
                        Label(PlayerGames.recordingTag, systemImage: "record.circle.fill")
                            .font(.system(size: PlayerMetrics.rowName, weight: .semibold)).foregroundStyle(Color.pigDanger)
                            .lineLimit(1)
                    }
                    if playing {
                        Image(systemName: "play.fill").font(.system(size: PlayerMetrics.rowIcon)).foregroundStyle(Color.pigMediaAccent)
                    }
                }
                Text(game.clock).font(.system(size: PlayerMetrics.rowTitle, weight: .semibold)).pigFigures().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .modifier(PlayerRowPanel(highlighted: highlighted, playing: playing))
    }

    private func sideLine(_ side: PlayerGame.Side) -> some View {
        HStack(spacing: PigSpacing.s) {
            SportBadge(name: side.name, logo: side.logo, league: game.game.league, client: client, size: PlayerMetrics.gameBadge,
                       monogram: PlayerGames.monogram(side))
                .frame(width: PlayerMetrics.gameBadge)
            Text(side.code).font(.system(size: PlayerMetrics.rowName, weight: .semibold)).lineLimit(1)
                .frame(width: PlayerMetrics.gameCode, alignment: .leading)
                .accessibilityLabel(side.name)
            Text(side.score ?? "").font(.system(size: PlayerMetrics.rowTitle, weight: .bold)).pigFigures().lineLimit(1)
                .frame(width: PlayerMetrics.gameScore, alignment: .trailing)
        }
    }
}

/// The player's Favourite and Record actions, shared by the TV info overlay's
/// action row and the iOS info overlay. Each returns the notice to show.
@MainActor
enum PlayerCommands {
    static func setFavourite(_ value: Bool, channel: Channel, browse: BrowseModel) async -> (ok: Bool, notice: String) {
        let ok = await browse.setFavourite(channel, value)
        return (ok, ok ? (value ? "Added to favourites" : "Removed from favourites") : "Couldn't update favourites")
    }

    /// Records what is on now on the playing channel (no padding).
    static func recordNow(playback: PlaybackModel, browse: BrowseModel) async -> String {
        guard let channel = browse.guideChannel(id: playback.channel.id), let programme = playback.programme() else {
            return "No programme information to record"
        }
        if browse.scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime)) {
            return "Already scheduled — manage it in Recordings"
        }
        let ok = await browse.schedule(channel: channel, programme: programme, before: 0, after: 0)
        guard ok else { return browse.actionError ?? "Couldn't schedule the recording" }
        if let already = browse.scheduleAlready { return already } // #329
        // #148 (D-28): a clash is said at once, in the player too.
        return browse.scheduleClash.map { "Recording \(programme.title). \($0)" } ?? "Recording \(programme.title)"
    }
}

extension AppModel {
    /// The player's channel list: the guide's row order when playback began
    /// (the zap list), else the whole guide.
    var playerChannels: [Channel] {
        if !zapList.isEmpty { return zapList }
        return browse.map { model in model.guide.map(model.asChannel) } ?? []
    }
}

/// iOS/iPadOS player chrome visibility (build 31: PigTV's controls are the
/// only ones; AVKit's are off). A tap on the picture toggles the controls;
/// they hide after 4 idle seconds unless playback is paused or a panel (the
/// channel list, Go to number) is open. Dragging the scrub bar counts as
/// input, so the controls never hide under the finger.
nonisolated enum PlayerChromeTimer {
    static let idle: TimeInterval = 4

    /// Visibility after a tap on the picture (taps on PigTV's own buttons
    /// never reach it).
    static func afterTap(visible: Bool) -> Bool { !visible }

    static func shouldHide(visible: Bool, lastInput: Date, now: Date, paused: Bool, panelOpen: Bool) -> Bool {
        visible && !paused && !panelOpen && now.timeIntervalSince(lastInput) >= idle
    }
}

/// The seekable (live buffer) window in the player item's
/// seconds, for the touch scrub bar (build 31). Pure: position ↔ fraction
/// mapping and the behind-live readout, tested in `PlayerSharedTests`.
/// #7 (D-36, build 72): a live play starts without a fixed hold, which turned a new play's first delivery pause into a
/// ~26 s frozen picture, and builds the same hold by playing slightly slower (pitch kept) until it is
/// `PlayerSeekWindow.liveOffset` behind the edge; measured in the server's docs/evidence/2026-10-30-live-hold-variants.
nonisolated enum LiveCatchUp {
    static let slowRate: Float = 0.97
    /// The rate for a play `behind` seconds behind the live edge (not finite while unknown). A source that ends plays at 1.
    static func rate(behind: Double, live: Bool) -> Float {
        guard live else { return 1 }
        return behind.isFinite && behind >= PlayerSeekWindow.liveOffset ? 1 : slowRate
    }
}

nonisolated struct PlayerSeekWindow: Equatable, Sendable {
    var start: Double
    var end: Double
    var current: Double
    /// A live playlist (no end): only then is a play held back from the end (build 57, Codex review of 56).
    var live: Bool = true
    /// How far behind the live edge a live play is held (build 56). Some providers deliver in bursts with pauses of up
    /// to ~16 s, and a healthy one fell 18.3 s behind (server FINDINGS FR-8); AVPlayer's default start, about three
    /// target durations (~12 s), runs dry in one. The server calls a feed lost at 24 s, before this runs out.
    /// Since build 72 (#7, D-36) a play builds this hold at `LiveCatchUp.slowRate` instead of starting with it.
    static let liveOffset: Double = 30
    /// Within this many seconds of the end reads as live (as on the TV): the held offset plus slack.
    static let liveMargin: Double = liveOffset + 10

    /// The furthest a seek goes: for a live playlist the held offset from the end, never before the window's
    /// start; for one that ends (a finite source), the end itself.
    static func liveTarget(start: Double, end: Double, live: Bool) -> Double { live ? max(start, end - liveOffset) : end }

    /// Nil when there is nothing meaningful to scrub (under 5 s, or not finite).
    init?(start: Double, end: Double, current: Double, live: Bool = true) {
        guard start.isFinite, end.isFinite, current.isFinite, end - start > 5 else { return nil }
        self.start = start; self.end = end; self.current = current; self.live = live
    }

    var duration: Double { end - start }
    /// Where the picture is, 0…1 through the window.
    var fraction: Double { Self.clamp((current - start) / duration) }
    func time(at fraction: Double) -> Double { start + Self.clamp(fraction) * duration }
    func behindLive(at fraction: Double) -> Double { max(0, end - time(at: fraction)) }
    func isLive(at fraction: Double) -> Bool { behindLive(at: fraction) <= Self.liveMargin }
    /// The target of a ±seconds skip, clamped to the window and never nearer the edge than the held offset. A play still
    /// building its hold (nearer the edge than the offset, build 72) is never moved back by a forward skip.
    func skipTarget(_ seconds: Double) -> Double {
        min(max(current + seconds, start), max(current, Self.liveTarget(start: start, end: end, live: live)))
    }
    /// Where a scrub released at `fraction` lands: never nearer the edge than the held offset, and, for a play still
    /// building its hold, never further forward than where it is (#159).
    func scrubTarget(at fraction: Double) -> Double {
        min(time(at: fraction), max(current, Self.liveTarget(start: start, end: end, live: live)))
    }

    /// A drag's x position on a track `width` wide → fraction.
    static func fraction(forX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return clamp(x / width)
    }

    /// "LIVE", or "2:15 behind live" / "1 h 05 min behind live".
    func readout(at fraction: Double) -> String {
        isLive(at: fraction) ? "LIVE" : "\(PlayerTimeMath.behindText(behindLive(at: fraction))) behind live"
    }

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

/// #37 (Mark, 30 Oct; C-W): a paused live play keeps its stream up to 30 minutes on the server. The
/// server keeps about 6 minutes of the channel, so a longer pause resumes at live, and past 30 minutes the stream has
/// gone and the play starts again at live. A warning 2 minutes before the end.
nonisolated enum LivePause {
    static let maxSeconds: TimeInterval = 30 * 60
    static let warnSeconds: TimeInterval = 28 * 60
    /// The server's window (90 four-second pieces) less a margin.
    static let windowSeconds: TimeInterval = 5 * 60 + 30

    enum Resume: Equatable { case inPlace, toLive, again }

    static func resume(after paused: TimeInterval) -> Resume {
        paused >= maxSeconds ? .again : paused >= windowSeconds ? .toLive : .inPlace
    }

    /// What the player says while paused, or nil.
    static func notice(after paused: TimeInterval) -> String? {
        if paused >= maxSeconds { return "Paused for 30 minutes, so the stream was stopped. Play goes back to live." }
        if paused >= warnSeconds { return "Paused for 28 minutes: the stream stops in 2 minutes unless you play." }
        return nil
    }
}
