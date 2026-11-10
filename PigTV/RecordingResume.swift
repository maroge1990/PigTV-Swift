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
    static func prompt(position: Double, watched: Bool) -> Double? {
        guard position.isFinite, position > 10, !watched else { return nil }
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
