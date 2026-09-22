import Foundation

nonisolated struct GuideProgramme: Codable, Equatable, Sendable {
    let title: String
    let description: String?
    let startTime: Double
    let endTime: Double
    var start: Date { Date(timeIntervalSince1970: startTime / 1000) }
    var end: Date { Date(timeIntervalSince1970: endTime / 1000) }
    func isLive(at date: Date) -> Bool { start <= date && date < end }

    init(title: String, description: String?, startTime: Double, endTime: Double) {
        self.title = title.strippingBadgeSuffix()
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Providers append a small-capitals "ᴸɪᴠᴇ" marker to live programmes; it
        // renders as a tacky superscript, so it is stripped on the way in.
        title = (try c.decode(String.self, forKey: .title)).strippingBadgeSuffix()
        description = try c.decodeIfPresent(String.self, forKey: .description)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
    }
}

extension String {
    // Strips a trailing run of phonetic/modifier-letter glyphs (the small-caps
    // "ᴸɪᴠᴇ" / "ɴᴇᴡ" style badges some EPGs append). Real English titles never
    // contain these code points, so nothing legitimate is removed.
    func strippingBadgeSuffix() -> String {
        var scalars = unicodeScalars
        func isBadge(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x1D00...0x1DBF, 0x02B0...0x02FF, 0x0250...0x02AF: return true // small caps / IPA / modifiers
            case 0x20, 0xA0: return true                                        // spaces
            default: return false
            }
        }
        while let last = scalars.last, isBadge(last) { scalars.removeLast() }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

nonisolated struct GuideChannel: Codable, Identifiable, Sendable {
    let rawID: String
    let sourceId: Int
    let name: String
    let logo: String?
    let category: String?
    let programmes: [GuideProgramme]
    var tvgId: String? = nil
    var id: String { "\(sourceId):\(rawID)" }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, logo, category, programmes, tvgId
    }
    // Library categories are keyed by ID; guide rows carry the category as the
    // server stored it, which may be the ID or the display name.
    func matches(_ item: Category) -> Bool {
        sourceId == item.sourceId && (category == item.rawID || category == item.name)
    }
}

nonisolated struct GuidePage: Decodable, Sendable {
    let total: Int
    let channels: [GuideChannel]
}

nonisolated struct ScheduledRecording: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let channel_name: String?
    let program_start: Double
    let program_end: Double
    let status: String
    var start: Date { Date(timeIntervalSince1970: program_start / 1000) }
    var end: Date { Date(timeIntervalSince1970: program_end / 1000) }
    var canCancel: Bool { ["scheduled", "waiting", "recording"].contains(status) }
    var isActive: Bool { canCancel }
    var statusLabel: String { status == "waiting" ? "Waiting — someone is watching" : status.capitalized }
    // Guide cells match schedules by channel name and programme start.
    var guideKey: String { ScheduledRecording.key(channel: channel_name ?? "", start: program_start) }
    static func key(channel: String, start: Double) -> String { "\(channel)|\(Int64(start))" }
}

// On-disk snapshot of the last complete guide load so the app can open with
// yesterday's data while it refreshes.
nonisolated struct GuideCache: Codable, Sendable {
    let savedAt: Date
    let window: Date
    let channels: [GuideChannel]
}

