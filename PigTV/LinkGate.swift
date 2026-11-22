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
    /// Links waiting, in order, each with the sign-in session it arrived in (`AppModel.sessionGeneration`).
    private var waiting: [(url: URL, session: Int)] = []
    /// Links waiting, in order.
    var held: [URL] { waiting.map { $0.url } }

    /// A link arrived (in `session`): true to open it now; false when it is held.
    mutating func arrived(_ url: URL, session: Int = 0) -> Bool {
        if active && cleanups == 0 { return true }
        waiting.append((url, session))
        return false
    }

    /// The scene phase changed: the held links to open now (none unless active with no clean-up running). #54: only
    /// those that arrived in `session`: a link held while a session ended (Sign out, a refused sign-in) is dropped.
    mutating func sceneChanged(active: Bool, session: Int = 0) -> [URL] {
        self.active = active
        return release(session: session)
    }

    /// The app went to the background and its clean-up started.
    mutating func cleanupStarted() { cleanups += 1 }

    /// That clean-up has run: the held links to open now, if the scene is active.
    mutating func cleanupFinished(session: Int = 0) -> [URL] {
        cleanups = max(0, cleanups - 1)
        return release(session: session)
    }

    private mutating func release(session: Int) -> [URL] {
        guard active, cleanups == 0, !waiting.isEmpty else { return [] }
        defer { waiting = [] }
        return waiting.filter { $0.session == session }.map { $0.url }
    }
}

/// ContentView's links (#54, Codex sign-off of 395): through the gate, into the model. A link that arrives while a refused
/// session is ending is dropped at once; one held across a session's end is dropped when released.
@MainActor
extension LinkGate {
    mutating func receive(_ url: URL, into model: AppModel) {
        guard !model.sessionEnding else { return }
        if arrived(url, session: model.sessionGeneration) { model.open(url) }
    }

    mutating func sceneChanged(active: Bool, into model: AppModel) {
        for url in sceneChanged(active: active, session: model.sessionGeneration) { model.open(url) }
    }

    mutating func cleanupFinished(into model: AppModel) {
        for url in cleanupFinished(session: model.sessionGeneration) { model.open(url) }
    }
}
