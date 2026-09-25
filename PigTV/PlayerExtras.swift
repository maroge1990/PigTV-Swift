#if os(iOS)
import SwiftUI
import AVFoundation

// The iPhone/iPad player's own chrome. Build 29 matched the TV (Mark, on
// iPad: no "Tuning…", and the old channel sheet). Build 31 (Mark: "clashing
// between the new player and avkit, there are controls for both on screen …
// the new player controls are a bit small"): AVKit's controls are off
// (`showsPlaybackControls = false`) and PigTV's are the only ones:
// - `TouchPlayerChrome`: top bar (Close, channel, **Channels**, **TV Guide**),
//   centre transport (−15 s, play/pause, +15 s), and one bottom panel with
//   the programme, a draggable scrub bar over the seekable/timeshift window
//   (`PlayerSeekWindow`), Go to live, and the actions (Favourite, Record,
//   Last channel, channel down/up, Go to number). All targets ≥ 44 pt, white
//   glyphs on dark translucent circles and pills.
// - `PlayerChannelPanel`: the TV's side channel list, as a translucent side
//   panel on iPad (regular width) or a bottom sheet on iPhone, opened from
//   Channels; tap a row to switch (switchPlayback, which releases the old
//   stream first). TV Guide closes the player and opens the Guide tab.

/// The channel list: current channel highlighted and scrolled to.
struct PlayerChannelPanel: View {
    @ObservedObject var app: AppModel
    let close: () -> Void

    var body: some View {
        let current = app.playback?.channel.id
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(app.playerChannels) { channel in
                            let playing = channel.id == current
                            Button {
                                if !playing { app.switchPlayback(to: channel) }
                                close()
                            } label: {
                                PlayerChannelRow(channel: channel, browse: app.browse, highlighted: playing,
                                                 playing: playing, now: context.date)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlayerRowPressStyle())
                            .id(channel.id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// iPad: the panel slides in from the leading edge over the picture (like
/// the TV's), with a header and close button; a tap beside it closes it.
struct PlayerSidePanel: View {
    @ObservedObject var app: AppModel
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.2).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Channels").font(.title2.bold())
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .accessibilityLabel("Close channels")
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                PlayerChannelPanel(app: app, close: close)
            }
            .foregroundStyle(.white)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background {
                if reduceTransparency { Color(white: 0.08).ignoresSafeArea() }
                else {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    }
                    .ignoresSafeArea()
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

private struct PlayerRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Build 31: the touch player's controls, shown and hidden together (a tap
/// on the picture toggles them; `PlayerChromeTimer` hides them after 4 idle
/// seconds unless paused). Always dark: it sits over video.
struct TouchPlayerChrome: View {
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    let close: () -> Void
    /// Closes the player and shows the TV Guide tab.
    let openGuide: () -> Void
    let openChannels: () -> Void
    let enterNumber: () -> Void
    /// Any interaction (keeps the controls up).
    let touch: () -> Void
    /// While the scrub bar is being dragged: where the finger is.
    @State private var dragFraction: Double?
    @State private var busy = false
    @State private var notice: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// iPad (both size classes regular): labels everywhere, bigger type.
    private var regular: Bool { sizeClass == .regular && verticalSizeClass == .regular }
    /// iPhone in landscape: little height, so the bottom panel drops a line.
    private var short: Bool { verticalSizeClass == .compact }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let window = playback.seekWindow()
            let paused = playback.player.timeControlStatus == .paused
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                transport(window: window, paused: paused)
                Spacer(minLength: 8)
                bottomPanel(now: context.date, window: window)
            }
            .padding(.horizontal, regular ? 28 : 16)
            .padding(.top, regular ? 16 : 8)
            .padding(.bottom, regular ? 20 : 8)
        }
        .foregroundStyle(.white)
        .background { shades.allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            notice = nil
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                PlayerCircleButton(icon: "xmark", label: "Close player", size: 44, action: close)
                if regular || short { channelTitle }
                Spacer(minLength: 8)
                PlayerPillButton(title: "Channels", icon: "list.bullet.rectangle", prominent: true) {
                    touch(); openChannels()
                }
                .accessibilityIdentifier("player.channels")
                PlayerPillButton(title: "TV Guide", icon: "calendar", prominent: true, action: openGuide)
                    .accessibilityHint("Closes the player and opens the TV Guide")
                    .accessibilityIdentifier("player.guide")
            }
            // iPhone upright: the channel gets its own line under the buttons.
            if !regular && !short { channelTitle.padding(.leading, 4) }
        }
    }

