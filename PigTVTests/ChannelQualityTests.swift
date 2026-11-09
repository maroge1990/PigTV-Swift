import XCTest
@testable import PigTV

// #265 (C-X, server 0502): guide rows carry `quality` ("UHD", "FHD", "HD", "SD" or null). The record page shows any label
// once the server advertises `channelQuality`; the guide's channel column shows only UHD and SD; sport channels read
// "FHD" as its own label. Before Apple 189 the guide rows dropped the field, there was no FHD, and a guide programme's
// record page had no badge.
@MainActor
final class ChannelQualityTests: XCTestCase {
    private func browse(quality: Bool) throws -> BrowseModel {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true\#(quality ? #","channelQuality":true"# : "")}}"#.utf8))
        return BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", info: info))
    }

    private func page() throws -> GuidePage {
        try JSONDecoder().decode(GuidePage.self, from: Data(#"{"total":5,"channels":[{"id":"a","sourceId":1,"name":"F1 UHD","programmes":[],"quality":"UHD"},{"id":"b","sourceId":1,"name":"F1 FHD","programmes":[],"quality":"FHD"},{"id":"c","sourceId":1,"name":"F1 HD","programmes":[],"quality":"HD"},{"id":"d","sourceId":1,"name":"F1 SD","programmes":[],"quality":"SD"},{"id":"e","sourceId":1,"name":"News","programmes":[],"quality":null}]}"#.utf8))
    }

    func testGuideRowsDecodeTheirQuality() throws {
        XCTAssertEqual(try page().channels.map(\.quality), ["UHD", "FHD", "HD", "SD", nil])
    }

    func testTheGuideShowsOnlyUHDAndSD() throws {
        let channels = try page().channels
        let on = try browse(quality: true)
        XCTAssertEqual(channels.map { on.guideQuality(of: $0) }, [.uhd, nil, nil, .sd, nil])
        XCTAssertEqual(channels.map { on.quality(of: $0) }, [.uhd, .fhd, .hd, .sd, nil])
        let off = try browse(quality: false)
        XCTAssertNil(off.quality(of: channels[0]), "an older server's (or a stale cache's) label is ignored")
        XCTAssertNil(off.guideQuality(of: channels[0]))
    }

    func testAGuideProgrammesRecordPageCarriesItsChannelsQuality() throws {
        let channel = try page().channels[1]
        let programme = GuideProgramme(title: "Formula 1: Race", description: nil, startTime: 1_000_000, endTime: 5_000_000)
        XCTAssertEqual(try browse(quality: true).recordRequest(channel: channel, programme: programme).airings.first?.quality, .fhd)
    }

    func testSportChannelsReadFHDAsItsOwnLabel() throws {
        let channel = try JSONDecoder().decode(SportEventChannel.self, from: Data(#"{"sourceId":1,"id":"b","name":"F1 FHD","quality":"FHD"}"#.utf8))
        XCTAssertEqual(channel.quality, .fhd)
        XCTAssertEqual(SportQuality.fhd.spoken, "Full HD")
    }

    func testTheCachedGuideKeepsTheLabel() throws {
        let cache = GuideCache(savedAt: Date(timeIntervalSince1970: 0), window: Date(timeIntervalSince1970: 0), channels: [
            GuideChannel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, programmes: [], quality: "UHD")
        ])
        XCTAssertEqual(try JSONDecoder().decode(GuideCache.self, from: JSONEncoder().encode(cache)).channels[0].quality, "UHD")
    }
}
