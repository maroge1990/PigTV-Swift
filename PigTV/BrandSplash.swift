import SwiftUI

// The branded start-up view (Pig family brand), maroge1990/PigTV#342 option C, "Into the header" (Mark, 18 Nov 2026).
// One pig from the first frame to the last:
//   0-0.6 s   the launch frame: the canvas colour, the pig and its static halo, exactly the launch image (BrandLayout is
//             the geometry of both; Tools/render-launch.swift draws the image), so nothing jumps.
//   0.6 s on  the halo's bloom swells and settles (1.5 s); the name alone (the kit's wordmark, placed where the stacked
//             lockup has it, never a second pig) rises 10 pt and fades in under the pig (from 0.95 s, 0.65 s).
//   2.0 s on  (or when start-up finishes, if later) the name fades out; the pig glides and shrinks onto the pig mark of
//             Home's page header (PigPageHeader) while the halo, the bloom and the canvas fade and Home rises 18 pt into
//             place; at 3.2 s the header's own mark takes over at the same place and size, so nothing visibly swaps.
// The splash holds its full length even when start-up is quicker (this changes brand §8's "never adds delay"; Mark's
// choice). With no saved sign-in there is no splash (LaunchStep): the first screen is sign-in, not Home.
//
// Reduce Motion: no bloom, the name fades in without rising, and the splash cross-fades to Home (no flight). Reduce
// Transparency: plain canvas, no glow. The quiet progress indicator shows only when start-up is still running after
// the sequence would have ended.

/// #342: the splash's timeline in seconds from its first frame, and its decisions (pure, `SplashTimelineTests`).
nonisolated enum SplashTimeline {
    /// The launch frame holds.
    static let launchHold: Double = 0.6
    /// The bloom swells, then settles.
    static let bloomSwell: Double = 0.75
    static let bloomSettle: Double = 0.75
    /// The name starts rising in this long after the launch frame, and takes `nameIn`.
    static let nameDelay: Double = 0.35
    static let nameIn: Double = 0.65
    /// The earliest hand-off: the pig and the name have settled.
    static let settled: Double = 2.0
    /// From the hand-off's start: the name fades out at once; the pig flies after `flightDelay`; Home rises in after
    /// `revealDelay`. Both end together.
    static let nameOut: Double = 0.3
    static let flightDelay: Double = 0.35
    static let flight: Double = 0.85
    static let revealDelay: Double = 0.4
    static let reveal: Double = 0.8
    /// Halo and bloom fade out over the flight's first part.
    static let glowOut: Double = 0.5

    /// How far the name rises and Home rises, in points on a 600 pt splash (scaled with the splash's side).
    static let nameRise: CGFloat = 10
    static let contentRise: CGFloat = 18

    /// From the hand-off's start to Home on its own (the header's mark taking over): 1.2 s.
    static var handoff: Double { max(flightDelay + flight, revealDelay + reveal) }
    /// The whole splash when start-up is quicker than it: 3.2 s.
    static var minimumLength: Double { settled + handoff }

    /// When the hand-off starts: once the pig and the name have settled and start-up has finished, whichever is later;
    /// nil while start-up still runs (the splash waits on the settled pig and name).
    static func handoffStart(restoreFinishedAt: Double?) -> Double? {
        restoreFinishedAt.map { max(settled, $0) }
    }

    /// When Home is on its own.
    static func end(restoreFinishedAt: Double?) -> Double? {
        handoffStart(restoreFinishedAt: restoreFinishedAt).map { $0 + handoff }
    }

    /// The quiet progress indicator: only when start-up is still running after the sequence would have ended.
    static func showsProgress(at t: Double, restoreFinished: Bool) -> Bool {
        !restoreFinished && t >= minimumLength
    }

    nonisolated enum Phase: Equatable, Sendable { case launchFrame, namingIn, settled, handingOff, done }

    static func phase(at t: Double, restoreFinishedAt: Double?) -> Phase {
        if let end = end(restoreFinishedAt: restoreFinishedAt), t >= end { return .done }
        if let start = handoffStart(restoreFinishedAt: restoreFinishedAt), t >= start { return .handingOff }
        if t < launchHold { return .launchFrame }
        return t < launchHold + nameDelay + nameIn ? .namingIn : .settled
    }

    nonisolated enum Handoff: Equatable, Sendable { case flight, crossFade }

    /// The flight needs motion and a header pig to land on (sign-in or Offline has none): else a plain cross-fade.
    static func handoff(reduceMotion: Bool, hasTarget: Bool) -> Handoff {
        !reduceMotion && hasTarget ? .flight : .crossFade
    }

    // The splash's own timing (brand §8 and #342's mock), so each is marked for BrandRulesTests.
    static var bloomSwellAnimation: Animation { .easeInOut(duration: bloomSwell) } // motion: #342 splash bloom
    static var bloomSettleAnimation: Animation { .easeInOut(duration: bloomSettle) } // motion: #342 splash bloom
    static var nameInAnimation: Animation { .easeOut(duration: nameIn) } // motion: #342 splash name
    static var nameOutAnimation: Animation { .easeOut(duration: nameOut) } // motion: #342 splash name
    static var flightAnimation: Animation { .timingCurve(0.65, 0, 0.25, 1, duration: flight) } // motion: #342 flight
    static var glowOutAnimation: Animation { .easeOut(duration: glowOut) } // motion: #342 splash glow
    static var revealAnimation: Animation { .easeOut(duration: reveal) } // motion: #342 Home rises in
}

