#if os(tvOS)
import SwiftUI
import AVFoundation

// A4.3: recordings play in a player built from the live player's parts
// (PlayerLayerView, PlayerActionRow, PlayerScrubTrack, BlankButtonStyle),
// replacing AVPlayerViewController, so the TV has one player. The model
// (lifecycle, resume, break markers) is RecordingPlayerModel.
//
// Remote map
//   Controls hidden:  Left/Right → back/forward 15 s (scrub bar)
//                     Select → Back to (8 s after Go to live), else Skip
//                     break while in a break, else info
//                     Up/Down → info · Play/Pause → pause/resume · Back → close
//   Scrub bar:        Left/Right → keep seeking · Select → info
//                     Up/Down/Back → hide
//   Info shown:       two lines of buttons (#58 option B, `PlayerButtons`, `PlayerCursor`): the row (Pause, Auto-skip
//                     breaks) and the progress bar (Skip break, then Go to live, at its end). It opens on the row's first
//                     button. Left/Right → choose in the line · Select → run it · Down → the bar (its right end) when
//                     it has a button · Up → back to the row · Up from the row, Down from the bar (or from the row with
//                     nothing on the bar), Back → hide
//                     #335: Go to live, red, while a recording still being made plays more than 30 s short of its live point
// Overlays hide themselves after a few idle seconds (not while paused).

private enum RecordingChrome: Equatable { case hidden, scrub, info }

struct RecordingPlayerView: View {
    @ObservedObject var model: RecordingPlayerModel
    let close: () -> Void
    @State private var chrome: RecordingChrome = .info
    /// Where the remote is in the row and on the bar (#58).
    @State private var cursor = PlayerCursor()
    @State private var lastInput = Date()
    @State private var seekForward = false
    @FocusState private var focused: Bool

    /// #58 option B: Pause and Auto-skip breaks in the row; Skip break and Go to live (#335: red, never the first
    /// selection) at the bar's end.
    private var buttons: PlayerButtons {
        PlayerButtons.recording(inBreak: model.inBreak != nil, hasBreaks: !model.breaks.isEmpty, canGoLive: model.canGoLive)
    }

