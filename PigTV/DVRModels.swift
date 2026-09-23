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
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
    }
    // Decoding is synthesised: the small-caps "ᴸɪᴠᴇ" badge is now stripped by
    // the server at ingest (build 0099), so no client cleanup is needed.
}

nonisolated struct GuideChannel: Codable, Identifiable, Sendable {
    let rawID: String
    let sourceId: Int
    let name: String
    let logo: String?
    let category: String?
    let programmes: [GuideProgramme]
    var tvgId: String? = nil
    // Server 0097: reorder-stable identity (see Channel.stableId). Additive.
    var stableId: String? = nil
    var id: String { "\(sourceId):\(rawID)" }
    var identityKey: String { stableId.map { "\(sourceId):s:\($0)" } ?? id }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, logo, category, programmes, tvgId, stableId
    }
    init(rawID: String, sourceId: Int, name: String, logo: String?, category: String?,
         programmes: [GuideProgramme], tvgId: String? = nil, stableId: String? = nil) {
        self.rawID = rawID; self.sourceId = sourceId; self.name = name; self.logo = logo
        self.category = category; self.programmes = programmes; self.tvgId = tvgId; self.stableId = stableId
    }
    // Decoding is synthesised from CodingKeys; the server strips the small-caps
    // badge from names at ingest (0099).
    // Library categories are keyed by ID; guide rows carry the category as the
    // server stored it, which may be the ID or the display name.
    func matches(_ item: Category) -> Bool {
        sourceId == item.sourceId && (category == item.rawID || category == item.name)
    }
}

nonisolated struct GuidePage: Decodable, Sendable {
    let total: Int
    let channels: [GuideChannel]
    // A1.1: cursor paging (server flag `guideCursor`). Absent/null on the last
    // page, and always absent from an older server, which keeps limit/offset.
    var nextCursor: String? = nil
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
    // A1.1: the server's guide version at the time this snapshot completed
    // (server flag `guideVersion`). Decoded tolerantly so a cache file written
    // before this field existed still loads, just without a fast-path check.
    var version: String? = nil
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
    // advances by whole columns until the programme start is at least a column
    // inside the right edge (a start just before a half hour is not left as a
    // sliver); moving left puts the programme start in the first column.
    static func reveal(_ programme: GuideProgramme, from viewport: Date,
                       duration: TimeInterval = visibleDuration) -> Date {
        let right = viewport.addingTimeInterval(duration)
        if programme.start >= right { return revealAhead(programme, from: viewport, duration: duration) }
        if programme.end <= viewport { return rounded(programme.start) }
        return viewport
    }
    // Brings a programme starting at or near the right edge at least one column
    // inside it.
    static func revealAhead(_ programme: GuideProgramme, from viewport: Date,
                            duration: TimeInterval = visibleDuration) -> Date {
        let columnEnd = Date(timeIntervalSince1970: ceil(programme.start.timeIntervalSince1970 / step) * step)
        return max(viewport.addingTimeInterval(step), columnEnd.addingTimeInterval(step - duration))
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
    // A channel's programmes as the grid draws them: valid, one per start
    // time (the first listed, as `visible` keeps), in start order.
    static func ordered(_ programmes: [GuideProgramme]) -> [GuideProgramme] {
        var seen = Set<Double>()
        return programmes.filter { $0.end > $0.start && seen.insert($0.startTime).inserted }
            .sorted { $0.startTime < $1.startTime }
    }
    // The programme a Left/Right step lands on (R19). Duplicate starts and
    // programmes wholly inside the current one are skipped, so a step never
    // "lands" on the cell that is already focused.
    static func neighbour(of startTime: Double, in programmes: [GuideProgramme], forward: Bool) -> GuideProgramme? {
        let drawn = ordered(programmes)
        guard let current = drawn.first(where: { $0.startTime == startTime }) else { return nil }
        if forward {
            return drawn.first { $0.startTime > startTime && $0.endTime > current.endTime }
        }
        return drawn.last { $0.startTime < startTime }
    }
    static func needsReload(viewport: Date, loadedFrom start: Date) -> Bool {
        viewport < start || viewport.addingTimeInterval(visibleDuration) > start.addingTimeInterval(loadedDuration)
    }
    // A1.1: true when a cheap version check (server flag `guideVersion`) shows
    // the already-loaded guide is still current and its loaded window still
    // covers at least the next 12 hours, so a full re-download can be skipped.
    static func guideStillCovers(cachedVersion: String?, serverVersion: String, window: Date, now: Date) -> Bool {
        guard let cachedVersion, cachedVersion == serverVersion else { return false }
        return window.addingTimeInterval(loadedDuration) > now.addingTimeInterval(12 * 3600)
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
