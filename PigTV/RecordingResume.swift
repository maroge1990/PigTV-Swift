import Foundation

// Where a recording resumes (server 0207 `features.recordingPositions`).
// With the feature the server's per-login position wins; without it, or when
// the request fails, this device's saved position is used (build 47: keyed by server, account and
// recording - Recording.localResumeKey; never the old `pigtv.resume.<id>`). Before
// playback the viewer is asked: "Resume from H:MM:SS" or "Start over".

/// `GET recordings/{id}/position`. `updated_at` is not needed.
nonisolated struct RecordingPosition: Decodable, Equatable, Sendable {
    let position_sec: Double?
    let watched: Bool?
}

nonisolated enum RecordingResume {
    /// The position and watched flag to consider: the server's answer when the
    /// feature is on and it answered, else the local key (never watched).
    static func source(featureOn: Bool, server: RecordingPosition?, local: Double) -> (position: Double, watched: Bool) {
        if featureOn, let server { return (server.position_sec ?? 0, server.watched ?? false) }
        return (local, false)
    }

    /// Seconds to offer "Resume from", or nil to just play from the start.
    /// Needs more than 10 s in and not watched; a local position within 30 s
    /// of the end is not offered (the old rule).
    static func prompt(position: Double, watched: Bool, duration: Double?, featureOn: Bool) -> Double? {
        guard position.isFinite, position > 10, !watched else { return nil }
        if !featureOn, let duration, duration > 0, position >= duration - 30 { return nil }
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
