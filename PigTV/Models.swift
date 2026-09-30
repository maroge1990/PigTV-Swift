import Foundation

struct ServerInfo: Decodable {
    let name: String
    let version: String
    let build: String?
    let display: String?
    var identity: String { display ?? "v\(version)" + (build.map { " · build \($0)" } ?? "") }
    let apiVersion: Int
    let features: Features

    struct Features: Decodable {
        let playbackResolve: Bool?
        let library: Bool?
        let devicePairing: Bool?
        let viewerConflict: Bool?
        let epgLogoFallback: Bool?
        let clientEvents: Bool?
        let scheduledWaiting: Bool?
        let recordingPlaybackPolling: Bool?
        let playbackTerminalStatus: Bool?
        // A1.1: additive guide-refresh contract. Older servers lack these and
        // the client keeps today's offset-paged, always-download behaviour.
        let guideCursor: Bool?
        let guideVersion: Bool?
        let logoCache: Bool?
        // C-A: rows carry a persistent channel `number`, a label only (since
        // server 0139 lists keep the provider's order). C-G: rows carry `health`.
        let channelNumbers: Bool?
        let channelHealth: Bool?
        // C-E (server env PIGTV_TUNER=1): an hours-long live window with
        // program dates (Start over), and HLS recordings that can be watched
        // while still recording.
        let timeshift: Bool?
        let recordingHls: Bool?
        // C-I (server 0147): `GET sports/events` (the Sport tab and Home's
        // "Sport now & next"). C-H's `sportCategories` is no longer read.
        var sportsEvents: Bool? = nil
        // Server 0156: `GET /api/recordings/scheduled?include=recent` also lists
        // missed/failed schedules from the last 7 days, each with `error`.
        let scheduleHistory: Bool?
        // C-J / C-K (multi-provider failover): `providers` = resolve carries a
        // `provider` object; `providerReminders` = `GET providers/reminders`.
        var providers: Bool? = nil
        var providerReminders: Bool? = nil
    }

    func validate() throws {
        guard apiVersion == 1, features.library == true, features.playbackResolve == true else {
            throw PigTVError.message("This server does not support the library and playback APIs required by this app.")
        }
    }
}

struct User: Decodable, Equatable {
    let id: Int
    let username: String
    let role: String
}

struct LoginResponse: Decodable {
    let token: String
    let user: User
}

nonisolated struct Category: Decodable, Hashable, Identifiable, Sendable {
    let rawID: String
    let sourceId: Int
    let name: String
    let channelCount: Int
    /// C-H: an admin marked this category as sport (false when absent).
    var sport = false
    var id: String { "\(sourceId):\(rawID)" }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, channelCount, sport
    }
    init(rawID: String, sourceId: Int, name: String, channelCount: Int, sport: Bool = false) {
        self.rawID = rawID; self.sourceId = sourceId; self.name = name; self.channelCount = channelCount
        self.sport = sport
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try c.decode(String.self, forKey: .rawID)
        sourceId = try c.decode(Int.self, forKey: .sourceId)
        name = try c.decode(String.self, forKey: .name)
        channelCount = (try? c.decode(Int.self, forKey: .channelCount)) ?? 0
        sport = (try? c.decode(Bool.self, forKey: .sport)) ?? false
    }
}

struct Programme: Decodable, Equatable {
    let title: String
    let startTime: Double
    let endTime: Double
    var start: Date { Date(timeIntervalSince1970: startTime / 1_000) }
    var end: Date { Date(timeIntervalSince1970: endTime / 1_000) }
    func progress(at date: Date) -> Double {
        guard endTime > startTime else { return 0 }
        return min(1, max(0, (date.timeIntervalSince1970 * 1_000 - startTime) / (endTime - startTime)))
    }
}

struct Channel: Decodable, Identifiable, Equatable {
    let rawID: String
    let sourceId: Int
    let name: String
    let logo: String?
    let category: String?
    let now: Programme?
    let next: Programme?
    // Server 0097: identity that survives a provider M3U reorder (the plain
    // `id` is position-based and does not). Additive; may be nil on older
    // servers. Prefer it as a durable local key across launches.
    var stableId: String? = nil
    // C-A (server flag `channelNumbers`): the channel's persistent number.
    // Absent/null on older servers and for an unnumbered channel.
    var number: Int? = nil
    // `library/recent`: a watched channel that no longer exists in the
    // playlist comes back with `unavailable: true` (and no logo or EPG).
    var unavailable: Bool? = nil
    var id: String { "\(sourceId):\(rawID)" }
    /// The number as shown ("504"), never locale-grouped.
    var numberText: String? { number.map { String($0) } }
    // Durable local key: the reorder-stable identity when the server sends
    // one, else the position-based id. Also equal for every listing of a
    // channel that appears in several categories.
    var identityKey: String { stableId.map { "\(sourceId):s:\($0)" } ?? id }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, logo, category, now, next, stableId, number, unavailable
    }
}

