import AVFoundation
import Foundation
import OSLog
import QuartzCore

/// Audit R03: signposts for the stages a viewer feels, read in Instruments
/// (os_signpost, subsystem = the bundle id, category "Responsiveness"). Cheap
/// when nothing is recording. Metadata is limited to fixed stage names and
/// small counts; never a token, a full URL or a provider name.
enum PigTVSignpost {
    nonisolated static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "PigTV", category: "Responsiveness")

    /// Starts a named interval; pass the result to `end`.
    nonisolated static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    nonisolated static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    nonisolated static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// An event carrying one short label (a tab name, a logo file name).
    nonisolated static func event(_ name: StaticString, _ label: String) {
        signposter.emitEvent(name, "\(label, privacy: .public)")
    }

    /// Emits `name` once, the first time `player` reports `.playing` (it
    /// watches only while a recording is running, and removes itself).
    nonisolated static func eventWhenPlaying(_ name: StaticString, _ player: AVPlayer) {
        guard signposter.isEnabled else { return }
        final class Box: @unchecked Sendable { var observation: NSKeyValueObservation? }
        let box = Box()
        box.observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable player, _ in
            guard player.timeControlStatus == .playing else { return }
            signposter.emitEvent(name)
            box.observation = nil
        }
    }

    // MARK: Tab selection

    /// One tab selection in flight: selection change → the destination's
    /// first visible content (`onAppear` of its root) → its first frame.
    /// (Focus stays in the tab bar while the remote switches tabs, so the
    /// first content frame stands in for "focus ready".)
    @MainActor private static var tabState: (name: String, state: OSSignpostIntervalState)?
    @MainActor private static var frameLink: FrameTick?

    @MainActor static func tabSelected(_ name: String) {
        guard signposter.isEnabled else { return }
        if let pending = tabState { signposter.endInterval("TabSwitch", pending.state, "superseded") }
        tabState = (name, signposter.beginInterval("TabSwitch", id: signposter.makeSignpostID(), "\(name, privacy: .public)"))
    }

    @MainActor static func tabContentAppeared(_ name: String) {
        guard signposter.isEnabled, let pending = tabState, pending.name == name else { return }
        tabState = nil
        signposter.endInterval("TabSwitch", pending.state, "content")
        let frame = signposter.beginInterval("TabFirstFrame", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        frameLink = FrameTick {
            signposter.endInterval("TabFirstFrame", frame)
            frameLink = nil
        }
    }

    /// One display-link callback, then gone.
    @MainActor private final class FrameTick: NSObject {
        private var link: CADisplayLink?
        private let done: @MainActor () -> Void
        init(_ done: @escaping @MainActor () -> Void) {
            self.done = done
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        @objc private func tick() {
            link?.invalidate()
            link = nil
            done()
        }
    }
}
