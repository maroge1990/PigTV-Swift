import Foundation
#if os(tvOS)
import UIKit
import AVFoundation
import AVKit
#endif

// #35 (Apple 399): the television's display mode (frame rate, SDR/HDR) belongs to the play, not to one player view. A
// channel change replaces the player view (PlayerHost's `.id(playback.id)`), and the view used to reset the mode as it
// left, so the TV dropped to its default mode during "Tuning…" and switched back for the next channel: two HDMI
// resyncs (1-3 s each), even between two 50 Hz channels. Now a channel change hands the mode to the next channel, which
// keeps it while it tunes and asks again only for a different mode; leaving the player, or an error, gives the TV back
// its default mode.

/// The decision, pure (tests drive it). `Criteria` is what was asked of the TV; `Play` names a play.
nonisolated struct DisplayCriteriaHold<Criteria: Equatable, Play: Equatable> {
    enum Action: Equatable {
        case none
        case apply(Criteria)
        case clear
    }

    /// What the TV was last asked for (nil: its default mode).
    private(set) var applied: Criteria?
    /// The play the mode is held for: the one whose view last showed, or the channel a change handed it to.
    private(set) var holder: Play?
    /// The holder was handed the mode by a channel change and has not shown criteria of its own yet.
    private(set) var inherited = false
    /// Plays that handed the mode on: their views leaving, stopping or showing late never touch it again.
    private var retired: [Play] = []

    /// A play's player view is on screen with its item's criteria (nil: none known yet, e.g. the asset's still loading).
    /// Only different criteria are applied. nil from a channel change's next channel, before it has shown criteria of
    /// its own, leaves the previous mode as it is; any other nil is the TV's default mode, as before #35.
    mutating func shown(_ criteria: Criteria?, by play: Play) -> Action {
        guard !retired.contains(play) else { return .none }
        let keeping = holder == play && inherited
        holder = play
        guard let criteria else {
            guard !keeping else { return .none }
            inherited = false
            guard applied != nil else { return .none }
            applied = nil
            return .clear
        }
        inherited = false
        guard criteria != applied else { return .none }
        applied = criteria
        return .apply(criteria)
    }

    /// A channel change: the next channel holds the mode while it tunes.
    mutating func handOver(from old: Play, to new: Play) {
        retired.append(old)
        if retired.count > 8 { retired.removeFirst(retired.count - 8) }
        if holder == old || holder == nil {
            holder = new
            inherited = true
        }
    }

    /// The play was exited, ended in an error or its view left the screen: the TV's default mode, unless the play
    /// handed the mode on (then this is the old channel going and changes nothing).
    mutating func ended(_ play: Play) -> Action {
        guard holder == play else { return .none }
        holder = nil
        inherited = false
        guard applied != nil else { return .none }
        applied = nil
        return .clear
    }
}

#if os(tvOS)
/// Criteria as the display manager sees them: Match Content matches only the frame rate and the dynamic range, so two
/// modes built from resolve answers are the same when those are (whatever the codec or size). Criteria from an asset's
/// own load have no mode and are compared as objects.
nonisolated struct HeldCriteria: Equatable {
    let criteria: AVDisplayCriteria
    let mode: DisplayMode?

    static func == (a: HeldCriteria, b: HeldCriteria) -> Bool {
        if let x = a.mode, let y = b.mode { return x.refreshRate == y.refreshRate && x.range == y.range }
        return a.criteria.isEqual(b.criteria)
    }
}

/// The one holder of the TV's display mode for the player views (live and recordings), across channel changes.
final class TVDisplayModeHold {
    static let shared = TVDisplayModeHold()

    private(set) var hold = DisplayCriteriaHold<HeldCriteria, UUID>()
    /// The window that last showed a player: a play with no view (tuning, an error) still clears the mode there.
    private weak var window: UIWindow?
    /// What reaches the display manager; tests record it instead.
    var setCriteria: (UIWindow, AVDisplayCriteria?) -> Void = { window, criteria in
        window.avDisplayManager.preferredDisplayCriteria = criteria
    }

    init() {}

    func shown(_ criteria: AVDisplayCriteria?, mode: DisplayMode?, by play: UUID, in window: UIWindow) {
        self.window = window
        switch hold.shown(criteria.map { HeldCriteria(criteria: $0, mode: mode) }, by: play) {
        case .apply(let held): setCriteria(window, held.criteria)
        case .clear: setCriteria(window, nil)
        case .none: break
        }
    }

    func handOver(from old: UUID, to new: UUID) {
        hold.handOver(from: old, to: new)
    }

    func ended(_ play: UUID) {
        guard hold.ended(play) == .clear, let window else { return }
        setCriteria(window, nil)
    }

    #if DEBUG
    /// Tests: start from the TV's default mode, nothing held.
    func resetForTesting() {
        hold = DisplayCriteriaHold()
        window = nil
    }
    #endif
}
#endif
