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
//                     Select → Skip break while in a break, else info
//                     Up/Down → info · Play/Pause → pause/resume · Back → close
//   Scrub bar:        Left/Right → keep seeking · Select → info
//                     Up/Down/Back → hide
//   Info shown:       Left/Right → choose action · Select → run action
//                     Up/Down/Back → hide
// Overlays hide themselves after a few idle seconds (not while paused).

private enum RecordingChrome: Equatable { case hidden, scrub, info }

private enum RecordingAction: Equatable { case skipBreak, playPause, autoSkip }

struct RecordingPlayerView: View {
    @ObservedObject var model: RecordingPlayerModel
    let close: () -> Void
    @State private var chrome: RecordingChrome = .info
    @State private var action = 0
    @State private var lastInput = Date()
    @State private var seekForward = false
    @FocusState private var focused: Bool

    private var actions: [RecordingAction] {
        var list: [RecordingAction] = []
        if model.inBreak != nil { list.append(.skipBreak) }
        list.append(.playPause)
        // Only offered when the recording has detected breaks (no dead UI).
        if !model.breaks.isEmpty { list.append(.autoSkip) }
        return list
    }

    var body: some View {
        Button(action: select) {
            ZStack {
                PlayerLayerView(player: model.player, criteria: model.displayCriteria).ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        if chrome == .hidden, model.inBreak != nil { skipBreakPill }
                        if chrome != .hidden { overlay(timeline: model.timeline()) }
                    }
                    .onChange(of: context.date) { _, now in autoHide(now) }
                }
                .animation(.easeInOut(duration: 0.16), value: chrome)
            }
        }
        .buttonStyle(BlankButtonStyle())
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
            if model.inBreak != nil { model.skipBreak() } else { action = 0; chrome = .info }
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
        case .autoSkip: return model.autoSkip ? "checkmark.circle.fill" : "circle"
        }
    }

    private func label(_ item: RecordingAction) -> String {
        switch item {
        case .skipBreak: return "Skip break"
        case .playPause: return model.paused ? "Play" : "Pause"
        case .autoSkip: return model.autoSkip ? "Auto-skip breaks: On" : "Auto-skip breaks: Off"
        }
    }

    // MARK: Chrome

    /// Like the system's Skip Intro: Select skips while it is shown.
    private var skipBreakPill: some View {
        Label("Skip break", systemImage: "forward.end.fill")
            .font(.system(size: 26, weight: .semibold))
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(Color.white, in: Capsule())
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 90).padding(.bottom, 80)
            .transition(.opacity)
    }

    private func overlay(timeline: RecordingTimeline?) -> some View {
        let recording = model.recording
        return VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(recording.channel_name ?? "Recording")
                        if let date = recording.started {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(recording.title).font(.system(size: chrome == .info ? 56 : 34, weight: .bold)).lineLimit(2)
                }
                Spacer()
                if chrome == .info {
                    PlayerActionRow(items: actions.map { (icon($0), label($0)) }, selected: action)
                } else {
                    Image(systemName: seekForward ? "goforward.15" : "gobackward.15")
                        .font(.system(size: 40, weight: .semibold))
                }
            }
            PlayerScrubTrack(fraction: timeline?.fraction ?? 0)
            HStack {
                Text(RecordingTimeline.clock(timeline?.elapsed ?? 0))
                Spacer()
                if timeline?.atLiveEdge == true {
                    // A growing (EVENT) recording, watched at its newest part.
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                        Text("LIVE").foregroundStyle(.red)
                    }
                } else if let timeline {
                    Text("−\(RecordingTimeline.clock(timeline.remaining))\(model.inProgress ? "  ·  still recording" : "")")
                }
            }
            .font(.system(size: 24, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 90).padding(.bottom, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .playerBottomShade(height: chrome == .info ? 520 : 300, opacity: 0.8)
        .transition(.opacity)
    }
}
#endif
