import Foundation

// Where a recording resumes: the server's per-login position; when that
// request fails, this device's saved position (build 47: keyed by server, account and
// recording - Recording.localResumeKey; never the old `pigtv.resume.<id>`). Before
// playback the viewer is asked: "Resume from H:MM:SS" or "Start over".

/// `GET recordings/{id}/position`. `updated_at` is not needed.
nonisolated struct RecordingPosition: Decodable, Equatable, Sendable {
    let position_sec: Double?
    let watched: Bool?
}

nonisolated enum RecordingResume {
    /// The position and watched flag to consider: the server's answer when it
    /// answered, else the local key (never watched).
    static func source(server: RecordingPosition?, local: Double) -> (position: Double, watched: Bool) {
        if let server { return (server.position_sec ?? 0, server.watched ?? false) }
        return (local, false)
    }

    /// Seconds to offer "Resume from", or nil to just play from the start.
    /// Needs more than 10 s in and not watched.
    /// Whether a start asks the server for the saved position (#345, Codex sign-off): only the ordinary Play can use it;
    /// from the start or the live edge (C-L, #17, and their finished-file fallback, which carries on from 0 or where the
    /// live playlist left off) and from the beginning (a Sport card) never do.
    static func asksPosition(fromStart: Bool, fromLive: Bool, fromBeginning: Bool) -> Bool {
        !fromStart && !fromLive && !fromBeginning
    }

    /// `fromBeginning` (#345): opened from a finished game's Sport card: always from the start, never asked.
    static func prompt(position: Double, watched: Bool, fromBeginning: Bool = false) -> Double? {
        guard !fromBeginning, position.isFinite, position > 10, !watched else { return nil }
        return position
    }

    /// "1:05:09" / "12:03".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Whether a position is worth saving: never 0 or junk from a teardown.
    static func shouldSave(_ seconds: Double) -> Bool { seconds.isFinite && seconds > 0 }

    /// Periodic saves: every 10 s of playback (a rewind earlier than the last
    /// save counts too).
    static func dueForPeriodicSave(now: Double, lastSaved: Double?) -> Bool {
        guard shouldSave(now) else { return false }
        guard let lastSaved else { return true }
        return now - lastSaved >= 10 || now < lastSaved
    }
}

private nonisolated struct PositionBody: Encodable { let position_sec: Double }

extension APIClient {
    func recordingPosition(id: Int) async -> RecordingPosition? {
        guard let reply = try? await response("recordings/\(id)/position", timeout: 5) else { return nil }
        return try? JSONDecoder().decode(RecordingPosition.self, from: reply.data)
    }

    /// Fire-and-forget by design: failures are ignored, the server decides `watched`.
    func saveRecordingPosition(id: Int, seconds: Double) async {
        guard RecordingResume.shouldSave(seconds) else { return }
        _ = try? await response("recordings/\(id)/position", method: "PUT", body: PositionBody(position_sec: seconds), timeout: 8)
    }
}

/// #17: "Play from live" on a recording being made: where it joins its playlist. The last seekable range's end, less the
/// live player's hold (`PlayerSeekWindow.liveOffset`), never before that range's start; nil when nothing is seekable yet.
nonisolated enum RecordingLiveEdge {
    static let title = "Play from live"
    static func target(_ ranges: [(start: Double, end: Double)]) -> Double? {
        guard let last = ranges.last, last.start.isFinite, last.end.isFinite, last.end > last.start else { return nil }
        return PlayerSeekWindow.liveTarget(start: last.start, end: last.end, live: true)
    }
}

/// #335 (D-67): "Go to live" on a recording still being made, played from its live playlist: offered only while the
/// playhead is more than `behind` seconds short of the live point (`RecordingLiveEdge.target`), and it jumps there.
/// For 8 s after the jump "Back to 1:02:03" returns to exactly where the viewer was. Pure (tests `RecordingGoLiveTests`).
nonisolated enum RecordingGoLive {
    static let label = "Go to live"
    /// Its own symbol, apart from Skip break's "forward.end.fill".
    static let icon = "forward.end.circle"
    static let notice = "Jumped to live"
    static let behind: Double = 30
    static let undoSeconds: TimeInterval = 8

    /// Where the viewer was, and until when they can go back there.
    struct Undo: Equatable, Sendable {
        let position: Double
        let until: Date
    }

    /// `watchingLive`: playing the recording's live playlist (it is still being made); `current`: the playhead; `ranges`:
    /// the playlist's seekable ranges.
    /// `noLive` (#345): opened from a finished game's Sport card, where the live edge is the coverage after the game.
    static func available(watchingLive: Bool, current: Double, ranges: [(start: Double, end: Double)], noLive: Bool = false) -> Bool {
        guard !noLive, watchingLive, current.isFinite, let target = RecordingLiveEdge.target(ranges) else { return false }
        return target - current > behind
    }

    /// The jump's target, when it is offered.
    static func target(watchingLive: Bool, current: Double, ranges: [(start: Double, end: Double)], noLive: Bool = false) -> Double? {
        available(watchingLive: watchingLive, current: current, ranges: ranges, noLive: noLive) ? RecordingLiveEdge.target(ranges) : nil
    }

    static func undo(from position: Double, at now: Date) -> Undo {
        Undo(position: position, until: now.addingTimeInterval(undoSeconds))
    }

    /// The position "Back to" returns to, while it is offered (nil after the 8 s).
    static func back(_ undo: Undo?, at now: Date) -> Double? {
        guard let undo, now < undo.until else { return nil }
        return undo.position
    }

    /// "Back to 1:02:03".
    static func backLabel(_ undo: Undo) -> String { "Back to \(RecordingResume.clock(undo.position))" }
}
