#if os(tvOS)
import SwiftUI
import AVFoundation
import AVKit

// Pieces of the live player shared with other screens (split out of CustomPlayer.swift in build 39).

/// The row of round action buttons; the selected one is white and labelled.
struct PlayerActionRow: View {
    let items: [(icon: String, label: String)]
    let selected: Int
    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = index == selected
                VStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .background(isSelected ? Color.white : Color.white.opacity(0.18), in: Circle())
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .scaleEffect(isSelected ? 1.1 : 1)
                    Text(item.label).font(.system(size: 18, weight: .medium))
                        .opacity(isSelected ? 1 : 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
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
                                       .init(color: .black.opacity(reduceTransparency ? 0.95 : opacity), location: 0.22),
                                       .init(color: .black.opacity(reduceTransparency ? 0.95 : max(opacity, 0.9)), location: 1)],
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
// It also owns the TV's display mode: a bare AVPlayerLayer never asks tvOS to
// switch to HDR / the stream's frame rate (AVPlayerViewController did that
// itself), so the stream's criteria are applied to the hosting window here.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let criteria: AVDisplayCriteria?
    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        // The view that last applied criteria. Only it may reset them, so an
        // outgoing channel's view cannot clear the incoming channel's mode.
        private static weak var owner: LayerView?
        var criteria: AVDisplayCriteria? {
            didSet { if criteria !== oldValue { apply() } }
        }
        private func apply() {
            guard let window else { return }
            window.avDisplayManager.preferredDisplayCriteria = criteria
            Self.owner = self
        }
        func reset() {
            guard Self.owner === self else { return }
            window?.avDisplayManager.preferredDisplayCriteria = nil
            Self.owner = nil
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            // Leaving the screen (exit to the guide, an error, or the next
            // channel's view taking over): return the TV to its default mode.
            if newWindow == nil { reset() }
            super.willMove(toWindow: newWindow)
        }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.criteria = criteria
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.criteria = criteria
    }
    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
        view.reset()
    }
}
#endif