nonisolated struct Recording: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let channel_name: String?
    let started_at: Double?
    let status: String
    let file_size_bytes: Double?
    let duration_sec: Double?
    let is_partial: Int?
    let missed_start_ms: Double?
    let ad_detect_status: String?
    let compress_status: String?
    var started: Date? { started_at.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

nonisolated struct RecordingMarkers: Decodable, Sendable {
    let status: String?
    let markers: [CommercialBreak]
}

nonisolated struct CommercialBreak: Decodable, Identifiable, Sendable {
    let id: Int
    let startMs: Double
    let endMs: Double
    let type: String
    var valid: Bool { startMs.isFinite && endMs.isFinite && startMs >= 0 && endMs > startMs }
}

nonisolated struct ScheduleBody: Encodable, Sendable {
    let sourceId: Int
    let channelItemId: String
    let channelName: String
    let channelLogo: String?
    let title: String
    let description: String?
    let programStart: Double
    let programEnd: Double
    let preBufferMin: Int
    let postBufferMin: Int
}

nonisolated struct FavouriteBody: Encodable, Sendable {
    let sourceId: Int
    let itemId: String
    let itemType = "channel"
}

nonisolated struct FavouriteCheck: Decodable, Sendable {
    let isFavorite: Bool
}

// Timeline geometry clips programmes to the requested window. Missing EPG
// remains a real gap instead of stretching neighbouring programmes over it.
nonisolated enum GuideGeometry {
    static func interval(start: Double, end: Double, window: Double, duration: Double) -> (offset: Double, width: Double)? {
        guard start.isFinite, end.isFinite, window.isFinite, duration.isFinite,
              duration > 0, end > start else { return nil }
        let lower = max(start, window)
        let upper = min(end, window + duration)
        guard upper > lower else { return nil }
        return ((lower - window) / duration, (upper - lower) / duration)
    }
    // Unclamped position of a programme relative to the window start, in
    // window widths; the caller clips. Keeps cell widths constant while the
    // window moves so the grid translates as one piece.
    static func placement(start: Double, end: Double, window: Double, duration: Double) -> (offset: Double, width: Double)? {
        guard start.isFinite, end.isFinite, window.isFinite, duration.isFinite,
              duration > 0, end > start else { return nil }
        return ((start - window) / duration, (end - start) / duration)
    }
}

// The viewport stays short; programme data covers a whole day around it so
// that moving through the guide never waits on the network.
nonisolated enum GuideNavigation {
    static let visibleDuration: TimeInterval = 2 * 3600
    static let step: TimeInterval = 1800
    static let loadedDuration: TimeInterval = 86400
    // Programme data starts this long before the viewport so a few steps back
    // in time do not trigger a reload.
    static let leadIn: TimeInterval = 2 * 3600
    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / step) * step)
    }
    static func programme(in programmes: [GuideProgramme], at time: Date) -> GuideProgramme? {
        programmes.first { $0.start <= time && time < $0.end }
    }
    // Programmes that overlap the visible window, in start order, without
    // duplicate starts (the grid keys cells by start time).
    static func visible(_ programmes: [GuideProgramme], viewport: Date,
                        duration: TimeInterval = visibleDuration) -> [GuideProgramme] {
        let right = viewport.addingTimeInterval(duration)
        var seen = Set<Double>()
        return programmes
            .filter { $0.end > $0.start && $0.end > viewport && $0.start < right && seen.insert($0.startTime).inserted }
            .sorted { $0.start < $1.start }
    }
    // Viewport that shows the programme after a horizontal move. Moving right
    // advances by whole columns until the programme start is on screen; moving
    // left puts the programme start in the first column.
    static func reveal(_ programme: GuideProgramme, from viewport: Date,
                       duration: TimeInterval = visibleDuration) -> Date {
        let right = viewport.addingTimeInterval(duration)
        if programme.start >= right {
            return max(viewport.addingTimeInterval(step), rounded(programme.start).addingTimeInterval(step - duration))
        }
        if programme.end <= viewport { return rounded(programme.start) }
        return viewport
    }
    // Left navigation must reveal the beginning of a clipped programme, not
    // merely notice that its tail is already visible. Live programmes return
    // to the same half-hour baseline used by Now/initial launch.
    static func revealMovingLeft(_ programme: GuideProgramme, from viewport: Date, now: Date) -> Date {
        let baseline = rounded(now)
        if programme.isLive(at: now) { return baseline }
        if programme.start < viewport { return max(baseline, rounded(programme.start)) }
        return viewport
    }
    static func needsReload(viewport: Date, loadedFrom start: Date) -> Bool {
        viewport < start || viewport.addingTimeInterval(visibleDuration) > start.addingTimeInterval(loadedDuration)
    }
}

nonisolated struct EPGSourceSummary: Decodable, Sendable {
    let id: Int
    let type: String
    let enabled: Bool
    enum CodingKeys: String, CodingKey { case id, type, enabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? ((try? values.decode(Int.self, forKey: .enabled)) == 1)
    }
}
nonisolated struct EPGArtworkChannel: Decodable, Sendable {
    let id: String
    let name: String
    let icon: String?
}
nonisolated struct EPGArtworkPage: Decodable, Sendable {
    let channels: [EPGArtworkChannel]
}
// Channel artwork looked up the way the web guide does: by EPG channel ID
// first, then by channel name. Names are normalised so that case, spacing and
// common decorations ("| HD", "(AU)") do not hide an available icon.
nonisolated struct EPGArtworkIndex: Sendable {
    private var byID: [String: String] = [:]
    private var byName: [String: String] = [:]
    var count: Int { byID.count }
    mutating func append(_ channels: [EPGArtworkChannel]) {
        for channel in channels {
            guard let icon = channel.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty,
                  icon.lowercased().hasPrefix("http") || icon.hasPrefix("/") else { continue }
            if byID[channel.id] == nil { byID[channel.id] = icon }
            for key in [Self.normalise(channel.name), Self.normalise(Self.stripDecorations(channel.name))]
            where !key.isEmpty && byName[key] == nil {
                byName[key] = icon
            }
        }
    }
    func logo(tvgID: String?, name: String) -> String? {
        if let tvgID, let icon = byID[tvgID] { return icon }
        let key = Self.normalise(name)
        if let icon = byName[key] { return icon }
        // Strip a trailing quality or region tag, e.g. "ABC News HD" -> "ABC News".
        let stripped = Self.normalise(Self.stripDecorations(name))
        return stripped == key ? nil : byName[stripped]
    }
    static func normalise(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
    static func stripDecorations(_ name: String) -> String {
        var result = name
        for pattern in [#"\s*\(.*?\)"#, #"\s*\[.*?\]"#, #"\s*\|.*$"#, #"\s+(FHD|UHD|4K|HD|SD)\s*$"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}

nonisolated struct RecordingPlayback: Decodable, Sendable {
    let url: String
    let container: String?
    let durationSec: Double?
}