struct ChannelPage: Decodable {
    let total: Int
    let limit: Int
    let offset: Int
    let channels: [Channel]
}

struct PlaybackDecision: Decodable {
    let strategy: String
    let url: String
    let container: String?
    let sessionId: String?
    let videoMode: String?
    /// The server's analysis of the source (`info` in the resolve answer):
    /// frame rate and HDR range, used for the TV's display mode. Optional and
    /// decoded tolerantly, so an odd or missing `info` never fails a resolve.
    var info: ResolveStreamInfo? = nil
    /// C-J: which provider serves this play. Absent on an older server.
    var provider: ResolveProvider? = nil

    enum CodingKeys: String, CodingKey { case strategy, url, container, sessionId, videoMode, info, provider }

    init(strategy: String, url: String, container: String? = nil, sessionId: String? = nil,
         videoMode: String? = nil, info: ResolveStreamInfo? = nil, provider: ResolveProvider? = nil) {
        self.provider = provider
        self.strategy = strategy
        self.url = url
        self.container = container
        self.sessionId = sessionId
        self.videoMode = videoMode
        self.info = info
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try values.decode(String.self, forKey: .strategy)
        url = try values.decode(String.self, forKey: .url)
        container = try values.decodeIfPresent(String.self, forKey: .container)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
        videoMode = try values.decodeIfPresent(String.self, forKey: .videoMode)
        info = (try? values.decodeIfPresent(ResolveStreamInfo.self, forKey: .info)) ?? nil
        provider = (try? values.decodeIfPresent(ResolveProvider.self, forKey: .provider)) ?? nil
    }
}

/// C-J: the resolve answer's `provider`. Decoded tolerantly (a malformed
/// object is simply absent); only a name is required to be worth showing.
nonisolated struct ResolveProvider: Decodable, Equatable, Sendable {
    var id: Int?
    var name: String
    /// "primary" or "backup".
    var role: String?
    /// "primary", "sibling" or "backup".
    var via: String?
    /// True when this play was moved off the primary provider.
    var failover: Bool

    init(id: Int? = nil, name: String, role: String? = nil, via: String? = nil, failover: Bool = false) {
        self.id = id; self.name = name; self.role = role; self.via = via; self.failover = failover
    }

    enum CodingKeys: String, CodingKey { case id, name, role, via, failover }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = ((try? values.decodeIfPresent(String.self, forKey: .name)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw PigTVError.decoding }
        self.name = String(name.prefix(60))
        id = (try? values.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        role = (try? values.decodeIfPresent(String.self, forKey: .role)) ?? nil
        via = (try? values.decodeIfPresent(String.self, forKey: .via)) ?? nil
        failover = ((try? values.decodeIfPresent(Bool.self, forKey: .failover)) ?? nil) ?? false
    }

    var isBackup: Bool { role == "backup" }

    /// "Trex (backup)" for a backup, the bare name for the primary.
    var label: String { isBackup ? "\(name) (backup)" : name }
}

/// C-K: one provider whose licence is due (or past). `expiresAt` is epoch ms.
nonisolated struct ProviderReminder: Decodable, Equatable, Sendable {
    var id: Int?
    var name: String
    var expiresAt: Double
    var daysLeft: Double?

    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }

    /// Decodes an array, dropping items that are malformed instead of failing
    /// the whole answer.
    static func list(from data: Data) throws -> [ProviderReminder] {
        struct Lossy: Decodable {
            let item: ProviderReminder?
            init(from decoder: Decoder) throws { item = try? ProviderReminder(from: decoder) }
        }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.item)
    }

    enum CodingKeys: String, CodingKey { case id, name, expiresAt, daysLeft }

    init(id: Int? = nil, name: String, expiresAt: Double, daysLeft: Double? = nil) {
        self.id = id; self.name = name; self.expiresAt = expiresAt; self.daysLeft = daysLeft
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PigTVError.decoding }
        self.name = String(name.prefix(60))
        expiresAt = try values.decode(Double.self, forKey: .expiresAt)
        guard expiresAt.isFinite else { throw PigTVError.decoding }
        id = (try? values.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        daysLeft = (try? values.decodeIfPresent(Double.self, forKey: .daysLeft)) ?? nil
    }
}

