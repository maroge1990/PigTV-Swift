import SwiftUI
import AVKit

#if os(iOS)
/// The recording player on iPhone and iPad: the picture (an AVPlayerLayer view,
/// so Picture in Picture can be started from here) and PigTV's controls over it:
/// the single close button, play/pause with ±15 s, the scrubber, Picture in
/// Picture and, whenever the playhead is inside a detected break, Skip break.
/// A tap on the picture shows or hides the controls (`PlayerChromeTimer`);
/// Skip break is outside that and stays up for the whole break.
/// #335: a recording still being made, played more than 30 s short of its live point, offers Go to live (red, last in
/// the top bar, set apart); for 8 s after the jump "Back to …" sits where Skip break does.
struct RecordingTouchPlayer: View {
    @ObservedObject var model: RecordingPlayerModel
    let close: () -> Void
    @StateObject private var pip = PiPHandle()
    @State private var chromeVisible = true
    @State private var lastInput = Date()
    @State private var dragFraction: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            NativePlayer(player: model.player, pip: pip, onClosed: close).ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    chromeVisible = PlayerChromeTimer.afterTap(visible: chromeVisible)
                    lastInput = Date()
                }
                .accessibilityLabel("Video")
                .accessibilityHint("Shows or hides the player controls")
            if chromeVisible { chrome.transition(.opacity) }
            if model.inBreak != nil || model.goLiveUndo != nil {
                VStack(alignment: .trailing, spacing: PigSpacing.s) {
                    Spacer()
                    if let undo = model.goLiveUndo { undoNotice(undo) }
                    if model.inBreak != nil {
                        Button { lastInput = Date(); model.skipBreak() } label: {
                            Label("Skip break", systemImage: "forward.end.fill")
                                .font(.headline).padding(.horizontal, PigSpacing.l).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(Color.pigAccent)
                        .foregroundStyle(Color.pigOnAccent)
                        .accessibilityIdentifier("recording.skipBreak")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                // Above the scrub panel when it is showing.
                .padding(.bottom, chromeVisible ? PigSpacing.empty : PigSpacing.xl)
                .padding(.horizontal, PigSpacing.xl)
                .transition(.opacity)
            }
        }
        .pigAnimation(value: chromeVisible)
        .pigAnimation(value: model.inBreak != nil)
        .pigAnimation(value: model.goLiveUndo)
        .task(id: lastInput) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !UIAccessibility.isVoiceOverRunning,
                   PlayerChromeTimer.shouldHide(visible: chromeVisible, lastInput: lastInput, now: Date(),
                                                paused: model.paused, panelOpen: false) {
                    chromeVisible = false
                }
            }
        }
    }

    private var chrome: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let timeline = model.timeline()
            VStack(spacing: 0) {
                HStack(spacing: PigSpacing.m) {
                    PlayerCircleButton(icon: "xmark", label: "Close player", size: 44, action: close)
                        .accessibilityIdentifier("recording.close")
                    Text(model.recording.title).font(.headline).lineLimit(1)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    Spacer(minLength: 8)
                    if pip.supported {
                        PlayerCircleButton(icon: "pip.enter", label: "Picture in Picture", size: 44) {
                            lastInput = Date(); pip.start()
                        }
                        .accessibilityIdentifier("recording.pip")
                    }
                    if model.canGoLive { goLiveButton.padding(.leading, PigSpacing.l) } // #335: last, set apart
                }
                Spacer(minLength: 8)
                HStack(spacing: PigSpacing.section) {
                    PlayerCircleButton(icon: "gobackward.15", label: "Back 15 seconds", size: 56) {
                        lastInput = Date(); model.skip(-15)
                    }
                    PlayerCircleButton(icon: model.paused ? "play.fill" : "pause.fill",
                                       label: model.paused ? "Play" : "Pause", size: 68) {
                        lastInput = Date(); model.togglePause()
                    }
                    .accessibilityIdentifier("recording.playPause")
                    PlayerCircleButton(icon: "goforward.15", label: "Forward 15 seconds", size: 56) {
                        lastInput = Date(); model.skip(15)
                    }
                }
                Spacer(minLength: 8)
                scrubPanel(timeline)
            }
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// #335: Go to live, red (it leaves where the viewer is; Back to undoes it for 8 s).
    private var goLiveButton: some View {
        Button { lastInput = Date(); model.goLive() } label: {
            Label(RecordingGoLive.label, systemImage: RecordingGoLive.icon)
                .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, PigSpacing.l).frame(minHeight: 44)
                .background(Capsule().fill(Color.pigDanger))
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recording.goLive")
    }

    /// #335: "Jumped to live" and the way back to exactly where the viewer was, for 8 s.
    private func undoNotice(_ undo: RecordingGoLive.Undo) -> some View {
        HStack(spacing: PigSpacing.m) {
            Text(RecordingGoLive.notice).font(.subheadline.weight(.semibold))
            Button { lastInput = Date(); model.undoGoLive() } label: {
                Label(RecordingGoLive.backLabel(undo), systemImage: "arrow.uturn.backward")
                    .font(.headline).pigFigures().padding(.horizontal, PigSpacing.l).frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(Color.pigAccent)
            .foregroundStyle(Color.pigOnAccent)
            .accessibilityIdentifier("recording.goLiveUndo")
        }
        .padding(.leading, PigSpacing.l)
        .background(Color.pigMediaPanel, in: Capsule())
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func scrubPanel(_ timeline: RecordingTimeline?) -> some View {
        if let timeline {
            let fraction = dragFraction ?? timeline.fraction
            HStack(spacing: PigSpacing.m) {
                Text(RecordingTimeline.clock(timeline.end * fraction))
                    .font(.footnote.weight(.semibold)).pigFigures()
                    .frame(minWidth: 56, alignment: .leading)
                TouchScrubBar(fraction: fraction, changed: { value in
                    dragFraction = value; lastInput = Date()
                }, ended: { value in
                    model.seek(toFraction: value); dragFraction = nil; lastInput = Date()
                }, skip: { seconds in lastInput = Date(); model.skip(seconds) })
                .accessibilityLabel("Position")
                .accessibilityValue("\(RecordingTimeline.clock(timeline.end * fraction)) of \(RecordingTimeline.clock(timeline.end))")
                Text("−" + RecordingTimeline.clock(timeline.end * (1 - fraction)))
                    .font(.footnote.weight(.semibold)).pigFigures()
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .padding(PigSpacing.m)
            .background(reduceTransparency ? AnyShapeStyle(Color.pigMediaSolidPanel) : AnyShapeStyle(Color.pigMediaPanel),
                        in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        }
    }
}
#endif
