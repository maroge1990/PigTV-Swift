import Foundation

/// A pigtv:// link (the Top Shelf's play or game, a timer) that arrives while the scene is not active is held, and opens
/// once the scene is active and the app's background clean-up (`AppModel.background()`, which cancels a waiting play or
/// hand-off) has run. Without it a warm link delivered as the app comes back, before the scene is active, could be queued
/// and then cancelled by the clean-up of the trip to the background (Codex review of Apple 325). A link that arrives while
/// active opens at once. Pure (`LinkGateTests`).
nonisolated struct LinkGate: Sendable {
    /// The scene is active (ContentView sets it from the scene phase, its first value included).
    private(set) var active = false
    /// Background clean-ups started and not finished yet.
    private(set) var cleanups = 0
    /// Links waiting, in order.
    private(set) var held: [URL] = []

    /// A link arrived: true to open it now; false when it is held.
    mutating func arrived(_ url: URL) -> Bool {
        if active && cleanups == 0 { return true }
        held.append(url)
        return false
    }

    /// The scene phase changed: the held links to open now (none unless active with no clean-up running).
    mutating func sceneChanged(active: Bool) -> [URL] {
        self.active = active
        return release()
    }

    /// The app went to the background and its clean-up started.
    mutating func cleanupStarted() { cleanups += 1 }

    /// That clean-up has run: the held links to open now, if the scene is active.
    mutating func cleanupFinished() -> [URL] {
        cleanups = max(0, cleanups - 1)
        return release()
    }

    private mutating func release() -> [URL] {
        guard active, cleanups == 0, !held.isEmpty else { return [] }
        defer { held = [] }
        return held
    }
}