/// #342: where the splash's pig lands. The header mark is a `PigBrandMark` (its ink centred in its frame, as wide as
/// `min(width, height x 1000/797)`); the splash pig's ink is `pigInkWidth` wide, centred in the splash.
nonisolated enum SplashFlight {
    static func landing(mark: CGRect, splash: CGRect, pigInkWidth: CGFloat) -> (offset: CGSize, scale: CGFloat) {
        let markInk = min(mark.width, mark.height * 1000 / 797)
        return (CGSize(width: mark.midX - splash.midX, height: mark.midY - splash.midY), markInk / pigInkWidth)
    }
}

/// #342: what the splash and Home share during the hand-off. ContentView owns it; the header's pig mark reports where it
/// is (`SplashLandingSpot`) and stays hidden until the splash's pig has landed on it.
@Observable @MainActor
final class SplashHandoff {
    /// The splash is over (or never played): the header's own mark shows and the splash is gone.
    private(set) var landed: Bool
    /// Home is shown, and how far below its place it is (the visual reveal only).
    private(set) var contentShown: Bool
    /// Home takes touches, presses, focus and VoiceOver only once the splash is gone (#342, Codex review: not while it
    /// still rises under the splash's overlay).
    var homeInteractive: Bool { landed }
    private(set) var contentRise: CGFloat
    /// Start-up finished, in seconds from the splash's first frame.
    private(set) var restoreFinishedAt: Double?
    /// The header Home opens on (its title), once signed in; nil: there is no header to land on.
    var landingTitle: String?
    /// Each header mark's frame in window coordinates as it will be once Home has risen into place.
    @ObservationIgnored private(set) var markFrames: [String: CGRect] = [:]
    @ObservationIgnored private var revealing = false
    @ObservationIgnored private let started = ContinuousClock.now

    init(playing: Bool, contentRise: CGFloat = 0) {
        landed = !playing
        contentShown = !playing
        self.contentRise = playing ? contentRise : 0
    }

