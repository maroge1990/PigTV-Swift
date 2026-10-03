import Foundation
import OSLog
import SwiftUI

/// Audit R11: predictive channel warming, client side. When the server can
/// warm (`features.warming`) and its admin turned "Warm the next channel" on
/// (`warmingEnabled`), the app asks it to start the stream of the channel the
/// viewer is likely to play next, so that play's resolve adopts a stream that
/// is already running. The owner chose a cautious policy:
///
/// - one warm channel at a time (a new target replaces, and cancels, the old);
/// - only while the app is active and no real play is mid-start;
/// - a target must hold for `dwell` first, so focus churn sends nothing;
/// - while watching, the likely channel is re-requested every `refresh`
///   (the server's warm stream lives 90 s from its last request);
/// - fire-and-forget: no errors shown, no retry, failure is a debug log line.
///
/// Callers only report *what is likely* (`setBrowseTarget`, `setPlayerTarget`)
/// and the app's state (`setActive`, `beginStart`, ...); this type owns the
/// single in-flight task and the policy. The clock and the request are
/// injected so the policy is testable without waiting.
struct WarmTarget: Equatable, Sendable {
    let sourceId: Int
    let channelId: String
    /// The channel's durable key, for the audio-encode memory resolve also reads.
    let identityKey: String
}

extension Channel {
    var warmTarget: WarmTarget { WarmTarget(sourceId: sourceId, channelId: rawID, identityKey: identityKey) }
}

@MainActor
final class ChannelWarmer {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    /// Sends one warm request; true when the server warmed it (a 200).
    typealias Send = @MainActor (WarmTarget) async -> Bool

    static let defaultDwell: Duration = .milliseconds(1500)
    static let defaultRefresh: Duration = .seconds(60)
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PigTV", category: "Warming")

    private let dwell: Duration
    private let refresh: Duration
    private let sleep: Sleep
    private let send: Send

    /// The server supports warming and its admin turned it on.
    private(set) var enabled = false
    /// The scene is active (not inactive or backgrounded).
    private(set) var active = true
    /// The player is on screen: its target wins over browsing, and repeats.
    private(set) var playerOpen = false
    private var starting = Set<UUID>()
    private var playerTarget: WarmTarget?
    private var browse: (target: WarmTarget, owner: String)?

    /// What the running task is for (nil: nothing scheduled).
    private(set) var scheduled: WarmTarget?
    private var task: Task<Void, Never>?

    init(dwell: Duration = ChannelWarmer.defaultDwell, refresh: Duration = ChannelWarmer.defaultRefresh,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, send: @escaping Send) {
        self.dwell = dwell
        self.refresh = refresh
        self.sleep = sleep
        self.send = send
    }

    /// A real play is resolving (a started play or a channel change).
    var isStarting: Bool { !starting.isEmpty }

    private var eligible: Bool { enabled && active && !isStarting }
    private var wanted: (target: WarmTarget, repeats: Bool)? {
        if playerOpen { return playerTarget.map { ($0, true) } }
        return browse.map { ($0.target, false) }
    }

    // MARK: Inputs

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value { playerTarget = nil; browse = nil }
        reconcile()
    }

    /// Backgrounding cancels everything and forgets what was focused: the
    /// viewer returns to a fresh screen, and warming never starts by itself.
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value { playerTarget = nil; browse = nil }
        reconcile()
    }

    /// Sport / Home focus. `target` is the focused live channel, or nil when
    /// focus left it; a nil only clears what the same `owner` set, because
    /// two shelves report in an unspecified order when focus moves between them.
    func setBrowseTarget(_ target: WarmTarget?, owner: String) {
        if let target {
            guard browse?.target != target || browse?.owner != owner else { return }
            browse = (target, owner)
        } else {
            guard browse?.owner == owner else { return }
            browse = nil
        }
        reconcile()
    }

    /// The player opened (or changed channel); `target` is the channel the
    /// remote's up/down or "Last channel" is most likely to go to.
    func setPlayerTarget(_ target: WarmTarget?) {
        playerOpen = true
        playerTarget = target
        browse = nil
        reconcile()
    }

    func playerClosed() {
        playerOpen = false
        playerTarget = nil
        starting.removeAll()
        reconcile()
    }

    /// A real play started resolving. Cancels any warm request at once: a warm
    /// must never get in a real play's way. `endStart` (or `playerClosed`) lifts it.
    func beginStart(_ id: UUID) {
        starting.insert(id)
        reconcile()
    }

    func endStart(_ id: UUID) {
        guard starting.remove(id) != nil else { return }
        reconcile()
    }

    // MARK: Policy

    /// Brings the single task in line with the inputs. Unchanged target,
    /// unchanged task: focus onChange handlers may repeat themselves freely.
    private func reconcile() {
        let want = eligible ? wanted : nil
        if want?.target == scheduled, task != nil || want == nil { return }
        task?.cancel()
        task = nil
        scheduled = want?.target
        guard let want else { return }
        let repeats = want.repeats
        task = Task { [weak self] in await self?.run(want.target, repeats: repeats) }
    }

    private func run(_ target: WarmTarget, repeats: Bool) async {
        do {
            try await sleep(dwell)
            while !Task.isCancelled {
                // Re-checked after every wait: the inputs may have moved on
                // in a way that cancel() has not reached yet.
                guard eligible, wanted?.target == target else { return }
                let warmed = await send(target)
                guard warmed, repeats, !Task.isCancelled else {
                    if !warmed { Self.log.debug("warm: not warmed (nothing free, off, or failed)") }
                    return
                }
                try await sleep(refresh)
            }
        } catch {
            // Cancelled while waiting: superseded, backgrounded or a play began.
        }
    }

    // MARK: The player's choice

    /// The channel the player's remote is most likely to go to: the previous
    /// channel when the viewer has just switched (they often flip back),
    /// otherwise the next one up, as `AppModel.zap(1)` would pick it.
    static func likelyNext(current: Channel, previous: Channel?, justSwitched: Bool, list: [Channel]) -> Channel? {
        if justSwitched, let previous, previous.id != current.id { return previous }
        guard !list.isEmpty else { return nil }
        let index = list.firstIndex { $0.id == current.id } ?? -1
        let next = list[(index + 1) % list.count]
        return next.id == current.id ? nil : next
    }
}

private struct ChannelWarmerKey: EnvironmentKey {
    static let defaultValue: ChannelWarmer? = nil
}

extension EnvironmentValues {
    /// The app's warmer; nil in previews and fixtures that never warm.
    var channelWarmer: ChannelWarmer? {
        get { self[ChannelWarmerKey.self] }
        set { self[ChannelWarmerKey.self] = newValue }
    }
}
