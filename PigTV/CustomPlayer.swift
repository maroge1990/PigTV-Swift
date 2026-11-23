#if os(tvOS)
import SwiftUI
import AVFoundation
import AVKit

// PigTV-owned live player (roadmap R07/R08). AVKit's controls are replaced
// by an overlay modelled on the reference IPTV layout, and every Siri Remote
// press is handled here so Up/Down can open the side channel list.
// The only live player on Apple TV; the AVKit fallback was retired in build 13.
//
// Remote map
//   Controls hidden:  Up/Down → channel list · Select → info
//                     Left/Right → rewind/forward 15 s (scrub bar)
//                     Play/Pause → pause/resume (shows info) · Back → guide
//   Scrub bar:        Left/Right → keep seeking · Select → info
//                     Up/Down/Back → hide
//   Info shown:       two lines of buttons (#58 option B, `PlayerButtons`, `PlayerCursor`): the row (Pause, Audio &
//                     subtitles, Favourite, Record, Last channel, Labs' sync marker) and the progress bar (Start over at
//                     its start when a recording of the programme on now exists, #308; Go to live at its end when
//                     behind or paused). It opens on the row's first button. Left/Right → choose in the line · Select →
//                     run it · Down → the bar (its right end) when it has a button · Up → back to the row · Up from the
//                     row, Down from the bar (or from the row with nothing on the bar), Back → hide
//                     "Last channel" (A1.2) shows when a previous channel is
//                     remembered and differs from the current one.
//   Channel list:     Up/Down → move · Select → switch · Back → close
//   #334: a play started from Sport lists the live games in the channel list's place (Select plays the game on its
//   preferred channel); with no other game live, Up/Down says so instead of opening it.
// Overlays hide themselves after a few idle seconds.
// A1.2: a long-press-Select shortcut for "last channel" while hidden was
// considered and rejected — see the note above `select()`.

enum PlayerChrome: Equatable {
    case hidden, info, channels, tracks, scrub
}

struct CustomPlayerView: View {
    /// Room above and below the channel list, so its first and last rows can scroll to the centre.
    private static let channelListOverscroll: CGFloat = 340
    /// The channel list's width; its rows keep `PlayerRowPanel.trailingRoom` free for the highlighted row's lift.
    static let channelListWidth: CGFloat = 640
    @ObservedObject var playback: PlaybackModel
    let app: AppModel
    let exit: () -> Void
    @State private var chrome: PlayerChrome = .info
    /// Where the remote is in the row and on the bar (#58).
    @State private var buttonCursor = PlayerCursor()
    @State private var cursor = 0
    @State private var paused = false
    @State private var lastInput = Date()
    @State private var notice: String?
    @State private var favourite = false
    @State private var busy = false
    // Direction of the latest seek, for the scrub bar's ⏪/⏩ indicator.
    @State private var seekForward = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // A4.2: Labs → Stream info overlay.
    @AppStorage(Labs.streamInfo) private var showsStreamInfo = false
    // #268: Labs → Sync marker button.
    @AppStorage(Labs.syncMarker) private var syncMarker = false

    private var browse: BrowseModel? { app.browse }
    private var channels: [Channel] { app.playerChannels }
    /// #334: the list shows the live games (a play from Sport).
    private var gamesMode: Bool { app.playerShowsGames && browse != nil }
    /// The live games as they are now (read at a press; the list itself observes the models).
    private var games: [PlayerGame] {
        guard let browse else { return [] }
        return PlayerGames.current(front: browse.sportFront, preferences: browse.f1Page)
    }
    private func playingGame(in games: [PlayerGame]) -> Int? {
        PlayerGames.playing(games, eventID: app.sportPlay?.eventID, channelID: playback.channel.id)
    }
    /// #348: the game's own channels, the list's first rows in games mode.
    private var gameChannels: [Channel] { gamesMode ? app.playerGameChannels : [] }
    /// How many rows the open list has.
    private var listCount: Int { gamesMode ? gameChannels.count + games.count : channels.count }
    // Channels are reached with Up/Down (the side list), so the row carries no Channels button. #58 option B: Start
    // over (#308) and Go to live (only when behind or paused) on the bar, the rest in the row.
    private func buttons(at now: Date = Date()) -> PlayerButtons {
        PlayerButtons.live(startOver: startOverRecording(at: now) != nil, goLive: playback.behindLive || paused,
                           tracks: playback.hasTrackChoice,
                           lastChannel: app.previousChannel.map { $0.id != playback.channel.id } ?? false,
                           syncMarker: syncMarker)
    }
    /// #308: the recording being made of the programme on this channel now, when it can be watched from its start.
    private func startOverRecording(at now: Date) -> Recording? {
        browse?.startOverRecording(channel: playback.channel, at: now)
    }
    @State private var trackCursor = 0
    private var allTracks: [PlaybackModel.MediaTrack] { playback.audioTracks + playback.subtitleTracks }

