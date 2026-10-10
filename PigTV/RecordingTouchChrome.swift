import SwiftUI
import AVKit

#if os(iOS)
/// The recording player on iPhone and iPad: the picture (an AVPlayerLayer view,
/// so Picture in Picture can be started from here) and PigTV's controls over it:
/// the single close button, play/pause with ±15 s, the scrubber, Picture in
/// Picture and, whenever the playhead is inside a detected break, Skip break.
/// A tap on the picture shows or hides the controls (`PlayerChromeTimer`);
/// Skip break is outside that and stays up for the whole break.
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
            if model.inBreak != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { lastInput = Date(); model.skipBreak() } label: {
                            Label("Skip break", systemImage: "forward.end.fill")
                                .font(.headline).padding(.horizontal, 18).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(Color.pigAccent)
                        .foregroundStyle(Color.pigOnAccent)
                        .accessibilityIdentifier("recording.skipBreak")
                    }
                    // Above the scrub panel when it is showing.
                    .padding(.bottom, chromeVisible ? 96 : 24)
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: model.inBreak != nil)
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
                HStack(spacing: 12) {
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
                HStack(spacing: 36) {
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
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func scrubPanel(_ timeline: RecordingTimeline?) -> some View {
        if let timeline {
            let fraction = dragFraction ?? timeline.fraction
            HStack(spacing: 12) {
                Text(RecordingTimeline.clock(timeline.end * fraction))
                    .font(.footnote.weight(.semibold).monospacedDigit()).fontDesign(.rounded)
                    .frame(minWidth: 56, alignment: .leading)
                TouchScrubBar(fraction: fraction, changed: { value in
                    dragFraction = value; lastInput = Date()
                }, ended: { value in
                    model.seek(toFraction: value); dragFraction = nil; lastInput = Date()
                }, skip: { seconds in lastInput = Date(); model.skip(seconds) })
                .accessibilityLabel("Position")
                .accessibilityValue("\(RecordingTimeline.clock(timeline.end * fraction)) of \(RecordingTimeline.clock(timeline.end))")
                Text("−" + RecordingTimeline.clock(timeline.end * (1 - fraction)))
                    .font(.footnote.weight(.semibold).monospacedDigit()).fontDesign(.rounded)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .padding(12)
            .background(reduceTransparency ? AnyShapeStyle(Color(white: 0.08)) : AnyShapeStyle(Color.black.opacity(0.45)),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
#endif
