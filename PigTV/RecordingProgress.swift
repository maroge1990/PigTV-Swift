import Foundation

// Resume position and watched state of a recording, in one place for the
// Recordings page and its cards: the server's per-login values on the
// recordings list (`position_sec`, `watched`).

nonisolated struct RecordingProgress: Equatable, Sendable {
    /// 0...1 of a partly watched recording, or nil (not started, finished or live).
    var fraction: Double?
    var watched: Bool
    static let none = RecordingProgress(fraction: nil, watched: false)
}

nonisolated extension Recording {
    func progress() -> RecordingProgress {
        guard status == "completed" else { return .none }
        if watched ?? false { return RecordingProgress(fraction: nil, watched: true) }
        return RecordingProgress(fraction: Recording.resumeFraction(position: position_sec ?? 0, duration: duration_sec), watched: false)
    }

    /// 0…1 of a recording already watched (the player's resume point), or nil when nothing useful is remembered.
    static func resumeFraction(position: Double, duration: Double?) -> Double? {
        guard let duration, duration > 0, position > 10, position < duration - 30 else { return nil }
        return min(1, position / duration)
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
}
