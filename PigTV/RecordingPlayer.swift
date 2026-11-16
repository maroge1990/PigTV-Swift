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
//   Info shown:       Left/Right → choose action · Select → run action
//                     Up/Down/Back → hide
//                     #335: Go to live, last and red, while a recording still
//                     being made plays more than 30 s short of its live point
// Overlays hide themselves after a few idle seconds (not while paused).

private enum RecordingChrome: Equatable { case hidden, scrub, info }

private typealias RecordingAction = RecordingActions.Item

struct RecordingPlayerView: View {
    @ObservedObject var model: RecordingPlayerModel
    let close: () -> Void
    @State private var chrome: RecordingChrome = .info
    @State private var action = 0
    @State private var lastInput = Date()
    @State private var seekForward = false
    @FocusState private var focused: Bool

    private var actions: [RecordingAction] {
        // #335: Go to live is always last (never the first focus) and never a pill of its own.
        RecordingActions.list(inBreak: model.inBreak != nil, hasBreaks: !model.breaks.isEmpty, canGoLive: model.canGoLive)
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
                    .onChange(of: context.date) { _, now in autoHide(now) }
                }
                .pigAnimation(value: chrome)
            }
        }
        .buttonStyle(BlankButtonStyle())
        #if DEBUG
        .accessibilityIdentifier("review.recordingPlayer")
        .accessibilityValue("\(chrome); action=\(action); paused=\(model.paused); autoSkip=\(model.autoSkip); break=\(model.inBreak?.id ?? -1)")
        #endif
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .focused($focused)
        .onAppear { focused = true }
        .onMoveCommand(perform: move)
        .onPlayPauseCommand { touch(); model.togglePause(); chrome = .info }
        .onExitCommand(perform: back)
        .onChange(of: model.inBreak?.id) { _, id in
            // Entering a break with the info shown: preselect Skip break.
            if id != nil, chrome == .info { action = 0 }
            else { action = min(action, actions.count - 1) }
        }
    }

    // MARK: Remote

    private func touch() { lastInput = Date() }

    private func move(_ direction: MoveCommandDirection) {
        touch()
        switch (chrome, direction) {
        case (.hidden, .left), (.scrub, .left): seek(-15)
        case (.hidden, .right), (.scrub, .right): seek(15)
        case (.hidden, _): action = 0; chrome = .info
        case (.scrub, _): chrome = .hidden
        case (.info, .left): action = max(0, action - 1)
        case (.info, .right): action = min(actions.count - 1, action + 1)
        case (.info, _): chrome = .hidden
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
            else if model.inBreak != nil { model.skipBreak() } else { action = 0; chrome = .info }
        case .scrub:
            action = 0
            chrome = .info
        case .info:
            guard actions.indices.contains(action) else { return }
            run(actions[action])
        }
    }

    private func back() {
        touch()
        if chrome == .hidden { close() } else { chrome = .hidden }
    }

    private func run(_ item: RecordingAction) {
        switch item {
        case .skipBreak: model.skipBreak(); action = 0
        case .playPause: model.togglePause()
        case .autoSkip: model.autoSkip.toggle()
        case .goLive:
            model.goLive()
            action = 0
            chrome = .hidden
        }
    }

    private func autoHide(_ now: Date) {
        let limit: TimeInterval = chrome == .scrub ? 4 : 6
        if chrome != .hidden, !model.paused, now.timeIntervalSince(lastInput) > limit { chrome = .hidden }
    }

    private func icon(_ item: RecordingAction) -> String {
        switch item {
        case .skipBreak: return "forward.end.fill"
        case .playPause: return model.paused ? "play.fill" : "pause.fill"
        case .autoSkip: return model.autoSkip ? "circle.inset.filled" : "circle"
        case .goLive: return RecordingGoLive.icon
        }
    }

    private func label(_ item: RecordingAction) -> String {
        switch item {
        case .skipBreak: return "Skip break"
        case .playPause: return model.paused ? "Play" : "Pause"
        case .autoSkip: return model.autoSkip ? "Auto-skip breaks: On" : "Auto-skip breaks: Off"
        case .goLive: return RecordingGoLive.label
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
                    PlayerActionRow(items: actions.map { (icon($0), label($0)) }, selected: action,
                                    destructive: actions.firstIndex(of: .goLive))
                } else {
                    Image(systemName: seekForward ? "goforward.15" : "gobackward.15")
                        .font(.system(size: PigType.display, weight: .semibold))
                }
            }
            PlayerScrubTrack(fraction: timeline?.fraction ?? 0)
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