    var elapsed: Double {
        let d = ContinuousClock.now - started
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func restoreFinished() { if restoreFinishedAt == nil { restoreFinishedAt = elapsed } }

    /// A header mark's frame (window coordinates). Taken only before Home starts rising, while it sits `contentRise`
    /// below its place, so the landing spot is where it will settle.
    func report(title: String, frame: CGRect) {
        guard !landed, !revealing else { return }
        markFrames[title] = frame.offsetBy(dx: 0, dy: -contentRise)
    }

    /// Where the pig lands: the opening tab's header mark.
    var target: CGRect? {
        guard let landingTitle else { return nil }
        return markFrames[landingTitle]
    }

    /// Home rises into place and fades in (under Reduce Motion ContentView draws no rise, so it only fades).
    func reveal() {
        revealing = true
        contentShown = true
        contentRise = 0
    }

    /// The header's mark takes over and the splash goes.
    func land() {
        revealing = true
        contentRise = 0
        contentShown = true
        landed = true
    }
}

/// #342: a header's pig mark as the splash's landing spot: hidden while the splash plays, its frame reported.
private struct SplashLandingSpot: ViewModifier {
    let title: String
    @Environment(SplashHandoff.self) private var handoff: SplashHandoff?

    func body(content: Content) -> some View {
        content
            .opacity((handoff?.landed ?? true) ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                handoff?.report(title: title, frame: frame)
            }
    }
}

extension View {
    func splashLandingSpot(_ title: String) -> some View { modifier(SplashLandingSpot(title: title)) }
}

struct BrandSplashView: View {
    /// The layout square's side in points (BrandLayout's unit S); the launch image is sized from the same value.
    #if os(tvOS)
    static let side: CGFloat = 1080
    #else
    static let side: CGFloat = 600
    #endif
    /// Points per point of the 600 pt splash (the mock's rise distances).
    static var unit: CGFloat { side / 600 }

    /// nil: the splash alone (PIGTV_UI_TEST_SCREEN=splash), which plays to the settled pig and name and stays.
    var handoff: SplashHandoff? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    private enum Bloom { case off, peak, rest }
    @State private var bloom = Bloom.off
    @State private var nameShown = false
    @State private var nameGone = false
    @State private var glowGone = false
    @State private var canvasGone = false
    @State private var pigGone = false
    @State private var landing: (offset: CGSize, scale: CGFloat)? = nil
    @State private var slowStart = false

