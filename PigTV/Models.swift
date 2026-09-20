import Foundation

struct ServerInfo: Decodable {
    let name: String
    let version: String
    let apiVersion: Int
    let features: Features

    struct Features: Decodable {
        let playbackResolve: Bool?
        let library: Bool?
        let devicePairing: Bool?
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

struct Category: Decodable, Hashable, Identifiable {
    let rawID: String
    let sourceId: Int
    let name: String
    let channelCount: Int
    var id: String { "\(sourceId):\(rawID)" }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, channelCount
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
    var id: String { "\(sourceId):\(rawID)" }
    enum CodingKeys: String, CodingKey {
        case rawID = "id", sourceId, name, logo, category, now, next
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
}

enum PigTVError: LocalizedError, Equatable {
    case invalidServerURL
    case unauthorised
    case forbidden
    case http(Int)
    case decoding
    case recordingConflict(RecordingConflict)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter an http or https server address, with an optional port. Paths, credentials and query strings are not supported."
        case .unauthorised: return "Please sign in or pair again. Your credentials were rejected or have expired."
        case .forbidden: return "Your account does not have permission for this action."
        case .http(let status): return "The server returned HTTP \(status). Please try again."
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
    let conflict: RecordingConflict?
}

struct DeclineBody: Encodable {
    let scheduleId: Int
}

struct ActionResult: Decodable {
    let success: Bool
}
