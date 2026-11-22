import XCTest
@testable import PigTV

/// maroge1990/PigTV#360 (G8): a guide row's `id` ("sourceId:rawID") is the grid's hot key (its store, every apply's diff,
/// focus restore). It is made once with the row, not rebuilt on every read, and the wire format and the saved guide cache
/// stay exactly as before.
final class GuideChannelIDTests: XCTestCase {
    /// The server's shape (as in the golden `library-guide.json`): nulls, a measured quality, a row without the optional
    /// fields, programmes with fields the app does not model (`isNow`).
    private let page = Data(#"""
    {"total": 3, "channels": [
      {"category": "101", "health": null, "id": "1001", "logo": null, "measured": {"fps": 50, "label": "1080"},
       "name": "##### SKY SPORTS #####", "nameKey": "##### sky sports #####", "number": 1, "programmes": [],
       "quality": null, "sourceId": 1, "stableId": "s1001", "tvgId": null},
      {"category": "105", "health": "flaky", "id": "1019", "logo": "/api/logo/<key>", "measured": {"fps": 25, "label": "720"},
       "name": "AU| ABC NEWS HD", "nameKey": "au| abc news", "number": 2, "quality": "HD", "sourceId": 1,
       "stableId": "s1019", "tvgId": "abcnews.au",
       "programmes": [{"description": "Business Today (S2E6) on ABC News.", "endTime": 1793492700000, "episode": "S2 E6",
                       "isNow": true, "startTime": 1793490900000, "title": "Business Today"},
                      {"description": null, "endTime": 1793496300000, "isNow": false, "startTime": 1793492700000,
                       "title": "Morning News", "liveBroadcast": true, "isNew": false}]},
      {"id": "77", "sourceId": 3, "name": "Plain", "programmes": []}
    ]}
    """#.utf8)

    /// The old GuideChannel's coding, field for field (synthesised from the same CodingKeys, `id` computed): what the
    /// server sent and the cache stored before #360.
    private struct WireChannel: Codable, Equatable {
        let rawID: String
        let sourceId: Int
        let name: String
        let logo: String?
        let category: String?
        let programmes: [GuideProgramme]
        var tvgId: String? = nil
        var stableId: String? = nil
        var number: Int? = nil
        var health: String? = nil
        var quality: String? = nil
        var measured: MeasuredQuality? = nil
        var nameKey: String? = nil
        enum CodingKeys: String, CodingKey {
            case rawID = "id", sourceId, name, logo, category, programmes, tvgId, stableId, number, health, quality, measured, nameKey
        }
    }
    private struct WirePage: Codable { let total: Int; let channels: [WireChannel] }
    private struct WireCache: Codable { let savedAt: Date; let window: Date; let channels: [WireChannel]; var version: String? }

    private func sorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func testTheIDIsStoredNotRebuiltOnEveryRead() throws {
        let decoded = try JSONDecoder().decode(GuidePage.self, from: page).channels[1]
        let made = GuideChannel(rawID: "1019", sourceId: 1, name: "AU| ABC NEWS HD", logo: nil, category: nil, programmes: [])
        for channel in [decoded, made, made.withProgrammes(decoded.programmes)] {
            let stored = Mirror(reflecting: channel).children.first { $0.label == "id" }?.value as? String
            XCTAssertEqual(stored, "1:1019", "the id is a stored property, made once with the row")
            XCTAssertEqual(channel.id, "1:1019")
        }
    }

    func testTheWireFormatAndTheCacheAreUnchanged() throws {
        let channels = try JSONDecoder().decode(GuidePage.self, from: page).channels
        let wire = try JSONDecoder().decode(WirePage.self, from: page).channels
        XCTAssertEqual(channels.map(\.id), ["1:1001", "1:1019", "3:77"])
        XCTAssertEqual(channels.map(\.identityKey), ["1:s:s1001", "1:s:s1019", "3:77"])
        // Every field decodes as before.
        for (channel, old) in zip(channels, wire) {
            XCTAssertEqual(channel.rawID, old.rawID)
            XCTAssertEqual(channel.sourceId, old.sourceId)
            XCTAssertEqual(channel.name, old.name)
            XCTAssertEqual(channel.logo, old.logo)
            XCTAssertEqual(channel.category, old.category)
            XCTAssertEqual(channel.programmes, old.programmes)
            XCTAssertEqual(channel.tvgId, old.tvgId)
            XCTAssertEqual(channel.stableId, old.stableId)
            XCTAssertEqual(channel.number, old.number)
            XCTAssertEqual(channel.health, old.health)
            XCTAssertEqual(channel.quality, old.quality)
            XCTAssertEqual(channel.measured, old.measured)
            XCTAssertEqual(channel.nameKey, old.nameKey)
        }
        // Encoding writes the same bytes as before: no "id" of its own beyond the raw one, nothing added or renamed.
        XCTAssertEqual(String(decoding: try sorted().encode(channels), as: UTF8.self),
                       String(decoding: try sorted().encode(wire), as: UTF8.self))
        // A guide cache saved by the old app loads, ids made, and saves back byte for byte.
        let savedAt = Date(timeIntervalSince1970: 1_793_490_000), window = Date(timeIntervalSince1970: 1_793_489_400)
        let oldCache = try sorted().encode(WireCache(savedAt: savedAt, window: window, channels: wire, version: "v9"))
        let cache = try JSONDecoder().decode(GuideCache.self, from: oldCache)
        XCTAssertEqual(cache.channels.map(\.id), ["1:1001", "1:1019", "3:77"])
        XCTAssertEqual(cache.version, "v9")
        XCTAssertEqual(try sorted().encode(cache), oldCache)
        // And a required field missing still fails the row, as the synthesised decoding did.
        XCTAssertThrowsError(try JSONDecoder().decode(GuideChannel.self, from: Data(#"{"id": "1", "name": "x", "programmes": []}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(WireChannel.self, from: Data(#"{"id": "1", "name": "x", "programmes": []}"#.utf8)))
    }
}