/// The few `info` fields the client reads. Every field is optional and a
/// field of an unexpected type is simply nil.
nonisolated struct ResolveStreamInfo: Decodable, Equatable, Sendable {
    /// ffprobe's rate as text: "25/1", "30000/1001", "50".
    var fps: String?
    /// "PQ" / "HLG" for an HDR source, null otherwise.
    var videoRange: String?
    /// Codec name ("h264", "hevc").
    var video: String?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey { case fps, videoRange, video, width, height }

    init(fps: String? = nil, videoRange: String? = nil, video: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.fps = fps
        self.videoRange = videoRange
        self.video = video
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fps = (try? values.decodeIfPresent(String.self, forKey: .fps)) ?? nil
        if fps == nil, let number = (try? values.decodeIfPresent(Double.self, forKey: .fps)) ?? nil {
            fps = String(number)
        }
        videoRange = (try? values.decodeIfPresent(String.self, forKey: .videoRange)) ?? nil
        video = (try? values.decodeIfPresent(String.self, forKey: .video)) ?? nil
        width = (try? values.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? values.decodeIfPresent(Int.self, forKey: .height)) ?? nil
    }
}

struct PlaybackTerminalStatus: Decodable {
    let status: String
}

struct PairStart: Decodable {
    let code: String
    let expiresAt: Double
    let expiresInSec: Int
    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1_000) }
}

struct PairPoll: Decodable {
    let status: String
    let token: String?
}

struct LoginBody: Encodable {
    let username: String
    let password: String
}

struct PairBody: Encodable {
    let name: String
    let platform: String
}

struct ResolveBody: Encodable {
    let sourceId: Int
    let channelId: String
    let capabilities: [String: Bool]
    var force = false
    /// Build 27: re-encode only the audio (absent unless true).
    var audioEncode: Bool? = nil
}

enum PigTVError: LocalizedError, Equatable {
    case invalidServerURL
    case unauthorised
    case forbidden
    case http(Int)
    case decoding
    case recordingConflict(RecordingConflict)
    case viewerConflict(message: String)
    case rateLimited(retryAfterSec: Int)
    case recordingPreparationFailed(reason: String?)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter an http or https server address, with an optional port. Paths, credentials and query strings are not supported."
        case .unauthorised: return "Please sign in or pair again. Your credentials were rejected or have expired."
        case .forbidden: return "Your account does not have permission for this action."
        case .http(let status): return "The server returned HTTP \(status). Please try again."
        case .viewerConflict(let message): return message
        case .rateLimited(let seconds): return "Too many attempts — try again in \(max(1, Int(ceil(Double(seconds) / 60)))) minutes."
        case .recordingPreparationFailed(let reason):
            return reason == "file-missing" ? "The recording file is missing from the server's storage." : "The server could not prepare this recording."
        case .recordingConflict: return "A recording is using the provider stream. Confirm before stopping it."
        case .decoding: return "The server returned an unexpected response. Check that PigTV is up to date."
        case .message(let message): return message
        }
    }
}


// Immutable API data must also support Error equality outside the UI actor.
nonisolated struct RecordingConflict: Decodable, Equatable, Sendable {
    let type: String
    let scheduleId: Int
    let title: String
    let channelName: String
    let endsAt: Double
}

struct RecordingPrompt: Decodable, Equatable, Identifiable {
    let scheduleId: Int
    let title: String
    let channelName: String
    let startsAt: Double
    let programEnd: Double
    var id: Int { scheduleId }
}

struct ServerErrorResponse: Decodable {
    let error: String?
    let conflict: PlaybackConflict?
    let retryAfterSec: Int?
    let reason: String?
}

struct DeclineBody: Encodable {
    let scheduleId: Int
}

struct ActionResult: Decodable {
    let success: Bool
}

// Viewer and recording conflicts share an envelope, but not the required fields.
struct PlaybackConflict: Decodable {
    let type: String
    let message: String?
    let scheduleId: Int?
    let title: String?
    let channelName: String?
    let endsAt: Double?
    let streamId: String?
    let lastActiveSec: Double?

    var recording: RecordingConflict? {
        guard type == "recording-in-progress", let scheduleId, let title, let channelName, let endsAt else { return nil }
        return RecordingConflict(type: type, scheduleId: scheduleId, title: title, channelName: channelName, endsAt: endsAt)
    }
}

struct RecordingPreparing: Decodable {
    let status: String
    let retryAfterSec: Double?
}

// A deliberately narrow diagnostics payload: never include arbitrary error text or URLs.
struct PlaybackEvent: Encodable {
    let event: String
    var strategy: String?
    var container: String?
    var videoMode: String?
    var hlsDelivery = true
    var codeName: String?
    var code: Int?
    var message: String?
    var path: String?
    var currentTime: Double?
    var bufferedEnd: Double?
    var resolveMs: Double?
    var totalMs: Double?
    var watchedSec: Double?
    var stalls: Int?
    // A4.2, play-end only: dropped frames over the item and the last access
    // log event's observed bitrate (bits per second). The server's
    // client-event route logs named fields and ignores others.
    var droppedFrames: Int?
    var observedBitrate: Double?
}
