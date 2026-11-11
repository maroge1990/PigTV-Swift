import Foundation

struct ServerInfo: Decodable {
    let name: String
    /// #47 (Apple 159): optional: /api/info's fallback (a failed feature check) may not know it, and a missing one must
    /// never stop the app restoring its sign-in.
    var version: String? = nil
    let build: String?
    let display: String?
    var identity: String { display ?? (version.map { "v\($0)" } ?? "PigTV") + (build.map { " · build \($0)" } ?? "") }
    let apiVersion: Int
    let features: Features
    /// Audit R11: the admin's "Warm the next channel" setting (absent reads as off).
    var warmingEnabled: Bool? = nil
    /// Predictive warming runs only when the server's admin turned it on (it is off by default and costs a provider
    /// connection).
    var warmingActive: Bool { warmingEnabled == true }

    /// The flags this app decodes. A flag that is `true` on every server from `minimumBuild` on is not asked for
    /// (D-53); decoding ignores it.
    struct Features: Decodable {
        let playbackResolve: Bool?
        let library: Bool?
        let viewerConflict: Bool?
        // C-X (server 0502, #265): guide and channel rows carry `quality` ("UHD", "FHD", "HD", "SD" or null).
        var channelQuality: Bool? = nil
        // C-I (server 0147): `GET sports/events` (the Sport tab and Home's
        // "Sport now & next"). C-H's `sportCategories` is no longer read.
        var sportsEvents: Bool? = nil
        // C-P (server 0340, #21): `GET sports/pages/f1`, the Formula 1 page; 0346 adds
        // `sports/pages/preferences` (a 404 there means device-local defaults).
        var sportPages: Bool? = nil
        // C-Q (server 0379, #21): `GET sports/pages/nfl`, the NFL page, and `following.NFL` in the preferences.
        var sportPageNfl: Bool? = nil
        // C-S (server 0383, #21): `GET sports/pages/cricket`, the Cricket page.
        var sportPageCricket: Bool? = nil
        // C-U (server 0391, #193, D-41; Apple #200): per-account follows (`sports/follows`, `catalog`, `names`,
        // `suggestions`): Settings › Sport.
        var sportFollows: Bool? = nil
        // C-T (server 0388, #21): `GET sports/pages/league/<league>`; an array of the leagues it answers, not a boolean.
        var sportPageLeagues: FeatureList? = nil
        // C-V (server 0428, #197, D-43): `GET sports/pages/events?league=` (tennis, golf, UFC, IndyCar, NASCAR).
        var sportPageEvents: Bool? = nil
        // C-J: `providers` = resolve carries a `provider` object.
        var providers: Bool? = nil
    }

    /// A flag sent as a list of names (`sportPageLeagues`); anything else reads as none, never failing `/api/info`.
    struct FeatureList: Decodable, Equatable {
        let items: [String]
        init(_ items: [String]) { self.items = items }
        init(from decoder: Decoder) throws {
            items = ((try? decoder.singleValueContainer().decode([String].self)) ?? [])
        }
    }

    /// D-53: the oldest server build this app works with (production's, 0476).
    static let minimumBuild = 476

    func validate() throws {
        guard apiVersion == 1, features.library == true, features.playbackResolve == true else {
            throw PigTVError.message("This PigTV server can’t be used by this app. Update PigTV on the server, then try again.")
        }
        // A build that does not parse (a development server, the fallback's null) is accepted.
        if let build, let number = Int(build), number < Self.minimumBuild {
            throw PigTVError.message("This PigTV server is too old for this app. Update the server, then try again.")
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
    // C-A: the channel's persistent number.
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
    /// R11: this play adopted a stream the app warmed earlier. Absent (nil)
    /// on an older server or when nothing was warm.
    var warm: Bool? = nil

    enum CodingKeys: String, CodingKey { case strategy, url, container, sessionId, videoMode, info, provider, warm }

    init(strategy: String, url: String, container: String? = nil, sessionId: String? = nil,
         videoMode: String? = nil, info: ResolveStreamInfo? = nil, provider: ResolveProvider? = nil,
         warm: Bool? = nil) {
        self.warm = warm
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
        warm = (try? values.decodeIfPresent(Bool.self, forKey: .warm)) ?? nil
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

/// R11: the 200 answer of `POST playback/warm` (a 204 means nothing was warmed).
nonisolated struct WarmResult: Decodable, Equatable, Sendable {
    let warm: Bool
    var refreshed: Bool? = nil
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
    /// #147: a sentence the server wrote to be shown, with the HTTP status it came with (which decides whether
    /// retrying can help).
    case serverMessage(String, status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Type the server’s address and its port only, as the PigTV web app shows it."
        case .unauthorised: return "Your sign-in wasn’t accepted. Sign in or pair this device again."
        case .forbidden: return "Your account can’t do this. Ask whoever runs your server."
        case .http: return "Your server didn’t answer as expected. Try again in a moment."
        case .viewerConflict(let message): return message
        case .rateLimited(let seconds): return "Too many attempts — try again in \(max(1, Int(ceil(Double(seconds) / 60)))) minutes."
        case .recordingPreparationFailed(let reason):
            return reason == "file-missing" ? "The recording file is missing from the server's storage." : "The server could not prepare this recording."
        case .recordingConflict: return "Watching this would stop a recording in progress. Choose whether to stop it."
        case .decoding: return "Your server didn’t answer as expected. Check that PigTV on the server is up to date."
        case .message(let message): return message
        case .serverMessage(let message, _): return message
        }
    }
}


/// What to show the person for an error, or nil when there is nothing to say (16 Oct). A request cancelled because the
/// view or task that asked for it went away is not a failure: URLError's text for it is literally "cancelled", which
/// reached the app-wide alert on tvOS and could not be dismissed under a full-screen cover. Every catch that shows an
/// error goes through this.
nonisolated enum UserMessage {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// #280: what reaches the screen is a sentence written for people: the app's own words for its errors, or a
    /// sentence the server wrote to be shown. Never the system's description, an error domain, a code or a status.
    static func text(for error: Error) -> String? { text(for: error, otherwise: somethingFailed) }

    /// The same, with `plain` (what could not be done) for an error that carries no sentence of its own.
    static func text(for error: Error, otherwise plain: String) -> String? {
        if isCancellation(error) { return nil }
        if let pig = error as? PigTVError { return pig.errorDescription ?? plain }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return unreachable }
        return plain
    }

    /// The server could not be reached (any network failure).
    static let unreachable = "This device can’t reach your server. Check that it’s on your home network or connected to it, then try again."
    /// An error with no words of its own.
    static let somethingFailed = "That didn’t work. Try again in a moment."
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
    // R11, play-start: true when the resolve adopted a warmed stream (absent
    // otherwise, so the server can compare warm and cold start times).
    var warm: Bool?
    // #6, start-timeout only: how long nothing played.
    var waitedSec: Double?
    // D-39 (Apple 89): which tab the play was started from ("sport-front", "tv", "guide"); absent when unknown. The
    // server's client-event route ignores fields it does not log.
    var origin: String?
    // #36 (Apple 174, server 0487), play-start only: where the start went, ms since the play began.
    var phases: StartPhases?
}

/// #36: a play's start, step by step (ms since the play began; each optional): the server's answer, the item ready to
/// play (playlist and first segments fetched), the television's display-mode switch done (only when one happened), the
/// first picture.
nonisolated struct StartPhases: Encodable, Equatable, Sendable {
    var resolveMs: Double?
    var readyMs: Double?
    var modeMs: Double?
    var frameMs: Double?
}