    var body: some View {
        Button(action: select) {
            ZStack {
                PlayerLayerView(player: model.player, criteria: model.displayCriteria).ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        // #335: for 8 s after Go to live the way back takes the pill's place (and Select).
                        if chrome == .hidden, let undo = model.goLiveUndo { undoPill(undo) }
                        else if chrome == .hidden, model.inBreak != nil { skipBreakPill }
                        if chrome != .hidden { overlay(timeline: model.timeline()) }
                    }
                    .onChange(of: context.date) { _, now in
                        settle() // Go to live comes and goes with the playhead (no publish of its own)
                        autoHide(now)
                    }
                }
                .pigAnimation(value: chrome)
            }
        }
        .buttonStyle(BlankButtonStyle())
        #if DEBUG
        .accessibilityIdentifier("review.recordingPlayer")
        .accessibilityValue("\(chrome); \(PlayerCursor.describe(cursor, buttons)); paused=\(model.paused); autoSkip=\(model.autoSkip); break=\(model.inBreak?.id ?? -1)")
        #endif
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .focused($focused)
        .onAppear { focused = true; cursor.open(in: buttons) }
        .onMoveCommand(perform: move)
        .onPlayPauseCommand {
            touch()
            model.togglePause()
            showInfo()
        }
        .onExitCommand(perform: back)
        .onChange(of: model.inBreak?.id) { _, id in
            // Entering a break with the info shown: Skip break, on the bar, is selected.
            if id != nil, chrome == .info { cursor.select(.skipBreak, in: buttons) } else { settle() }
        }
    }

    // MARK: Remote

    private func touch() { lastInput = Date() }

    /// The info opens on the row's first button; already open, it stays where it is.
    private func showInfo() {
        if chrome != .info { cursor.open(in: buttons) }
        chrome = .info
    }

    private func settle() {
        let settled = cursor.settled(in: buttons)
        if settled != cursor { cursor = settled }
    }

    private func move(_ direction: MoveCommandDirection) {
        touch()
        switch (chrome, direction) {
        case (.hidden, .left), (.scrub, .left): seek(-15)
        case (.hidden, .right), (.scrub, .right): seek(15)
        case (.hidden, _): showInfo()
        case (.scrub, _): chrome = .hidden
        case (.info, _):
            guard let move = PlayerCursor.Move(direction) else { return }
            if !cursor.move(move, in: buttons) { chrome = .hidden }
        }
    }

    private func seek(_ seconds: Double) {
        seekForward = seconds > 0
        model.skip(seconds)
        chrome = .scrub
    }

    private func select() {
        touch()
        switch chrome {
        case .hidden:
            if model.goLiveUndo != nil { model.undoGoLive() }
            else if model.inBreak != nil { model.skipBreak() } else { showInfo() }
        case .scrub:
            showInfo()
        case .info:
            guard let item = cursor.current(in: buttons) else { return }
            run(item)
        }
    }

    private func back() {
        touch()
        if chrome == .hidden { close() } else { chrome = .hidden }
    }

    private func run(_ item: PlayerButton) {
        switch item {
        case .skipBreak:
            model.skipBreak()
            settle() // the nearest button left on the bar, else back to the row
        case .playPause: model.togglePause()
        case .autoSkip: model.autoSkip.toggle()
        case .goLive:
            model.goLive()
            chrome = .hidden
        case .startOver, .tracks, .favourite, .record, .lastChannel, .syncMarker:
            break // not a recording's
        }
    }

    private func autoHide(_ now: Date) {
        let limit: TimeInterval = chrome == .scrub ? 4 : 6
        if chrome != .hidden, !model.paused, now.timeIntervalSince(lastInput) > limit { chrome = .hidden }
    }

    private func icon(_ item: PlayerButton) -> String {
        switch item {
        case .playPause: return model.paused ? "play.fill" : "pause.fill"
        case .autoSkip: return PlayerButtonText.autoSkipIcon(on: model.autoSkip)
        case .goLive: return RecordingGoLive.icon
        default: return PlayerButtonText.icon(item)
        }
    }

    private func label(_ item: PlayerButton) -> String {
        switch item {
        case .playPause: return model.paused ? "Play" : "Pause"
        case .autoSkip: return PlayerButtonText.autoSkip(on: model.autoSkip)
        case .goLive: return RecordingGoLive.label
        default: return PlayerButtonText.label(item)
        }
    }

    // MARK: Chrome

    /// Like the system's Skip Intro: Select skips while it is shown.
    private var skipBreakPill: some View {
        Label("Skip break", systemImage: "forward.end.fill")
            .font(.system(size: PigType.cardTitle, weight: .semibold))
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            .background(Color.white, in: Capsule())
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, PigSpacing.tvSafeSide).padding(.bottom, PigSpacing.empty)
            .transition(.opacity)
    }

    /// #335: "Jumped to live" and the way back, in the Skip break pill's place; Select takes it for its 8 s.
    private func undoPill(_ undo: RecordingGoLive.Undo) -> some View {
        HStack(spacing: PigSpacing.m) {
            Text(RecordingGoLive.notice).font(.system(size: PigType.cardTitle, weight: .semibold))
            Label(RecordingGoLive.backLabel(undo), systemImage: "arrow.uturn.backward")
                .font(.system(size: PigType.cardTitle, weight: .semibold)).pigFigures()
                .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
                .background(Color.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.leading, PigSpacing.l)
        .background(Color.pigMediaPanel, in: Capsule())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, PigSpacing.tvSafeSide).padding(.bottom, PigSpacing.empty)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording.goLiveUndo")
    }

    /// #58: Skip break, then Go to live (red), at the bar's end.
    private var barButtons: some View {
        let shown = buttons
        let at = cursor.settled(in: shown)
        return ForEach(Array(shown.bar.enumerated()), id: \.element) { index, item in
            PlayerBarPill(icon: icon(item), label: label(item), selected: at.line == .bar && at.index == index,
                          destructive: item == .goLive)
        }
    }

    private func overlay(timeline: RecordingTimeline?) -> some View {
        let recording = model.recording
        return VStack(alignment: .leading, spacing: PigSpacing.m) {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    HStack(spacing: PigSpacing.s) {
                        Text(recording.channel_name ?? "Recording")
                        if let date = recording.started {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).pigFigures()
                        }
                    }
                    .font(.system(size: PigType.cardTitle, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(recording.title).font(.system(size: chrome == .info ? PigType.hero : PigType.sectionTitle, weight: .bold)).lineLimit(2)
                }
                Spacer()
                if chrome == .info {
                    let at = cursor.settled(in: buttons)
                    PlayerActionRow(items: buttons.row.map { (icon($0), label($0)) }, selected: at.line == .row ? at.index : nil)
                } else {
                    Image(systemName: seekForward ? "goforward.15" : "gobackward.15")
                        .font(.system(size: PigType.display, weight: .semibold))
                }
            }
            HStack(spacing: PigSpacing.m) {
                PlayerScrubTrack(fraction: timeline?.fraction ?? 0)
                if chrome == .info { barButtons }
            }
            HStack {
                Text(RecordingTimeline.clock(timeline?.elapsed ?? 0))
                Spacer()
                if let timeline {
                    Text("−\(RecordingTimeline.clock(timeline.remaining))")
                }
            }
            .font(.system(size: PigType.body, weight: .semibold)).pigFigures()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PigSpacing.tvSafeSide).padding(.bottom, PigSpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .playerBottomShade(height: chrome == .info ? 520 : 300, opacity: 0.82)
        .transition(.opacity)
    }
}
#endif
