import SwiftUI

// The branded start-up view (Pig family brand), maroge1990/PigTV#342 option C, "Into the header" (Mark, 18 Nov 2026).
// One pig from the first frame to the last:
//   0-0.6 s   the launch frame: the canvas colour, the pig and its static halo, exactly the launch image (BrandLayout is
//             the geometry of both; Tools/render-launch.swift draws the image), so nothing jumps.
//   0.6 s on  the halo's bloom swells and settles (1.5 s); the name alone (the kit's wordmark, placed where the stacked
//             lockup has it, never a second pig) rises 10 pt and fades in under the pig (from 0.95 s, 0.65 s).
//   2.0 s on  (or later: once start-up has finished and the page Home opens on has its first content in and laid out,
//             capped at 4 s past that point) the name fades out; the pig glides and shrinks onto the pig mark of
//             Home's page header (PigPageHeader) while the halo, the bloom and the canvas fade and Home fades in and glides
//             18 pt up into place; at 3.2 s the header's own mark takes over at the same place and size, so nothing visibly swaps.
// Home's glide is drawn, never laid out: a UIKit transform on the view that holds Home's tabs (found from the header's
// landing spot, `SplashGlideProbe`), which SwiftUI's layout never sees. A SwiftUI offset (or visualEffect, or projection)
// moved Home against the screen's safe area and SwiftUI laid the page out again by its new insets (60 pt lower on the
// Apple TV, a 1-2 pt shimmer on the iPad and iPhone), so the pig landed where the header was while risen and the page
// jumped when it settled. Home without tabs (sign-in, Offline) has no header to land on and only fades.
// The splash holds its full length even when start-up is quicker (this changes brand §8's "never adds delay"; Mark's
// choice), and waits for the opening page's first content so the pig lands on a page that is already still (Mark, 19 Nov
// 2026). It plays on a cold launch only: a return from the background shows the app as it was left, with no splash. With
// no saved sign-in there is no splash (LaunchStep): the first screen is sign-in, not Home.
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
    /// From the hand-off's start: the name fades out at once; the pig flies after `flightDelay`; Home glides in after
    /// `revealDelay`. Both end together.
    static let nameOut: Double = 0.3
    static let flightDelay: Double = 0.35
    static let flight: Double = 0.85
    static let revealDelay: Double = 0.4
    static let reveal: Double = 0.8
    /// Halo and bloom fade out over the flight's first part.
    static let glowOut: Double = 0.5

    /// How far the name rises and Home glides, in points on a 600 pt splash (scaled with the splash's side).
    static let nameRise: CGFloat = 10
    static let contentRise: CGFloat = 18

    /// From the hand-off's start to Home on its own (the header's mark taking over): 1.2 s.
    static var handoff: Double { max(flightDelay + flight, revealDelay + reveal) }
    /// The whole splash when start-up is quicker than it: 3.2 s.
    static var minimumLength: Double { settled + handoff }

    /// The page Home opens on is laid out this long after it says its first content is in (`splashPageReady`).
    static let pageSettle: Double = 0.15
    /// The longest the hand-off waits for that page, past the settled pig and name (or start-up's end, if later).
    static let pageWaitCap: Double = 4

    /// When the hand-off starts: once the pig and the name have settled, start-up has finished, and the opening page's
    /// first content is in and laid out (`pageReadyAt` + `pageSettle`), whichever is latest; but never more than
    /// `pageWaitCap` after the first two. nil while start-up still runs (the splash waits on the settled pig and name).
    /// `pageReadyAt`: when the page said its content is in; nil: not yet (the answer is then the cap, which a later
    /// answer can only bring forward); 0: no page to wait for (sign-in, Offline).
    static func handoffStart(restoreFinishedAt: Double?, pageReadyAt: Double? = 0) -> Double? {
        guard let restoreFinishedAt else { return nil }
        let earliest = max(settled, restoreFinishedAt)
        let latest = earliest + pageWaitCap
        guard let pageReadyAt else { return latest }
        return min(max(earliest, pageReadyAt + pageSettle), latest)
    }

    /// When Home is on its own.
    static func end(restoreFinishedAt: Double?, pageReadyAt: Double? = 0) -> Double? {
        handoffStart(restoreFinishedAt: restoreFinishedAt, pageReadyAt: pageReadyAt).map { $0 + handoff }
    }

    /// The quiet progress indicator: only when start-up is still running after the sequence would have ended.
    static func showsProgress(at t: Double, restoreFinished: Bool) -> Bool {
        !restoreFinished && t >= minimumLength
    }

    nonisolated enum Phase: Equatable, Sendable { case launchFrame, namingIn, settled, handingOff, done }

    static func phase(at t: Double, restoreFinishedAt: Double?, pageReadyAt: Double? = 0) -> Phase {
        if let end = end(restoreFinishedAt: restoreFinishedAt, pageReadyAt: pageReadyAt), t >= end { return .done }
        if let start = handoffStart(restoreFinishedAt: restoreFinishedAt, pageReadyAt: pageReadyAt), t >= start { return .handingOff }
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
    static var revealAnimation: Animation { .easeOut(duration: reveal) } // motion: #342 Home glides in
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
    /// Home is shown, and how far below its place its tabs are drawn until they glide in (a transform: layout never moves).
    private(set) var contentShown: Bool
    let contentRise: CGFloat
    /// Home takes touches, presses, focus and VoiceOver only once the splash is gone (#342, Codex review: not while it
    /// still fades in under the splash's overlay).
    var homeInteractive: Bool { landed }
    /// Start-up finished, in seconds from the splash's first frame.
    private(set) var restoreFinishedAt: Double?
    /// The header Home opens on (its title), once signed in; nil: there is no header to land on.
    var landingTitle: String?
    /// Each header mark's frame in window coordinates: where it settles (SwiftUI's frames never include the glide's
    /// transform, which is UIKit's alone).
    @ObservationIgnored private(set) var markFrames: [String: CGRect] = [:]
    /// When each page said its first content was in, in seconds from the splash's first frame (`splashPageReady`).
    @ObservationIgnored private var pagesReadyAt: [String: Double] = [:]
    @ObservationIgnored private var revealing = false
    /// The view that holds Home's tabs, drawn `contentRise` low until the glide (`SplashGlideProbe`).
    @ObservationIgnored private weak var glideView: UIView?
    @ObservationIgnored private let started = ContinuousClock.now

    init(playing: Bool, contentRise: CGFloat = 0) {
        landed = !playing
        contentShown = !playing
        self.contentRise = playing ? contentRise : 0
    }

    /// The view that holds Home's tabs was found under the splash: it is drawn `rise` low (0 under Reduce Motion) until
    /// the glide. A transform only: SwiftUI lays Home out as if it were in place, so its frames are the settled ones.
    func glide(_ view: UIView, rise: CGFloat) {
        guard !landed, !revealing, glideView == nil else { return }
        glideView = view
        view.transform = CGAffineTransform(translationX: 0, y: rise)
    }

    var elapsed: Double {
        let d = ContinuousClock.now - started
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func restoreFinished() { if restoreFinishedAt == nil { restoreFinishedAt = elapsed } }

    /// A page (by its header's title) has its first content in: the first time counts.
    func pageReady(title: String) { if pagesReadyAt[title] == nil { pagesReadyAt[title] = elapsed } }

    /// When the page Home opens on had its first content; 0 when there is no header to land on (nothing to wait for).
    var pageReadyAt: Double? {
        guard let landingTitle else { return 0 }
        return pagesReadyAt[landingTitle]
    }

    /// When the hand-off starts (SplashTimeline), nil while start-up runs.
    var handoffStart: Double? { SplashTimeline.handoffStart(restoreFinishedAt: restoreFinishedAt, pageReadyAt: pageReadyAt) }

    /// A header mark's frame (window coordinates), taken until Home starts gliding in. It is the settled frame whatever
    /// the glide's transform, so the landing spot is the frame as reported.
    func report(title: String, frame: CGRect) {
        guard !landed, !revealing else { return }
        markFrames[title] = frame
    }

    /// Where the pig lands: the opening tab's header mark.
    var target: CGRect? {
        guard let landingTitle else { return nil }
        return markFrames[landingTitle]
    }

    /// Home fades in and glides into place (ContentView draws no glide under Reduce Motion: it only fades).
    func reveal() {
        revealing = true
        contentShown = true
        if let glideView {
            UIView.animate(withDuration: SplashTimeline.reveal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { glideView.transform = .identity } // motion: #342 Home glides in
        }
    }

    /// The header's mark takes over and the splash goes.
    func land() {
        revealing = true
        glideView?.layer.removeAllAnimations()
        glideView?.transform = .identity
        contentShown = true
        landed = true
    }
}

/// #342: a header's pig mark as the splash's landing spot: hidden while the splash plays, its frame reported.
private struct SplashLandingSpot: ViewModifier {
    let title: String
    @Environment(SplashHandoff.self) private var handoff: SplashHandoff?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity((handoff?.landed ?? true) ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                handoff?.report(title: title, frame: frame)
            }
            .background {
                if let handoff, !handoff.landed {
                    SplashGlideProbe(handoff: handoff, rise: reduceMotion ? 0 : handoff.contentRise).accessibilityHidden(true)
                }
            }
    }
}

/// #342: finds the UIKit view that holds Home's tabs (the tab bar controller's view, above the header) for the glide.
private struct SplashGlideProbe: UIViewRepresentable {
    let handoff: SplashHandoff
    let rise: CGFloat

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.found = { [weak handoff] view in handoff?.glide(view, rise: rise) }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        var found: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let candidate = view {
                if candidate.next is UITabBarController { found?(candidate); return }
                view = candidate.superview
            }
        }
    }
}

