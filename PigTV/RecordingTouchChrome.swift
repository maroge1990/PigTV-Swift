import SwiftUI
import AVKit

#if os(iOS)
/// The recording player on iPhone and iPad: the picture (an AVPlayerLayer view,
/// so Picture in Picture can be started from here) and PigTV's controls over it:
/// the single close button, play/pause with ±15 s, the scrubber, Picture in
/// Picture and, whenever the playhead is inside a detected break, Skip break.
/// A tap on the picture shows or hides the controls (`PlayerChromeTimer`);
/// Skip break stays up for the whole break: at the scrub bar's end with the controls, on its own without them.
/// #58 option B (`PlayerButtons`): Skip break and Go to live at the bar's end, Auto-skip breaks (#369: any recording with
/// breaks found) in the row: above the bar on iPad, below it on iPhone, as the live player's row.
/// #335: a recording still being made, played more than 30 s short of its live point, offers Go to live (red); for 8 s
/// after the jump "Back to …" sits where Skip break does.
struct RecordingTouchPlayer: View {
    @ObservedObject var model: RecordingPlayerModel
    let close: () -> Void
    @StateObject private var pip = PiPHandle()
    @State private var chromeVisible = true
    @State private var lastInput = Date()
    @State private var dragFraction: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPad (both size classes regular), as the live player's: the row above the bar, labels on the bar's buttons.
    private var regular: Bool { sizeClass == .regular && verticalSizeClass == .regular }

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
            // #335: with the controls up, the Back to notice sits in them, above the scrub panel (never over its edge).
            // #58: with the controls up, Skip break is on the bar.
            if !chromeVisible, model.inBreak != nil || model.goLiveUndo != nil {
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
                .padding(.bottom, PigSpacing.xl)
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
                if let undo = model.goLiveUndo {
                    // #335: above the scrub panel, the panel's own spacing apart.
                    undoNotice(undo).frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, PigSpacing.m)
                }
                scrubPanel(timeline)
            }
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// #58: a button on the bar's end: Skip break white (as the Apple TV's), Go to live red (#335: it leaves where the
    /// viewer is; Back to undoes it for 8 s). The iPhone shows the icon alone.
    private func barButton(_ title: String, icon: String, red: Bool, action: @escaping () -> Void) -> some View {
        Button { lastInput = Date(); action() } label: {
            Group {
                if regular {
                    Label(title, systemImage: icon).lineLimit(1).fixedSize().padding(.horizontal, PigSpacing.l)
                } else {
                    Image(systemName: icon).frame(width: 44)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .background(Capsule().fill(red ? Color.pigDanger : Color.white))
            .foregroundStyle(red ? Color.white : Color.black)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// #369: Auto-skip breaks on iPad and iPhone (the model already honours it); "Auto-skip: Off" on the iPhone.
    private var autoSkipButton: some View {
        PlayerPillButton(title: PlayerButtonText.autoSkip(on: model.autoSkip, short: !regular),
                         icon: PlayerButtonText.autoSkipIcon(on: model.autoSkip)) {
            lastInput = Date(); model.autoSkip.toggle()
        }
        .accessibilityIdentifier("recording.autoSkip")
    }

    /// #335: "Jumped to live" and the way back to exactly where the viewer was, for 8 s.
    private func undoNotice(_ undo: RecordingGoLive.Undo) -> some View {
        HStack(spacing: PigSpacing.m) {
            Text(RecordingGoLive.notice).font(.subheadline.weight(.semibold))
            Button { lastInput = Date(); model.undoGoLive() } label: {
                // The Apple TV's white pill (RecordingPlayer.undoPill).
                Label(RecordingGoLive.backLabel(undo), systemImage: "arrow.uturn.backward")
                    .font(.headline).pigFigures().lineLimit(1).fixedSize()
                    .padding(.horizontal, PigSpacing.l).frame(minHeight: 44)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recording.goLiveUndo")
        }
        .padding(.leading, PigSpacing.l)
        .background(Color.pigMediaPanel, in: Capsule())
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func scrubPanel(_ timeline: RecordingTimeline?) -> some View {
        if let timeline {
            let buttons = PlayerButtons.recording(inBreak: model.inBreak != nil, hasBreaks: !model.breaks.isEmpty,
                                                  canGoLive: model.canGoLive, pause: false)
            VStack(alignment: .leading, spacing: regular ? PigSpacing.m : PigSpacing.s) {
                if regular, buttons.row.contains(.autoSkip) { autoSkipButton }
                scrubRow(timeline, buttons: buttons)
                if !regular, buttons.row.contains(.autoSkip) { autoSkipButton }
            }
            .padding(PigSpacing.m)
            .background(reduceTransparency ? AnyShapeStyle(Color.pigMediaSolidPanel) : AnyShapeStyle(Color.pigMediaPanel),
                        in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        }
    }

    private func scrubRow(_ timeline: RecordingTimeline, buttons: PlayerButtons) -> some View {
        let fraction = dragFraction ?? timeline.fraction
        return HStack(spacing: PigSpacing.m) {
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
            if buttons.bar.contains(.skipBreak) {
                barButton(PlayerButtonText.skipBreak, icon: PlayerButtonText.icon(.skipBreak), red: false) { model.skipBreak() }
                    .accessibilityIdentifier("recording.skipBreak")
            }
            if buttons.bar.contains(.goLive) {
                barButton(RecordingGoLive.label, icon: RecordingGoLive.icon, red: true) { model.goLive() }
                    .accessibilityIdentifier("recording.goLive")
            }
        }
    }
}
#endif