    var body: some View {
        let s = Self.side
        let r = BrandLayout.haloRadius * s
        let dark = scheme == .dark
        let pig = BrandLayout.pigInkWidth * s
        ZStack {
            Color("LaunchEdge").opacity(canvasGone ? 0 : 1)
            if !reduceTransparency {
                ZStack {
                    RadialGradient(stops: BrandLayout.halo(dark: dark).gradientStops,
                                   center: .center, startRadius: 0, endRadius: r)
                        .frame(width: 2 * r, height: 2 * r)
                    if !reduceMotion {
                        ZStack {
                            RadialGradient(stops: BrandLayout.bloomWide(dark: dark).gradientStops, center: .center,
                                           startRadius: 0, endRadius: BrandLayout.bloomWideRadius * r)
                                .frame(width: 2 * BrandLayout.bloomWideRadius * r, height: 2 * BrandLayout.bloomWideRadius * r)
                            RadialGradient(stops: BrandLayout.bloomCore(dark: dark).gradientStops, center: .center,
                                           startRadius: 0, endRadius: BrandLayout.bloomCoreRadius * r)
                                .frame(width: 2 * BrandLayout.bloomCoreRadius * r, height: 2 * BrandLayout.bloomCoreRadius * r)
                        }
                        // brand splashMotion: bloom opacity 0 -> 1 and scale 0.9 -> 1.12 at its peak; it settles between
                        .scaleEffect(bloom == .peak ? 1.12 : bloom == .rest ? 1.0 : 0.9)
                        .opacity(bloom == .peak ? 1 : bloom == .rest ? 0.6 : 0)
                    }
                }
                .opacity(glowGone ? 0 : 1)
            }
            // The name alone, where the kit's stacked lockup has it under this pig.
            let word = BrandLayout.stackedWordmarkSize, centre = BrandLayout.stackedWordmarkCentreFromPig
            Image("BrandWordmark").resizable()
                .frame(width: word.width * pig, height: word.height * pig)
                .offset(x: centre.x * pig, y: centre.y * pig + (nameShown || reduceMotion ? 0 : SplashTimeline.nameRise * Self.unit))
                .opacity(nameShown && !nameGone ? 1 : 0)
            // The one pig: the launch image's, later flying onto the header's mark.
            Image("PigLogo").resizable()
                .frame(width: BrandLayout.markSide * s, height: BrandLayout.markSide * s)
                .scaleEffect(landing?.scale ?? 1)
                .offset(landing?.offset ?? .zero)
                .opacity(pigGone ? 0 : 1)
            if slowStart {
                ProgressView().controlSize(.small).opacity(0.55)
                    .offset(y: s * 0.40)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .clipped()
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting PigTV")
        .task { await play() }
        .task {
            // A quiet progress indicator, only when start-up is still running after the sequence would have ended.
            try? await Task.sleep(for: .seconds(SplashTimeline.minimumLength))
            guard !Task.isCancelled, SplashTimeline.showsProgress(at: SplashTimeline.minimumLength,
                                                                   restoreFinished: handoff?.restoreFinishedAt != nil) else { return }
            withAnimation(PigMotion.standard) { slowStart = true }
        }
    }

    @State private var frame: CGRect = .zero

    /// Plays the timeline from the launch frame (the first frame is already on screen).
    private func play() async {
        let clock = ContinuousClock()
        let start = clock.now
        func at(_ t: Double) async throws { try await clock.sleep(until: start + .milliseconds(Int(t * 1000))) }
        do {
            try await at(SplashTimeline.launchHold)
            if !reduceMotion { withAnimation(SplashTimeline.bloomSwellAnimation) { bloom = .peak } }
            try await at(SplashTimeline.launchHold + SplashTimeline.nameDelay)
            withAnimation(SplashTimeline.nameInAnimation) { nameShown = true }
            try await at(SplashTimeline.launchHold + SplashTimeline.bloomSwell)
            if !reduceMotion { withAnimation(SplashTimeline.bloomSettleAnimation) { bloom = .rest } }
            try await at(SplashTimeline.settled)
            guard let handoff else { return } // the splash alone stays on the settled pig and name
            while handoff.restoreFinishedAt == nil { try await Task.sleep(for: .milliseconds(50)) }
            // Home has just been laid out under the splash: give its header a moment to report where its pig is.
            if handoff.landingTitle != nil {
                for _ in 0..<12 where handoff.target == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            try await handOff(handoff, clock: clock)
        } catch {
            return // cancelled: the view went away
        }
    }

    private func handOff(_ handoff: SplashHandoff, clock: ContinuousClock) async throws {
        let start = clock.now
        func at(_ t: Double) async throws { try await clock.sleep(until: start + .milliseconds(Int(t * 1000))) }
        withAnimation(PigMotion.standard) { slowStart = false }
        switch SplashTimeline.handoff(reduceMotion: reduceMotion, hasTarget: handoff.target != nil) {
        case .flight:
            withAnimation(SplashTimeline.nameOutAnimation) { nameGone = true }
            try await at(SplashTimeline.flightDelay)
            if let target = handoff.target {
                let to = SplashFlight.landing(mark: target, splash: frame, pigInkWidth: BrandLayout.pigInkWidth * Self.side)
                withAnimation(SplashTimeline.flightAnimation) { landing = to }
            }
            withAnimation(SplashTimeline.glowOutAnimation) { glowGone = true }
            try await at(SplashTimeline.revealDelay)
            withAnimation(SplashTimeline.revealAnimation) {
                canvasGone = true
                handoff.reveal()
            }
        case .crossFade:
            // Reduce Motion (or nothing to land on): the splash fades out as Home fades in; nothing moves.
            try await at(SplashTimeline.revealDelay)
            withAnimation(SplashTimeline.revealAnimation) {
                canvasGone = true
                glowGone = true
                nameGone = true
                pigGone = true
                handoff.reveal()
            }
        }
        try await at(SplashTimeline.handoff)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { handoff.land() }
    }
}

#Preview { BrandSplashView() }
