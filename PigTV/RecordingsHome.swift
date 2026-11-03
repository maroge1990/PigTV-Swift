import Foundation

// D-44 batch 5 (Apple 119, R5-Recordings-*): what the Recordings tab draws, as pure functions (RecordingsHomeTests).
// No library: one featured recording across the top, the rest as large cards, and Coming up as a strip whose "All ›"
// opens Scheduled. Only what the feeds supply: no league, no UHD, no rule name on a recording.

nonisolated enum RecordingsHome {
    /// The recordings the tab shows: everything but the failed ones (Scheduled › Needs attention owns those) and the
    /// ones waiting on their Undo (`hidden`, keys from `RecordingsHome.key`). Recording now first, then newest first.
    static func shelf(_ recordings: [Recording], hidden: Set<String> = []) -> [Recording] {
        recordings
            .filter { $0.status != "failed" && !hidden.contains(key($0)) }
            .sorted { lhs, rhs in
                let l = lhs.status == "recording", r = rhs.status == "recording"
                if l != r { return l }
                return (lhs.started_at ?? 0, lhs.id) > (rhs.started_at ?? 0, rhs.id)
            }
    }

    /// The featured recording: the newest partly watched one (Continue), else the newest finished one not yet watched,
    /// else the first of the shelf.
    static func featured(_ shelf: [Recording], progress: (Recording) -> RecordingProgress) -> Recording? {
        if let resume = RecordingsRows.continueWatching(shelf, progress: progress).first { return resume }
        if let fresh = shelf.first(where: { $0.status == "completed" && !progress($0).watched }) { return fresh }
        return shelf.first
    }

    /// The cards under the featured one, in the shelf's order.
    static func cards(_ shelf: [Recording], featured: Recording?) -> [Recording] {
        shelf.filter { $0.id != featured?.id }
    }

    /// Coming up: the schedules still to start (scheduled or waiting), soonest first, without the ones waiting on their
    /// Undo. One recording now is already a card.
    static func comingUp(_ schedules: [ScheduledRecording], hidden: Set<String> = []) -> [ScheduledRecording] {
        schedules
            .filter { ["scheduled", "waiting"].contains($0.status) && !hidden.contains(key($0)) }
            .sorted { ($0.program_start, $0.id) < ($1.program_start, $1.id) }
    }

    /// It clashes (#12): it loses its clash, or another schedule needs its connection.
    static func clashes(_ item: ScheduledRecording) -> Bool {
        item.isBeaten || !(item.conflictsWith ?? []).isEmpty
    }

    /// "Today 10:20 pm", "Tomorrow 9:30 pm", "Tue 9:30 pm" within the week, else "Sat 8 Nov 11:30 pm".
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        return "\(day(date, now: now, calendar: calendar)) \(time)"
    }

    /// "Today", "Tomorrow", "Tue" within the week, else "Sat 8 Nov".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        let startOfToday = calendar.startOfDay(for: now)
        if let week = calendar.date(byAdding: .day, value: 7, to: startOfToday), date >= startOfToday, date < week {
            return date.formatted(style)
        }
        style = style.day().month(.abbreviated)
        return date.formatted(style)
    }

    /// The strip's chip text: "Today 10:20 pm", or "Clash · Sat 8 Nov 11:30 pm".
    static func chip(_ item: ScheduledRecording, now: Date) -> String {
        (clashes(item) ? "Clash · " : "") + when(item.start, now: now)
    }

    /// "Channel · 2 h 05 min", "Channel · from 9:30 pm" while it records, "Channel · 14 min left" when partly watched.
    static func meta(_ item: Recording, progress: RecordingProgress) -> String {
        var parts = [item.channel_name ?? "Channel unavailable"]
        if item.status == "recording", let started = item.started {
            parts.append("from \(started.formatted(date: .omitted, time: .shortened))")
        } else if let fraction = progress.fraction, let duration = item.duration_sec, duration > 0 {
            parts.append("\(DetailText.duration(duration * (1 - fraction))) left")
        } else if let duration = item.duration_sec, duration > 0 {
            parts.append(DetailText.duration(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// The featured kicker: "CONTINUE · SAT 1 NOV", "RECORDING NOW · …", else "RECORDED · …".
    static func kicker(_ item: Recording, progress: RecordingProgress, now: Date) -> String {
        let lead = item.status == "recording" ? "Recording now" : progress.fraction != nil ? "Continue" : "Recorded"
        guard let started = item.started else { return lead.uppercased() }
        let day = DetailText.day(started, now: now)
        let date = ["Today", "Yesterday", "Tomorrow"].contains(day) ? day : started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(lead) · \(date)".uppercased()
    }

    /// The key a recording, schedule or rule is hidden by while its removal waits on the Undo.
    static func key(_ item: Recording) -> String { "recording:\(item.id)" }
    static func key(_ item: ScheduledRecording) -> String { "schedule:\(item.id)" }
    static func key(_ item: RecordingRule) -> String { "rule:\(item.id)" }
}

/// The two teams of a game recording, for its art (D-44: "team logos for sport"). Recordings carry no game id, so the
/// "A v B" title is matched against the Sport data already loaded (C-R cards' competitors; only their cached
/// `/api/logo/` logos); a title naming two sides with no card found draws monogram discs. Pure (RecordingsHomeTests).
nonisolated enum RecordingTeams {
    private static let separators = [" v ", " vs. ", " vs ", " @ "]

    /// The two sides of "AFL: Collingwood v Carlton · Round 3" ("Collingwood", "Carlton"); nil for any other title.
    static func sides(_ title: String) -> (String, String)? {
        var text = title
        if let dot = text.range(of: " · ") { text = String(text[..<dot.lowerBound]) }
        if let colon = text.range(of: ": ") { text = String(text[colon.upperBound...]) }
        for separator in separators {
            let parts = text.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !b.isEmpty, a.count <= 40, b.count <= 40 else { return nil }
            return (a, b)
        }
        return nil
    }

    /// The teams in the title's order, with the logos of the first loaded game whose two competitors are the title's
    /// two sides; without one, the two sides' names (monogram discs). Nil when the title is not "A v B".
    static func match(title: String, games: [SportsGame]) -> [RecordTeam]? {
        guard let (a, b) = sides(title) else { return nil }
        for game in games where game.competitors.count == 2 {
            let names = game.competitors
            if let first = names.first(where: { same($0.name, a) }), let second = names.first(where: { same($0.name, b) }),
               first.id != second.id {
                return [RecordTeam(name: first.name, logo: first.cachedLogo), RecordTeam(name: second.name, logo: second.cachedLogo)]
            }
        }
        return [RecordTeam(name: a), RecordTeam(name: b)]
    }

    /// "Man City" is "Manchester City" when one holds the other, or they share their last word ("Kansas City Chiefs" /
    /// "Chiefs"); case and accents are ignored.
    static func same(_ competitor: String, _ side: String) -> Bool {
        let c = fold(competitor), s = fold(side)
        guard !c.isEmpty, !s.isEmpty else { return false }
        if c == s || c.contains(s) || s.contains(c) { return true }
        guard let cl = c.split(separator: " ").last, let sl = s.split(separator: " ").last, cl.count > 3 else { return false }
        return cl == sl
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

/// A removal committed after its Undo (Apple 124): what to send, for which server and account (`CacheScope.digest`).
nonisolated struct PendingRemoval: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case recording, cancelSchedule, deleteSchedule, rule }
    let kind: Kind
    let id: Int
    let scope: String

    /// The key the lists hide it by (`RecordingsHome.key`).
    var key: String { Self.key(kind, id) }
    var flightKey: String { "\(scope)|\(kind.rawValue)|\(id)" }

    static func key(_ kind: Kind, _ id: Int) -> String {
        switch kind {
        case .recording: "recording:\(id)"
        case .cancelSchedule, .deleteSchedule: "schedule:\(id)"
        case .rule: "rule:\(id)"
        }
    }
}

/// The removals committed and not yet confirmed by the server, kept in UserDefaults so a process killed in the
/// background replays them (Codex 5b round 1, high). `inFlight` is this process's sends, so a replay never sends one twice.
@MainActor
final class PendingRemovalLog {
    static let shared = PendingRemovalLog(defaults: .standard)
    static let storageKey = "pigtv.pendingRemovals.v1"
    private let defaults: UserDefaults
    var inFlight: Set<String> = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    func all() -> [PendingRemoval] {
        defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([PendingRemoval].self, from: $0) } ?? []
    }
    func pending(scope: String) -> [PendingRemoval] { all().filter { $0.scope == scope } }
    func contains(_ op: PendingRemoval) -> Bool { all().contains(op) }
    func add(_ op: PendingRemoval) { var ops = all(); if !ops.contains(op) { ops.append(op) }; save(ops) }
    func remove(_ op: PendingRemoval) { save(all().filter { $0 != op }) }
    private func save(_ ops: [PendingRemoval]) {
        if ops.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let data = try? JSONEncoder().encode(ops) { defaults.set(data, forKey: Self.storageKey) }
    }
}
