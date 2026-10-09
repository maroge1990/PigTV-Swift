import SwiftUI

// The branded start-up view (Pig family brand 1.6): the canvas colour, the PigTV pig with a static halo and, once the
// wordmark has faded in, the name. The halo then breathes into a bloom and back (8 s cycle, 4 s each way) while the view is
// visible. The pig, the name and the layout never move or scale. Geometry and colours come from `BrandLayout`, which
// Tools/render-launch.swift also uses to draw the launch image, so this view's first frame (halo at full opacity, no
// bloom, no wordmark) is the launch screen and nothing jumps.
//
// It only ever shows while the app is genuinely starting (ContentView's `!initialRestoreFinished`): nothing waits for a
// cycle to finish, and when start-up ends the view is simply cross-faded away.
//
// Reduce Motion: static halo, no animation, wordmark shown. Reduce Transparency: plain canvas, no glow.

struct BrandSplashView: View {
    /// The layout square's side in points (BrandLayout's unit S); the launch image is sized from the same value.
    #if os(tvOS)
    static let side: CGFloat = 1080
    #else
    static let side: CGFloat = 600
    #endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    /// false: the launch-screen frame (halo 1, bloom 0 at 0.9); true: the other end of the breathing cycle.
    @State private var breathing = false
    @State private var wordIn = false
    @State private var slowStart = false

    private var showWord: Bool { wordIn || reduceMotion }

    var body: some View {
        let s = Self.side
        let r = BrandLayout.haloRadius * s
        let dark = scheme == .dark
        ZStack {
            Color("LaunchEdge")
            if !reduceTransparency {
                RadialGradient(stops: BrandLayout.halo(dark: dark).gradientStops,
                               center: .center, startRadius: 0, endRadius: r)
                    .frame(width: 2 * r, height: 2 * r)
                    .opacity(breathing ? 0.25 : 1)
                if !reduceMotion {
                    ZStack {
                        RadialGradient(stops: BrandLayout.bloomWide(dark: dark).gradientStops, center: .center,
                                       startRadius: 0, endRadius: BrandLayout.bloomWideRadius * r)
                            .frame(width: 2 * BrandLayout.bloomWideRadius * r, height: 2 * BrandLayout.bloomWideRadius * r)
                        RadialGradient(stops: BrandLayout.bloomCore(dark: dark).gradientStops, center: .center,
                                       startRadius: 0, endRadius: BrandLayout.bloomCoreRadius * r)
                            .frame(width: 2 * BrandLayout.bloomCoreRadius * r, height: 2 * BrandLayout.bloomCoreRadius * r)
                    }
                    .scaleEffect(breathing ? 1.12 : 0.9)
                    .opacity(breathing ? 1 : 0)
                }
            }
            Image("PigLogo").resizable()
                .frame(width: BrandLayout.markSide * s, height: BrandLayout.markSide * s)
            Image("BrandWordmark").resizable()
                .frame(width: BrandLayout.wordmarkWidth * s, height: BrandLayout.wordmarkHeight * s)
                .offset(y: (BrandLayout.wordmarkTop + BrandLayout.wordmarkHeight / 2) * s)
                .opacity(showWord ? 1 : 0)
            if slowStart {
                ProgressView().controlSize(.small).opacity(0.55)
                    .offset(y: s * 0.40)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting PigTV")
        .task { play() }
        .task {
            // A quiet progress indicator, only when start-up is genuinely slow.
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.4)) { slowStart = true } }
        }
    }

    /// Starts after the first frame is on screen: the wordmark fades in over 250 ms, the glow breathes (never when Reduce
    /// Motion is on).
    private func play() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.25)) { wordIn = true }
        withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathing = true }
    }
}

#Preview { BrandSplashView() }