/// #342: the page Home opens on says when its first content is in (not its loading placeholder), so the splash hands
/// over to a page that is already still.
private struct SplashPageReady: ViewModifier {
    let title: String
    let ready: Bool
    @Environment(SplashHandoff.self) private var handoff: SplashHandoff?

    func body(content: Content) -> some View {
        content.onChange(of: ready, initial: true) { _, ready in
            if ready { handoff?.pageReady(title: title) }
        }
    }
}

extension View {
    func splashLandingSpot(_ title: String) -> some View { modifier(SplashLandingSpot(title: title)) }
    /// `title`: the page's header title (`LibraryView.title(of:)`); `ready`: its first content is in.
    func splashPageReady(_ title: String, when ready: Bool) -> some View { modifier(SplashPageReady(title: title, ready: ready)) }
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
        // The canvas is exactly the screen and the pig sits at its centre, as the launch image's does (it is centred on
        // the screen, ignoring the safe area). The bloom is wider than an iPhone is tall; left to size the stack, it made the
        // stack overflow the screen, which was then centred in the safe area instead: 14 pt lower on an iPhone with a
        // notch (its top inset is 62 pt, its bottom 34), the jump from the launch screen's pig to the splash's.
        GeometryReader { screen in
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
            .frame(width: screen.size.width, height: screen.size.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .clipped()
        }
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
            // Start-up, then the opening page's first content (capped: SplashTimeline.handoffStart).
            while true {
                if let start = handoff.handoffStart, handoff.elapsed >= start { break }
                try await Task.sleep(for: .milliseconds(50))
            }
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
