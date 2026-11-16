import XCTest
@testable import PigTV

// D-65/D-67 (#265): every channel the app sees may carry `measured: {label, fps}`; the badge shows it ("4K · 50"), else
// the name's label dashed ("4K", "1080", "HD", "SD"), else nothing. Before this the badge was the name's label only.
@MainActor
final class MeasuredQualityTests: XCTestCase {
    private func sport(_ json: String) throws -> SportEventChannel {
        try JSONDecoder().decode(SportEventChannel.self, from: Data(json.utf8))
    }

    func testEventChannelsDecodeTheirMeasurement() throws {
        let channel = try sport(#"{"sourceId":1,"id":"a","name":"Sky Sports F1","quality":"HD","measured":{"label":"4K","fps":50}}"#)
        XCTAssertEqual(channel.measured, MeasuredQuality(label: .uhd, fps: 50))
        XCTAssertNil(try sport(#"{"sourceId":1,"id":"a","name":"Sky Sports F1"}"#).measured, "absent: unmeasured")
        XCTAssertEqual(try sport(#"{"sourceId":1,"id":"a","name":"X","measured":{"label":"1080","fps":49.94}}"#).measured?.fps, 50)
    }

    func testAMalformedMeasurementNeverDropsTheChannel() throws {
        for bad in [#""4K""#, #"{"label":"8K","fps":50}"#, #"{"fps":50}"#, "null", "[]", #"{"label":7}"#] {
            let channel = try sport(#"{"sourceId":1,"id":"a","name":"X","quality":"SD","measured":\#(bad)}"#)
            XCTAssertNil(channel.measured, bad)
            XCTAssertEqual(channel.chip?.text, "SD", "falls back to the name's label: \(bad)")
        }
        let guide = try JSONDecoder().decode(GuidePage.self, from: Data(#"{"total":2,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[],"measured":"junk"},{"id":"b","sourceId":1,"name":"B","programmes":[],"measured":{"label":"720","fps":25}}]}"#.utf8))
        XCTAssertEqual(guide.channels.count, 2)
        XCTAssertNil(guide.channels[0].measured?.known)
        XCTAssertEqual(guide.channels[1].measured, MeasuredQuality(label: .hd, fps: 25))
        let channel = try JSONDecoder().decode(Channel.self, from: Data(#"{"id":"a","sourceId":1,"name":"A","logo":null,"category":null,"now":null,"next":null,"measured":{"label":"sd","fps":25}}"#.utf8))
        XCTAssertEqual(channel.measured, MeasuredQuality(label: .sd, fps: 25))
    }

    func testTheCachedGuideKeepsTheMeasurement() throws {
        let cache = GuideCache(savedAt: Date(timeIntervalSince1970: 0), window: Date(timeIntervalSince1970: 0), channels: [
            GuideChannel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, programmes: [],
                         measured: MeasuredQuality(label: .uhd, fps: 50))
        ])
        let back = try JSONDecoder().decode(GuideCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(back.channels[0].measured, MeasuredQuality(label: .uhd, fps: 50))
    }

    func testBadgeText() {
        XCTAssertEqual(QualityChip.make(measured: .init(label: .uhd, fps: 50), quality: .sd)?.text, "4K · 50", "measured wins over the name")
        XCTAssertEqual(QualityChip.make(measured: .init(label: .fhd, fps: 25), quality: nil)?.text, "1080 · 25")
        XCTAssertEqual(QualityChip.make(measured: .init(label: .hd, fps: nil), quality: nil)?.text, "720")
        XCTAssertEqual([SportQuality.uhd, .fhd, .hd, .sd].map { QualityChip.make(measured: nil, quality: $0)?.text },
                       ["4K", "1080", "HD", "SD"])
        XCTAssertNil(QualityChip.make(measured: nil, quality: nil), "neither: no badge at all")
        XCTAssertNil(QualityChip.make(measured: .init(label: nil, fps: 50), quality: nil), "an unreadable label is unmeasured")
    }

    func testOnlyMeasured4KTakesTheAccent() {
        XCTAssertEqual(QualityChip.make(measured: .init(label: .uhd, fps: 50), quality: nil)?.accent, true)
        XCTAssertEqual(QualityChip.make(measured: .init(label: .fhd, fps: 50), quality: nil)?.accent, false)
        let named = QualityChip.make(measured: nil, quality: .uhd)
        XCTAssertEqual(named?.accent, false, "unmeasured is dashed, never filled")
        XCTAssertEqual(named?.measured, false)
    }

    func testTheRecordPageCarriesTheMeasurement() throws {
        let channel = SportEventChannel(sourceId: 1, rawID: "a", name: "Sky Sports F1", quality: .hd,
                                        measured: MeasuredQuality(label: .uhd, fps: 50))
        let event = SportEvent(id: "e", title: "F1", league: "F1", startTime: 1_000_000, endTime: 5_000_000, channels: [channel])
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
        let airing = browse.recordRequest(event: event, now: Date(timeIntervalSince1970: 0))?.airings.first
        XCTAssertEqual(airing?.chip?.text, "4K · 50")
    }

    // D-67: the players' tag is the playing channel's measured badge, else the decoded picture's height.
    func testThePlayerTagPrefersTheMeasurement() {
        XCTAssertEqual(PlayerQualityTag.chip(measured: .init(label: .fhd, fps: 50))?.text, "1080 · 50")
        XCTAssertNil(PlayerQualityTag.chip(measured: nil))
        XCTAssertNil(PlayerQualityTag.chip(measured: .init(label: nil, fps: 50)))
        XCTAssertEqual([2160, 1440, 1080, 720, 576, 360, 0].map { PlayerQualityTag.decoded(height: CGFloat($0)) },
                       ["4K", "1440p", "1080p", "720p", "576p", "SD", nil])
    }

    func testAPlayedChannelCarriesItsMeasurement() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
        let event = SportEventChannel(sourceId: 1, rawID: "a", name: "Sky Sports F1", measured: .init(label: .uhd, fps: 50))
        let played = browse.playable(event)
        XCTAssertEqual(played.measured, MeasuredQuality(label: .uhd, fps: 50))
        XCTAssertEqual(browse.measured(for: played), MeasuredQuality(label: .uhd, fps: 50))
        let guide = GuideChannel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, programmes: [],
                                 measured: .init(label: .sd, fps: 25))
        XCTAssertEqual(browse.asChannel(guide).measured, MeasuredQuality(label: .sd, fps: 25))
    }
}
