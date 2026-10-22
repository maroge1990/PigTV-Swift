import Foundation

// Resume position and watched state of a recording, in one place for the
// Recordings page and Home. With server 0207 (`features.recordingPositions`)
// the server's per-login values are used; an older server has none (or the
// request failed), so the player's saved position on this device is the source.
// A1 (build 47): that key is scoped to the server and account the recording
// belongs to (`pigtv.resume.<scope>.<id>`), because recording ids are per
// server: recording 42 on one server or login must never resume another's.
// The old unscoped `pigtv.resume.<id>` keys cannot say whose they were and are
// deleted, never read.

nonisolated struct RecordingProgress: Equatable, Sendable {
    /// 0...1 of a partly watched recording, or nil (not started, finished or live).
    var fraction: Double?
    var watched: Bool
    static let none = RecordingProgress(fraction: nil, watched: false)
}

nonisolated extension Recording {
    /// `serverPositions`: the server advertises `recordingPositions`. `local`
    /// reads the saved position (seconds) for an id on this device.
    func progress(serverPositions: Bool, local: (Int) -> Double) -> RecordingProgress {
        guard status == "completed" else { return .none }
        let position: Double
        let watched: Bool
        if serverPositions {
            position = position_sec ?? 0
            watched = self.watched ?? false
        } else {
            position = local(id)
            watched = Recording.finished(position: position, duration: duration_sec)
        }
        if watched { return RecordingProgress(fraction: nil, watched: true) }
        return RecordingProgress(fraction: HomeRows.resumeFraction(position: position, duration: duration_sec), watched: false)
    }

    /// A device-local position within 30 s of the end counts as watched
    /// (the same margin `HomeRows.resumeFraction` uses to stop resuming).
    static func finished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position > 10 && position >= duration - 30
    }
}

/// What the Recordings page lists, as pure functions (`RecordingsRowsTests`).
nonisolated enum RecordingsRows {
    /// Review F6: how often the Recordings page refreshes itself while it is on screen (it stops when it isn't).
    /// Often while something is changing (a recording running or due within five minutes, or a file being
    /// prepared, analysed or compressed), rarely otherwise. The TV has no pull-to-refresh.
    static let busyRefresh: TimeInterval = 15
    static let idleRefresh: TimeInterval = 60

    static func refreshInterval(recordings: [Recording], schedules: [ScheduledRecording], now: Date) -> TimeInterval {
        let soon = now.addingTimeInterval(5 * 60)
        let changingSchedule = schedules.contains { item in
            ["recording", "waiting"].contains(item.status)
                || (item.status == "scheduled" && item.start <= soon)
        }
        let changingFile = recordings.contains { item in
            item.status == "recording"
                || ["pending", "preparing"].contains(item.native_status ?? "")
                || ["pending", "running"].contains(item.ad_detect_status ?? "")
                || ["pending", "running"].contains(item.compress_status ?? "")
        }
        return changingSchedule || changingFile ? busyRefresh : idleRefresh
    }

    /// Partly watched, newest first.
    static func continueWatching(_ recordings: [Recording], progress: (Recording) -> RecordingProgress) -> [Recording] {
        recordings
            .filter { $0.status == "completed" && progress($0).fraction != nil }
            .sorted { ($0.started_at ?? 0, $0.id) > ($1.started_at ?? 0, $1.id) }
    }

    /// Failed recordings that are not the other half of a listed problem
    /// schedule (those are counted once, as the schedule).
    static func failedRecordings(_ recordings: [Recording], schedules: [ScheduledRecording]) -> [Recording] {
        let covered = Set(problemSchedules(schedules).map(\.id))
        return recordings.filter { $0.status == "failed" && !($0.scheduled_id.map(covered.contains) ?? false) }
    }

    static func problemSchedules(_ schedules: [ScheduledRecording]) -> [ScheduledRecording] {
        schedules.filter { ["missed", "failed"].contains($0.status) }
    }

    /// "1 recording failed", "3 recordings failed", or, when some were only
    /// missed, "2 recordings failed or were missed". Nil when there are none.
    static func attentionTitle(failedSchedules: Int, missedSchedules: Int, failedRecordings: Int) -> String? {
        let total = failedSchedules + missedSchedules + failedRecordings
        guard total > 0 else { return nil }
        let noun = total == 1 ? "recording" : "recordings"
        if missedSchedules == 0 { return "\(total) \(noun) failed" }
        return "\(total) \(noun) failed or \(total == 1 ? "was" : "were") missed"
    }
}
