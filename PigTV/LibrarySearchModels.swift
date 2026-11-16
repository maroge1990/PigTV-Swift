import Foundation

/// One programme found: keyed by the channel's id and the programme's start (stable across refreshes).
nonisolated struct GuideSearchHit: Identifiable, Equatable, Sendable {
    let channel: GuideChannel
    let programme: GuideProgramme
    var id: String { "\(channel.id)|\(programme.startTime)" }
    static func == (a: GuideSearchHit, b: GuideSearchHit) -> Bool { a.id == b.id && a.programme == b.programme }
}

// #57 (Apple half, D-66): Search asks the server (`GET /api/library/search?q=&limit=20`) for teams, games, programmes,
// channels and recordings, debounced and with stale requests cancelled. A server without the endpoint (404: older than
// the index) is searched as before, through the loaded guide (`GuideSearch`). Everything decodes leniently: a row that
// does not decode is skipped, never the whole answer.

/// A team the search found (`teams[]`).
nonisolated struct LibrarySearchTeam: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let league: String
    let logo: String?
    let followed: Bool

    init(id: String, name: String, league: String, logo: String? = nil, followed: Bool = false) {
        self.id = id; self.name = name; self.league = league; self.logo = logo; self.followed = followed
    }

    enum CodingKeys: String, CodingKey { case id, name, league, logo, followed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = LibrarySearchDecoding.string(c, .id) ?? name
        league = LibrarySearchDecoding.string(c, .league) ?? ""
        logo = LibrarySearchDecoding.string(c, .logo)
        followed = (try? c.decodeIfPresent(Bool.self, forKey: .followed)) ?? false
    }

    /// Only a same-server cached logo (as a Sport card's).
    var cachedLogo: String? {
        logo.flatMap { $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil }
    }
}

/// The search's answer. Every list is optional on the wire.
nonisolated struct LibrarySearchResponse: Decodable, Sendable {
    var q: String
    var channels: [GuideChannel]
    var programmes: [GuideSearchHit]
    var events: [SportEvent]
    var teams: [LibrarySearchTeam]
    var recordings: [Recording]

    init(q: String, channels: [GuideChannel] = [], programmes: [GuideSearchHit] = [], events: [SportEvent] = [],
         teams: [LibrarySearchTeam] = [], recordings: [Recording] = []) {
        self.q = q; self.channels = channels; self.programmes = programmes; self.events = events
        self.teams = teams; self.recordings = recordings
    }

    enum CodingKeys: String, CodingKey { case q, channels, programmes, events, teams, recordings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        q = LibrarySearchDecoding.string(c, .q) ?? ""
        channels = LibrarySearchDecoding.list(c, .channels, of: SearchChannelRow.self).map(\.channel)
        programmes = LibrarySearchDecoding.list(c, .programmes, of: SearchProgrammeRow.self).map(\.hit)
        events = LibrarySearchDecoding.list(c, .events, of: SportEvent.self)
        teams = LibrarySearchDecoding.list(c, .teams, of: LibrarySearchTeam.self)
        recordings = LibrarySearchDecoding.list(c, .recordings, of: Recording.self)
    }
}

/// A guide channel row as the search sends it: its programmes may be left out.
nonisolated struct SearchChannelRow: Decodable, Sendable {
    let channel: GuideChannel

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GuideChannel.CodingKeys.self)
        guard let id = LibrarySearchDecoding.string(c, .rawID) else {
            throw DecodingError.keyNotFound(GuideChannel.CodingKeys.rawID, .init(codingPath: c.codingPath, debugDescription: "no id"))
        }
        channel = GuideChannel(
            rawID: id, sourceId: try c.decode(Int.self, forKey: .sourceId), name: try c.decode(String.self, forKey: .name),
            logo: LibrarySearchDecoding.string(c, .logo), category: LibrarySearchDecoding.string(c, .category),
            programmes: LibrarySearchDecoding.list(c, .programmes, of: GuideProgramme.self),
            tvgId: LibrarySearchDecoding.string(c, .tvgId), stableId: LibrarySearchDecoding.string(c, .stableId),
            number: (try? c.decodeIfPresent(Int.self, forKey: .number)) ?? nil,
            health: LibrarySearchDecoding.string(c, .health), quality: LibrarySearchDecoding.string(c, .quality))
    }
}

/// `programmes[]`: `{ channel: <guide channel row>, title, subtitle?, episode?, start, end, live?, new?, image? }`.
/// `start` and `end` are milliseconds since 1970 (as the sport events' and the guide's).
nonisolated struct SearchProgrammeRow: Decodable, Sendable {
    let hit: GuideSearchHit

    enum CodingKeys: String, CodingKey { case channel, title, description, subtitle, episode, start, end, live, new, image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try c.decode(SearchChannelRow.self, forKey: .channel).channel
        let start = try c.decode(Double.self, forKey: .start)
        let end = try c.decode(Double.self, forKey: .end)
        guard end > start else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "ends before it starts")
        }
        let programme = GuideProgramme(
            title: try c.decode(String.self, forKey: .title), description: LibrarySearchDecoding.string(c, .description),
            startTime: start, endTime: end,
            liveBroadcast: (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? nil,
            isNew: (try? c.decodeIfPresent(Bool.self, forKey: .new)) ?? nil,
            subtitle: LibrarySearchDecoding.string(c, .subtitle), episode: LibrarySearchDecoding.string(c, .episode),
            image: LibrarySearchDecoding.string(c, .image))
        // The guide's own copy of the programme, when it is loaded, has the same start; the row's fields win.
        hit = GuideSearchHit(channel: channel, programme: programme)
    }
}

nonisolated enum LibrarySearchDecoding {
    /// A trimmed, non-empty string; a number is read as its digits (ids); anything else is nil.
    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let text = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return String(number) }
        return nil
    }

    /// The rows that decode; a missing or odd list is empty.
    static func list<K: CodingKey, T: Decodable & Sendable>(_ c: KeyedDecodingContainer<K>, _ key: K, of type: T.Type) -> [T] {
        ((try? c.decodeIfPresent(LossyList<T>.self, forKey: key)) ?? nil)?.items ?? []
    }
}
