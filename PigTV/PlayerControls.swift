#if os(tvOS)
import SwiftUI
import AVFoundation
import AVKit

// Pieces of the live player shared with other screens (split out of CustomPlayer.swift in build 39).

/// The row of round action buttons (#58 option B: Pause, Auto-skip breaks, Audio & subtitles, Favourite, Record, Last
/// channel; `PlayerButtons`); the selected one is white. #369: every button has the same width and always shows its
/// name (a name hidden with opacity used to keep its own width, so the gaps between the circles differed).
/// `selected`: nil while the remote is on the bar.
struct PlayerActionRow: View {
    static let itemWidth: CGFloat = 140
    let items: [(icon: String, label: String)]
    let selected: Int?
    var body: some View {
        HStack(alignment: .top, spacing: PigSpacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = index == selected
                VStack(spacing: PigSpacing.s) {
                    Image(systemName: item.icon)
                        .font(.system(size: PigType.sectionTitle, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .background(isSelected ? Color.white : Color.white.opacity(0.18), in: Circle())
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .scaleEffect(isSelected ? 1.1 : 1)
                    Text(item.label).font(.system(size: PigType.caption, weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
                }
                .frame(width: Self.itemWidth, alignment: .top)
            }
        }
        .pigAnimation(value: selected, moves: true)
    }
}

/// A button on the progress bar (#58 option B: Start over at its start, Skip break and Go to live at its end): a pill,
/// white while the remote is on it. `destructive` (#335): the recording player's Go to live, red.
struct PlayerBarPill: View {
    let icon: String
    let label: String
    let selected: Bool
    var destructive = false
    var body: some View {
        Label(label, systemImage: icon)
            .font(.system(size: PigType.body, weight: .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
            .background(fill, in: Capsule())
            .foregroundStyle(glyph)
            .scaleEffect(selected ? 1.08 : 1)
            .pigAnimation(value: selected, moves: true)
    }

    private var fill: Color {
        if destructive { return selected ? Color.pigDanger : Color.white.opacity(0.18) }
        return selected ? Color.white : Color.white.opacity(0.18)
    }

    private var glyph: Color {
        if destructive { return selected ? Color.white : Color.pigDanger }
        return selected ? Color.black : Color.white
    }
}

extension PlayerCursor.Move {
    /// A remote arrow.
    init?(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        @unknown default: return nil
        }
    }
}

/// The pink scrub track with its knob (R17).
struct PlayerScrubTrack: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(Color.pigMediaAccent).frame(width: geometry.size.width * fraction)
                Circle().fill(Color.white).frame(width: 26, height: 26)
                    .offset(x: min(geometry.size.width - 26, max(0, geometry.size.width * fraction - 13)))
            }
        }.frame(height: 26)
    }
}

extension View {
    /// The dark gradient behind bottom player chrome, opaque enough with
    /// Reduce Transparency, sitting against the screen bottom.
    func playerBottomShade(height: CGFloat, opacity: Double) -> some View {
        modifier(PlayerBottomShade(height: height, opacity: opacity))
    }
}

private struct PlayerBottomShade: ViewModifier {
    let height: CGFloat
    let opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: Color.pigMediaCanvas.opacity(reduceTransparency ? 0.95 : max(opacity, 0.82)), location: 0.22),
                                       .init(color: Color.pigMediaCanvas.opacity(reduceTransparency ? 0.95 : max(opacity, 0.9)), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height).ignoresSafeArea()
            }
            .ignoresSafeArea(edges: .bottom)
    }
}

// Draws only the label — no tvOS focus container, lift or border — while still
// firing its action on the first Select press.
struct BlankButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

// Plain video surface: no AVKit controls, so no competing remote handling.
// It also shows the TV's display mode: a bare AVPlayerLayer never asks tvOS to
// switch to HDR / the stream's frame rate (AVPlayerViewController did that
// itself), so the stream's criteria are applied to the hosting window. #35
// (Apple 399): the mode is held by the play (TVDisplayModeHold), so a channel
// change keeps it through "Tuning…" instead of dropping to the default mode.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let criteria: AVDisplayCriteria?
    /// What the criteria ask for, when built from a resolve answer (equal modes are not asked for again).
    var mode: DisplayMode? = nil
    /// The play this view shows (a live play's PlaybackModel id); nil: the view is its own play (a recording).
    var play: UUID? = nil
    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var play = UUID()
        var mode: DisplayMode?
        var criteria: AVDisplayCriteria? {
            didSet { if criteria !== oldValue { apply() } }
        }
        private func apply() {
            guard let window else { return }
            TVDisplayModeHold.shared.shown(criteria, mode: mode, by: play, in: window)
        }
        func reset() {
            // The play leaving the screen (exit, an error): the TV's default mode. A play that handed the mode to
            // the next channel changes nothing here.
            TVDisplayModeHold.shared.ended(play)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { reset() }
            super.willMove(toWindow: newWindow)
        }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        if let play { view.play = play }
        view.mode = mode
        view.criteria = criteria
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.mode = mode
        view.criteria = criteria
    }
    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
        view.reset()
    }
}
#endif