    var body: some View {
        // A Button owns the primary (Select) action: on tvOS this fires on the
        // first click, where `.onTapGesture` needed a second press and felt slow.
        // A1.2 considered a long-press-Select shortcut ("hold Select while
        // chrome is hidden to jump to the last channel") via
        // `.simultaneousGesture(LongPressGesture(...))` on this same Button,
        // but a second gesture recogniser competing with the Button's own
        // click handling is exactly the fragility the comment above already
        // called out for `.onTapGesture`, and it cannot be verified without
        // driving the simulator interactively. Skipped: "Last channel" is
        // reachable only via the info overlay's action row.
        Button(action: select) {
            ZStack {
                PlayerLayerView(player: playback.player, criteria: playback.displayCriteria, mode: playback.displayCriteriaMode,
                                play: playback.id).ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        if chrome == .info { infoOverlay(now: context.date) }
                        if chrome == .channels { channelList(now: context.date) }
                        if chrome == .tracks { tracksPanel }
                        if chrome == .scrub { scrubBar(now: context.date) }
                        if let notice {
                            Text(notice).font(.callout.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
                                .background(panelFill, in: Capsule())
                                .frame(maxHeight: .infinity, alignment: .top).padding(.top, PigSpacing.tvSafeTop)
                        }
                    }
                    .onChange(of: context.date) { _, now in
                        settle(now) // Start over and Go to live come and go with the clock and the playhead
                        autoHide(now)
                    }
                }
                .pigAnimation(value: chrome)
            }
        }
        .buttonStyle(BlankButtonStyle())
        #if DEBUG
        .accessibilityIdentifier("review.livePlayer")
        .accessibilityValue("\(chrome); \(PlayerCursor.describe(buttonCursor, buttons())); track=\(trackCursor); channel=\(cursor); selected=\(allTracks.filter { $0.selected }.map(\.id).joined(separator: ","))")
        #endif
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .focused($focused)
        .onAppear {
            focused = true
            buttonCursor.open(in: buttons())
            favourite = browse?.isFavourite(playback.channel) ?? false
            cursor = channels.firstIndex { $0.id == playback.channel.id } ?? 0
        }
        // #132: the tuning card held focus until the first picture.
        .onChange(of: playback.hasPlayed) { _, played in if played { focused = true } }
        .task(id: playback.ready) { if playback.ready { await playback.loadTracks() } }
        // #334: a game picked from the list that is no longer on air.
        .onChange(of: app.playerNotice) { _, text in
            guard let text else { return }
            notice = text
            touch()
            app.playerNotice = nil
        }
        // #334: the live games are read again when a play from Sport begins (the Sport pages rest under the player),
        // and kept fresh while the list is open.
        .task(id: app.sportPlay) {
            guard gamesMode, let browse else { return }
            await browse.sportFront.refresh(preferences: browse.f1Page)
        }
        .task(id: chrome == .channels && gamesMode) {
            guard chrome == .channels, gamesMode, let browse else { return }
            await browse.sportFront.keepFresh(preferences: browse.f1Page)
        }
        .onMoveCommand(perform: move)
        .onPlayPauseCommand(perform: togglePause)
        .onExitCommand(perform: back)
    }

    // MARK: Remote

    private func touch() { lastInput = Date() }

    private func move(_ direction: MoveCommandDirection) {
        touch()
        switch (chrome, direction) {
        case (.hidden, .up), (.hidden, .down):
            openList()
        case (.hidden, .left), (.scrub, .left):
            seek(-15)
        case (.hidden, .right), (.scrub, .right):
            seek(15)
        case (.scrub, _):
            chrome = .hidden
        case (.hidden, _):
            showInfo()
        case (.info, _):
            guard let move = PlayerCursor.Move(direction) else { return }
            if !buttonCursor.move(move, in: buttons()) { chrome = .hidden }
        case (.channels, .up):
            let count = listCount
            if count > 0 { cursor = (cursor - 1 + count) % count }
        case (.channels, .down):
            let count = listCount
            if count > 0 { cursor = (cursor + 1) % count }
        case (.channels, _):
            break
        case (.tracks, .up):
            if !allTracks.isEmpty { trackCursor = (trackCursor - 1 + allTracks.count) % allTracks.count }
        case (.tracks, .down):
            if !allTracks.isEmpty { trackCursor = (trackCursor + 1) % allTracks.count }
        case (.tracks, _):
            break
        }
    }

    // Seeking gets its own minimal chrome rather than the full info overlay,
    // so it is obvious that Left/Right are rewinding or fast-forwarding (R17).
    private func seek(_ seconds: Double) {
        seekForward = seconds > 0
        playback.skip(seconds)
        chrome = .scrub
    }

    private func select() {
        touch()
        switch chrome {
        case .hidden, .scrub:
            showInfo()
        case .info:
            guard let item = buttonCursor.current(in: buttons()) else { return }
            run(item)
        case .channels:
            if gamesMode {
                let gameChannels = self.gameChannels
                if gameChannels.indices.contains(cursor) {
                    // #348: another channel of the game playing (Watch another channel, inside the player).
                    let target = gameChannels[cursor]
                    chrome = .hidden
                    if target.id != playback.channel.id { app.switchPlayback(to: target) }
                    return
                }
                let games = self.games
                let index = cursor - gameChannels.count
                guard games.indices.contains(index) else { return }
                chrome = .hidden
                // #334: the game on its preferred channel, no picker; the list stays the live games.
                if index != playingGame(in: games) { app.playSportGame(games[index]) }
                return
            }
            guard channels.indices.contains(cursor) else { return }
            let target = channels[cursor]
            chrome = .hidden
            // Browsing never resolved media; only this choice switches, via
            // the existing release-before-switch path.
            if target.id != playback.channel.id { app.switchPlayback(to: target) }
        case .tracks:
            // Apply the track but keep the panel open so audio and subtitles
            // can both be set; Back closes it.
            guard allTracks.indices.contains(trackCursor) else { return }
            playback.selectTrack(allTracks[trackCursor].id)
        }
    }

    private func back() {
        touch()
        if chrome == .hidden { exit() } else { chrome = .hidden }
    }

    /// Opens the side list on the row playing. #334: the live games for a play from Sport; with no other game live the
    /// list stays closed and the notice says so.
    private func openList() {
        if gamesMode {
            let games = self.games
            let playing = playingGame(in: games)
            let gameChannels = self.gameChannels
            guard PlayerGames.hasOthers(games, playing: playing, gameChannels: gameChannels) else {
                notice = PlayerGames.noOthers
                return
            }
            cursor = PlayerGames.openingRow(gameChannels: gameChannels, playingChannel: playback.channel.id, playingGame: playing)
        } else {
            cursor = channels.firstIndex { $0.id == playback.channel.id } ?? 0
        }
        chrome = .channels
    }

    /// The remote's Play/Pause: pauses or plays and shows the info.
    private func togglePause() {
        touch()
        pauseOrPlay()
        showInfo()
    }

    private func pauseOrPlay() {
        if playback.player.rate == 0 { playback.player.play(); paused = false }
        else { playback.player.pause(); paused = true }
    }

    /// The info opens on the row's first button (#335: never Go to live); already open, it stays where it is.
    private func showInfo() {
        if chrome != .info { buttonCursor.open(in: buttons()) }
        chrome = .info
    }

    private func settle(_ now: Date = Date()) {
        let settled = buttonCursor.settled(in: buttons(at: now))
        if settled != buttonCursor { buttonCursor = settled }
    }

    private func autoHide(_ now: Date) {
        let limit: TimeInterval = chrome == .channels || chrome == .tracks ? 8 : chrome == .scrub ? 4 : 6
        if chrome != .hidden, !paused, now.timeIntervalSince(lastInput) > limit { chrome = .hidden }
        if notice != nil, now.timeIntervalSince(lastInput) > 3 { notice = nil }
    }

    private func run(_ item: PlayerButton) {
        switch item {
        case .playPause:
            pauseOrPlay()
        case .startOver:
            // #308: the Guide's Watch from start: this play ends, and the recording plays from the programme's start.
            guard let recording = startOverRecording(at: Date()) else { settle(); return }
            chrome = .hidden
            app.startOver(playback, recording: recording)
        case .skipBreak, .autoSkip:
            break // a recording's
        case .tracks:
            trackCursor = max(0, allTracks.firstIndex { $0.selected } ?? 0)
            chrome = .tracks
        case .goLive:
            playback.goToLive(); paused = false
            notice = "Back to live"
            settle()
        case .lastChannel:
            app.returnToPreviousChannel()
        case .syncMarker:
            // #268: one av-desync event; a second press within 10 s is ignored.
            if playback.markSoundOutOfStep() { notice = SyncMarker.confirmation }
        case .favourite:
            guard let browse, !busy else { return }
            let value = !favourite
            busy = true
            Task {
                let result = await PlayerCommands.setFavourite(value, channel: playback.channel, browse: browse)
                busy = false
                if result.ok { favourite = value }
                notice = result.notice
                touch()
            }
        case .record:
            guard let browse, !busy else { notice = "No programme information to record"; return }
            busy = true
            Task {
                notice = await PlayerCommands.recordNow(playback: playback, browse: browse)
                busy = false
                touch()
            }
        }
    }

    // MARK: Info overlay

    private var panelFill: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color.pigMediaSolidPanel) : AnyShapeStyle(Color.pigMediaPanel)
    }

    private func infoOverlay(now: Date) -> some View {
        // C-E: once rewound, describe what is on screen, not what is live.
        let programme = playback.programme(at: now)
        let next = playback.nextProgramme(after: now)
        let shown = buttons(at: now)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    LogoTile(logo: browse?.logo(for: playback.channel) ?? playback.channel.logo, client: browse?.client,
                             name: playback.channel.name)
                        .frame(width: 180, height: 100)
                    HStack(alignment: .firstTextBaseline, spacing: PigSpacing.s) {
                        Text(playback.channel.name)
                            .font(.system(size: PigType.cardTitle, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        // C-A, build 29: the number small and muted after the name.
                        if let number = playback.channel.numberText {
                            ChannelNumberText(number: number, font: .system(size: PigType.secondary, weight: .medium), onDark: true)
                        }
                    }
                    Text(programme?.title ?? "No programme information")
                        .font(.system(size: PigType.hero, weight: .bold)).lineLimit(2)
                    if let programme {
                        Text("\(programme.start.formatted(date: .omitted, time: .shortened)) — \(programme.end.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: PigType.cardTitle, weight: .medium)).pigFigures()
                        if let description = programme.description, !description.isEmpty {
                            Text(description).font(.system(size: PigType.body)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    // D-67: the measured quality when known, else the decoded picture's height.
                    PlayerQualityBadge(measured: browse?.measured(for: playback.channel) ?? playback.channel.measured,
                                       decodedHeight: playback.player.currentItem?.presentationSize.height ?? 0,
                                       font: .system(size: PigType.caption, weight: .semibold))
                    if showsStreamInfo { StreamInfoLine(playback: playback) }
                }
                Spacer()
                actionRow(shown)
            }
            timeline(programme: programme, next: next, now: now, shown: shown).padding(.top, PigSpacing.l)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PigSpacing.tvSafeSide).padding(.bottom, PigSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: Color.pigMediaCanvas.opacity(reduceTransparency ? 0.95 : 0.82), location: 0.22),
                                   .init(color: Color.pigMediaCanvas.opacity(reduceTransparency ? 0.95 : 0.9), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 620).ignoresSafeArea()
        }
        // Sit against the screen bottom rather than the title-safe inset, which
        // left a visible gap below the overlay.
        .ignoresSafeArea(edges: .bottom)
        .transition(.opacity)
    }

    private func actionRow(_ shown: PlayerButtons) -> some View {
        let at = buttonCursor.settled(in: shown)
        return PlayerActionRow(items: shown.row.map { (icon($0), label($0)) }, selected: at.line == .row ? at.index : nil)
    }

    /// A button on the bar, white while the remote is on it.
    private func barPill(_ item: PlayerButton, _ shown: PlayerButtons) -> some View {
        PlayerBarPill(icon: icon(item), label: label(item),
                      selected: buttonCursor.settled(in: shown).line == .bar && buttonCursor.current(in: shown) == item)
    }

    private func icon(_ item: PlayerButton) -> String {
        switch item {
        case .favourite: return favourite ? "heart.fill" : "heart"
        case .playPause: return paused ? "play.fill" : "pause.fill"
        default: return PlayerButtonText.icon(item)
        }
    }

    private func label(_ item: PlayerButton) -> String {
        switch item {
        case .favourite: return favourite ? "Unfavourite" : "Favourite"
        case .playPause: return paused ? "Play" : "Pause"
        default: return PlayerButtonText.label(item)
        }
    }

    // MARK: Audio & subtitles panel

    private var tracksPanel: some View {
        VStack(alignment: .leading, spacing: PigSpacing.l) {
            Text("Audio & subtitles").font(.system(size: PigType.sectionTitle, weight: .bold))
            if !playback.audioTracks.isEmpty {
                trackSection("Audio", tracks: playback.audioTracks)
            }
            if !playback.subtitleTracks.isEmpty {
                trackSection("Subtitles", tracks: playback.subtitleTracks)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(PigSpacing.xl)
        .background(RoundedRectangle(cornerRadius: PigRadius.hero).fill(panelFill))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, PigSpacing.tvSafeSide)
        .transition(.opacity)
    }

    private func trackSection(_ title: String, tracks: [PlaybackModel.MediaTrack]) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            Text(title.uppercased()).font(.system(size: PigType.caption, weight: .bold)).foregroundStyle(Color.pigMediaAccent)
            ForEach(tracks) { track in
                let highlighted = allTracks.indices.contains(trackCursor) && allTracks[trackCursor].id == track.id
                HStack(spacing: PigSpacing.m) {
                    Image(systemName: track.selected ? "circle.inset.filled" : "circle")
                        .foregroundStyle(track.selected ? Color.pigMediaAccent : Color.white.opacity(0.5))
                    Text(track.name).font(.system(size: PigType.body, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
                .background(highlighted ? Color.pigMediaAccent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: PigRadius.compact))
                .overlay { RoundedRectangle(cornerRadius: PigRadius.compact).stroke(highlighted ? Color.pigMediaAccent : .clear, lineWidth: 3) }
            }
        }
    }

    /// Programme bar (about three quarters) plus the next programme's slot, as in the reference layout. #58: Start over
    /// at the programme bar's start, Go to live at its end (before the next programme's slot).
    private func timeline(programme: GuideProgramme?, next: GuideProgramme?, now: Date, shown: PlayerButtons) -> some View {
        let programmeProgress = programme.map { PlayerTimeMath.fraction(of: now, from: $0.start, to: $0.end) } ?? 0
        // At the live edge the bar tracks programme progress; once rewound it
        // becomes a scrubber (pink) with a draggable-looking knob at the
        // position in the buffer.
        let scrubbing = playback.behindLive
        let progress = !scrubbing ? programmeProgress : (playback.bufferPosition() ?? programmeProgress)
        // With a button on the bar its line is a pill's height, and the next programme's slot keeps level with it.
        let line: CGFloat? = shown.bar.isEmpty ? nil : 60
        return HStack(alignment: .top, spacing: PigSpacing.m) {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                HStack(spacing: PigSpacing.m) {
                    if shown.bar.contains(.startOver) { barPill(.startOver, shown) }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(scrubbing ? Color.pigMediaAccent : Color.white).frame(width: geometry.size.width * progress)
                            if scrubbing {
                                Circle().fill(Color.white).frame(width: 22, height: 22)
                                    .offset(x: min(geometry.size.width - 22, max(0, geometry.size.width * progress - 11)))
                            }
                        }
                    }.frame(height: 10)
                    if shown.bar.contains(.goLive) { barPill(.goLive, shown) }
                }
                .frame(height: line)
                HStack {
                    Text(programme?.start.formatted(date: .omitted, time: .shortened) ?? "").pigFigures()
                    Spacer()
                    HStack(spacing: PigSpacing.xs) {
                        if !paused && !playback.behindLive { Circle().fill(Color.pigMediaAccent).frame(width: 12, height: 12) }
                        Text(paused || playback.behindLive ? "BEHIND LIVE" : "LIVE").foregroundStyle(paused || playback.behindLive ? Color.white : Color.pigMediaAccent)
                        Text(now.formatted(date: .omitted, time: .shortened)).pigFigures()
                    }
                }.font(.system(size: PigType.body, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 10).frame(height: line)
                Text(next.map { "\($0.start.formatted(date: .omitted, time: .shortened)) · \($0.title)" } ?? "")
                    .font(.system(size: PigType.body, weight: .semibold)).lineLimit(1)
            }
            .frame(width: 420)
        }
    }

    // MARK: Scrub bar (R17)

    // Channel, direction and the buffer position only — nothing that competes
    // with the picture while seeking.
    private func scrubBar(now: Date) -> some View {
        let position = playback.bufferPosition()
        let behind = playback.secondsBehindLive() ?? 0
        let live = behind <= 20
        return VStack(alignment: .leading, spacing: PigSpacing.m) {
            HStack(spacing: PigSpacing.m) {
                Image(systemName: seekForward ? "goforward.15" : "gobackward.15")
                    .font(.system(size: PigType.display, weight: .semibold))
                Text(playback.channel.name).font(.system(size: PigType.cardTitle, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer()
                if live {
                    HStack(spacing: PigSpacing.xs) {
                        Circle().fill(Color.pigMediaAccent).frame(width: 12, height: 12)
                        Text("LIVE").foregroundStyle(Color.pigMediaAccent)
                    }
                } else {
                    Text("\(PlayerTimeMath.behindText(behind)) behind live").pigFigures()
                }
                Text(now.formatted(date: .omitted, time: .shortened)).pigFigures()
            }
            .font(.system(size: PigType.body, weight: .semibold))
            PlayerScrubTrack(fraction: position ?? 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PigSpacing.tvSafeSide).padding(.bottom, PigSpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .playerBottomShade(height: 260, opacity: 0.82)
        .transition(.opacity)
    }

    // MARK: Channel list

    private func channelList(now: Date) -> some View {
        HStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: PigSpacing.xs) {
                        if gamesMode, let browse {
                            // #348: the game's own channels first (best first, the one playing marked).
                            let gameChannels = self.gameChannels
                            if !gameChannels.isEmpty {
                                PlayerListSubheader(text: PlayerGames.gameChannelsHeader)
                                ForEach(Array(gameChannels.enumerated()), id: \.element.id) { index, channel in
                                    channelRow(channel, highlighted: index == cursor, now: now).id(index)
                                }
                                PlayerListSubheader(text: PlayerGames.header)
                            }
                            // #334: the live games, on the channel rows' panels.
                            PlayerGamesReader(front: browse.sportFront, preferences: browse.f1Page) { games in
                                let playing = playingGame(in: games)
                                let first = gameChannels.count
                                ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                                    PlayerGameRow(game: game, client: browse.client, highlighted: first + index == cursor,
                                                  playing: index == playing).id(first + index)
                                }
                            }
                        } else {
                            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                                channelRow(channel, highlighted: index == cursor, now: now).id(index)
                            }
                        }
                    }
                    .padding(.vertical, Self.channelListOverscroll)
                    .padding(.trailing, PlayerRowPanel.trailingRoom(listWidth: Self.channelListWidth))
                }
                .scrollDisabled(true)
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(cursor, anchor: .center) }
                .onChange(of: cursor) { _, value in
                    pigWithAnimation(moves: true, momentum: true, reduceMotion: reduceMotion) { proxy.scrollTo(value, anchor: .center) }
                }
            }
            .frame(width: Self.channelListWidth)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.leading, PigSpacing.section)
            .background(alignment: .leading) {
                LinearGradient(colors: [Color.pigMediaCanvas.opacity(reduceTransparency ? 0.95 : 0.82), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 900).ignoresSafeArea()
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .pigSlide(from: .leading)
    }

    private func channelRow(_ channel: Channel, highlighted: Bool, now: Date) -> some View {
        // Build 29: the row is shared with the iOS channel panel.
        PlayerChannelRow(channel: channel, browse: browse, highlighted: highlighted,
                         playing: channel.id == playback.channel.id, now: now)
    }
}

// A4.2 (Labs → Stream info overlay): codec, size and frame rate, bitrates,
// dropped frames, stalls, the server's route and build, refreshed every
// second while the info overlay is up (the task ends when it hides).
private struct StreamInfoLine: View {
    @ObservedObject var playback: PlaybackModel
    @State private var stats: StreamStats?
    var body: some View {
        Text(stats?.line ?? " ")
            .font(.system(size: PigType.caption, weight: .medium)).pigFigures()
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1).pigMinimumScale(0.7, size: PigType.caption)
            .frame(maxWidth: 1100, alignment: .leading)
            .accessibilityIdentifier("player.streamInfo")
            .task {
                while !Task.isCancelled {
                    stats = await playback.streamStats()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

// Parts shared by the live player and the recording player (A4.3).
#endif