    private var channelTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(playback.channel.name).font(regular ? .title3.weight(.semibold) : .headline).lineLimit(1)
            if let number = playback.channel.numberText {
                ChannelNumberText(number: number, font: regular ? .subheadline : .caption, onDark: true)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    // MARK: Centre transport

    private func transport(window: PlayerSeekWindow?, paused: Bool) -> some View {
        HStack(spacing: regular ? 56 : 36) {
            if window != nil {
                PlayerCircleButton(icon: "gobackward.15", label: "Back 15 seconds", size: regular ? 68 : 56) {
                    touch(); playback.skip(-15)
                }
            }
            PlayerCircleButton(icon: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause",
                               size: regular ? 92 : (short ? 64 : 76)) {
                touch()
                if playback.player.rate == 0 { playback.player.play() } else { playback.player.pause() }
            }
            .accessibilityIdentifier("player.playPause")
            if window != nil {
                PlayerCircleButton(icon: "goforward.15", label: "Forward 15 seconds", size: regular ? 68 : 56) {
                    touch(); playback.skip(15)
                }
            }
        }
    }

    // MARK: Bottom panel

    private func bottomPanel(now: Date, window: PlayerSeekWindow?) -> some View {
        let watching = watchedDate(now: now)
        let programme = playback.programme(at: watching)
        let next = playback.nextProgramme(after: watching)
        return VStack(alignment: .leading, spacing: regular ? 12 : 8) {
            // iPad landscape: the actions beside the programme; otherwise
            // (iPad upright, iPhone) on their own row below it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    programmeInfo(programme: programme, next: next, watching: watching)
                    Spacer(minLength: 12)
                    if regular { actions }
                }
                VStack(alignment: .leading, spacing: regular ? 12 : 8) {
                    programmeInfo(programme: programme, next: next, watching: watching)
                    if regular { ScrollView(.horizontal) { actions }.scrollIndicators(.hidden) }
                }
            }
            scrubRow(now: now, window: window, programme: programme, watching: watching)
            if !regular {
                ScrollView(.horizontal) { actions }.scrollIndicators(.hidden)
            }
            if let notice {
                Text(notice).font(.footnote.weight(.semibold)).foregroundStyle(Color.pigAccent)
                    .transition(.opacity)
            }
        }
        .padding(regular ? 20 : 12)
        .background(reduceTransparency ? AnyShapeStyle(Color(white: 0.08)) : AnyShapeStyle(Color.black.opacity(0.45)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func programmeInfo(programme: GuideProgramme?, next: GuideProgramme?, watching: Date) -> some View {
            HStack(alignment: .center, spacing: 14) {
                LogoTile(logo: browse.logo(for: playback.channel) ?? playback.channel.logo, client: browse.client,
                         name: playback.channel.name)
                    .frame(width: regular ? 112 : 72, height: regular ? 63 : 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(programme?.title ?? "No programme information")
                        .font(regular ? .title2.bold() : .headline).lineLimit(1)
                    if let programme {
                        Text("\(PlayerInfoText.timeRange(programme)) · \(PlayerInfoText.remaining(programme, at: watching))")
                            .font(regular ? .subheadline : .footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    if !short, let next = PlayerInfoText.next(next) {
                        Text(next).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
    }

    @ViewBuilder
    private func scrubRow(now: Date, window: PlayerSeekWindow?, programme: GuideProgramme?, watching: Date) -> some View {
        HStack(spacing: 12) {
            if let window {
                let fraction = dragFraction ?? window.fraction
                let live = window.isLive(at: fraction)
                Text(leftReadout(window: window, fraction: fraction, now: now))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: regular ? 96 : 64, alignment: .leading)
                    .lineLimit(1)
                TouchScrubBar(fraction: fraction, changed: { value in
                    dragFraction = value
                    touch()
                }, ended: { value in
                    playback.seek(toFraction: value)
                    dragFraction = nil
                    touch()
                }, skip: { seconds in touch(); playback.skip(seconds) })
                .accessibilityLabel("Position")
                .accessibilityValue(window.readout(at: fraction))
                liveControl(live: live && dragFraction == nil)
            } else if let programme {
                // No buffer to scrub: the programme's progress, live.
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                PigProgressBar(fraction: PlayerInfoText.progress(programme, at: watching), height: 6)
                liveControl(live: true)
            }
        }
    }

    /// With timeshift: the picture's clock time; otherwise how far behind.
    private func leftReadout(window: PlayerSeekWindow, fraction: Double, now: Date) -> String {
        if window.isLive(at: fraction) { return now.formatted(date: .omitted, time: .shortened) }
        if playback.timeshift {
            return now.addingTimeInterval(-window.behindLive(at: fraction)).formatted(date: .omitted, time: .shortened)
        }
        return "−\(TimeshiftMath.behindText(window.behindLive(at: fraction)))"
    }

    @ViewBuilder
    private func liveControl(live: Bool) -> some View {
        if live {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("LIVE").font(.footnote.bold())
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } else {
            PlayerPillButton(title: "Go to live", icon: "forward.end.fill", compactLabel: true) {
                touch(); playback.goToLive()
            }
            .accessibilityIdentifier("player.goToLive")
        }
    }

    private var actions: some View {
        let favourite = browse.isFavourite(playback.channel)
        return HStack(spacing: 10) {
            PlayerPillButton(title: favourite ? "In favourites" : "Favourite", icon: favourite ? "heart.fill" : "heart",
                             iconOnly: !regular, accessibility: favourite ? "Remove from favourites" : "Add to favourites") {
                touch(); busy = true
                Task {
                    let result = await PlayerCommands.setFavourite(!favourite, channel: playback.channel, browse: browse)
                    busy = false
                    notice = result.notice
                }
            }
            PlayerPillButton(title: "Record", icon: "record.circle", iconOnly: !regular, accessibility: "Record this programme") {
                touch(); busy = true
                Task {
                    notice = await PlayerCommands.recordNow(playback: playback, browse: browse)
                    busy = false
                }
            }
            if let previous = app.previousChannel, previous.id != playback.channel.id {
                PlayerPillButton(title: "Last channel", icon: "arrow.uturn.backward", iconOnly: !regular,
                                 accessibility: "Last channel, \(previous.name)") {
                    touch(); app.returnToPreviousChannel()
                }
            }
            PlayerCircleButton(icon: "chevron.down", label: "Previous channel", size: 44) { touch(); app.zap(-1) }
            PlayerCircleButton(icon: "chevron.up", label: "Next channel", size: 44) { touch(); app.zap(1) }
            if browse.showsChannelNumbers {
                PlayerPillButton(title: "Go to number", icon: "number", iconOnly: !regular, accessibility: "Go to channel number") {
                    touch(); enterNumber()
                }
            }
        }
        .disabled(busy)
    }

    private var shades: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(reduceTransparency ? 0.9 : 0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: regular ? 170 : 130)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(reduceTransparency ? 0.95 : 0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: regular ? 340 : 260)
        }
        .ignoresSafeArea()
    }

    /// With timeshift, once rewound: the picture's time (as the TV).
    private func watchedDate(now: Date) -> Date {
        guard playback.behindLive, let date = playback.playbackDate(), date < now else { return now }
        return date
    }
}

/// A round control: white glyph on a dark translucent circle.
struct PlayerCircleButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }
}

/// A pill control: icon and label (or the icon alone in a 44 pt circle).
struct PlayerPillButton: View {
    let title: String
    let icon: String
    var prominent = false
    var iconOnly = false
    /// Label only on wide screens (the icon stays).
    var compactLabel = false
    var accessibility: String? = nil
    let action: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Button(action: action) {
            Group {
                if iconOnly {
                    Image(systemName: icon).frame(width: 44, height: 44)
                } else {
                    Label(title, systemImage: icon)
                        .labelStyle(compactLabel && sizeClass != .regular ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, prominent ? 18 : 14)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .font(prominent ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .background(Capsule().fill(prominent ? Color.white.opacity(0.2) : Color.black.opacity(0.55)))
            .background(Capsule().fill(.ultraThinMaterial).opacity(prominent ? 1 : 0))
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.45 : 0.22), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(accessibility ?? title)
    }
}

private struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The draggable scrub bar: a 44 pt tall touch area around a 6 pt track.
/// `changed` follows the finger; `ended` seeks. VoiceOver adjusts by 15 s.
struct TouchScrubBar: View {
    let fraction: Double
    let changed: (Double) -> Void
    let ended: (Double) -> Void
    let skip: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knob: CGFloat = 22
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 6)
                Capsule().fill(Color.pigAccent).frame(width: max(0, width * fraction), height: 6)
                Circle().fill(Color.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: min(max(0, width * fraction - knob / 2), max(0, width - knob)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed(PlayerSeekWindow.fraction(forX: $0.location.x, width: width)) }
                .onEnded { ended(PlayerSeekWindow.fraction(forX: $0.location.x, width: width)) })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            skip(direction == .increment ? 15 : -15)
        }
        .accessibilityIdentifier("player.scrub")
    }
}
#endif
