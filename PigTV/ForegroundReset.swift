import SwiftUI

/// Every open starts from scratch (Mark, 18 Nov 2026): a return from the background (scene phase `.background` →
/// `.active`) is opened like a cold launch. The app goes back to the opening tab at its root (pushed pages, pages and
/// sheets closed, scrolled to the top) and the splash plays again and lands on that tab's header pig (#342, D-69), so the
/// pig always lands in a known place. A mere `.inactive` blip (Control Center, an alert, the app switcher half-opened)
/// changes nothing. A player that is up (watching, Picture in Picture, background audio, a recording) is kept and nothing
/// splashes. A link (`pigtv://play` from the Top Shelf or a timer, `pigtv://game`) that arrives with the return opens
/// once the splash has landed, as a cold launch plays it after its start-up. Pure (`ForegroundResetTests`).
nonisolated struct ForegroundReset: Sendable {
    /// The scene has been in the background since the last time it was active.
    private(set) var wasInBackground = false
    /// A reset's splash is playing: links wait for it to land.
    private(set) var splashing = false
    /// Links that arrived while the return was being decided or the splash played, in order.
    private(set) var heldLinks: [URL] = []
    /// The scene is active now (Codex review of 320: a splash that lands after the scene left again releases nothing).
    private(set) var active = true

    /// What a scene phase change asks of the app root.
    struct Step: Equatable, Sendable {
        /// Back to the opening tab at its root, and the splash plays.
        var reset = false
        /// Links to open now.
        var open: [URL] = []
    }

    /// `playerUp`: a player is presented (live or recording, full screen or in Picture in Picture). `signedIn`: there is
    /// a session with its pages (the splash lands on a header only then).
    mutating func sceneChanged(to phase: ScenePhase, playerUp: Bool, signedIn: Bool) -> Step {
        active = phase == .active
        switch phase {
        case .background:
            wasInBackground = true
            return Step()
        case .active:
            // An .inactive blip: nothing resets. Links held for a splash that landed during the blip (Codex sign-off of
            // 320) open now; while a splash still plays they keep waiting for it.
            guard wasInBackground else { return Step(open: splashing ? [] : releaseLinks()) }
            wasInBackground = false
            guard signedIn, !playerUp else { return Step(open: releaseLinks()) }
            splashing = true
            return Step(reset: true)
        default:
            return Step()
        }
    }

    /// A link arrived: true to open it now; false when it is held until the return's splash has landed.
    mutating func linkArrived(_ url: URL) -> Bool {
        guard wasInBackground || splashing else { return true }
        heldLinks.append(url)
        return false
    }

    /// The splash has landed: the held links, to open now. One that lands while the scene is not active (it went back to
    /// the background during the splash) releases nothing: the links wait for the next return's splash, or for a
    /// return to a player.
    mutating func splashLanded() -> [URL] {
        splashing = false
        guard active, !wasInBackground else { return [] }
        return releaseLinks()
    }

    private mutating func releaseLinks() -> [URL] {
        defer { heldLinks = [] }
        return heldLinks
    }
}
