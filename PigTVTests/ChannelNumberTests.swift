import XCTest
@testable import PigTV

// C-A: channel numbers are decoded when present, shown only when the server
// advertises `channelNumbers`, and iOS "Go to number" looks a number up in the
// zap list first, then the guide.
@MainActor
final class ChannelNumberTests: XCTestCase {
    private func info(_ features: String) throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true\#(features)}}"#.utf8))
    }

    private func browse(numbers: Bool) throws -> BrowseModel {
        let model = BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            info: try info(numbers ? #","channelNumbers":true"# : "")))
        model.guide = [
            GuideChannel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, programmes: [], number: 1),
            GuideChannel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, programmes: [], number: 504),
            GuideChannel(rawID: "c", sourceId: 1, name: "C", logo: nil, category: nil, programmes: [])
        ]
        return model
    }

    func testNumbersDecodeAndAreOptional() throws {
        let guide = try JSONDecoder().decode(GuidePage.self, from: Data(#"{"total":2,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[],"number":504},{"id":"b","sourceId":1,"name":"B","programmes":[],"number":null},{"id":"c","sourceId":1,"name":"C","programmes":[]}]}"#.utf8))
        XCTAssertEqual(guide.channels.map(\.number), [504, nil, nil])
        XCTAssertEqual(guide.channels[0].numberText, "504")
        let page = try JSONDecoder().decode(ChannelPage.self, from: Data(#"{"total":1,"limit":50,"offset":0,"channels":[{"id":"7","sourceId":2,"name":"N","logo":null,"category":null,"now":null,"next":null,"number":1004}]}"#.utf8))
        XCTAssertEqual(page.channels[0].number, 1004)
        XCTAssertEqual(page.channels[0].numberText, "1004", "Numbers are never locale-grouped")
        let modern = try info(#","channelNumbers":true,"channelHealth":true"#)
        XCTAssertEqual(modern.features.channelNumbers, true)
        XCTAssertEqual(modern.features.channelHealth, true)
        let old = try info("")
        XCTAssertNil(old.features.channelNumbers)
        XCTAssertNil(old.features.channelHealth)
    }

    func testNumbersAreShownOnlyWithTheFlag() throws {
        let on = try browse(numbers: true)
        XCTAssertEqual(on.number(for: on.guide[1]), 504)
        XCTAssertEqual(on.asChannel(on.guide[1]).number, 504, "Player channels carry the number")
        let off = try browse(numbers: false)
        XCTAssertNil(off.number(for: off.guide[1]), "An older server (or a stale cache) shows no numbers")
        XCTAssertNil(off.asChannel(off.guide[1]).number)
    }

    func testGoToNumberPrefersZapListThenGuide() throws {
        let browse = try browse(numbers: true)
        let app = AppModel()
        app.configureClientForTesting(browse.client, browse: browse)
        let a = browse.asChannel(browse.guide[0])
        app.beginPlayback(a)
        // A zap-list entry wins over a guide row with the same number.
        let zapped = Channel(rawID: "z", sourceId: 2, name: "Z", logo: nil, category: nil, now: nil, next: nil, number: 504)
        app.zapList = [a, zapped]
        XCTAssertEqual(app.channel(number: 504)?.id, zapped.id)
        // Not in the zap list: falls back to the guide.
        app.zapList = [a]
        XCTAssertEqual(app.channel(number: 504)?.id, "1:b")
        XCTAssertNil(app.channel(number: 999))

        XCTAssertTrue(app.goToChannel(numberText: " 504 "))
        XCTAssertEqual(app.playback?.channel.id, "1:b")
        XCTAssertFalse(app.goToChannel(numberText: "999"), "An unknown number does not switch")
        XCTAssertFalse(app.goToChannel(numberText: "abc"))
        XCTAssertFalse(app.goToChannel(numberText: "0"))
        XCTAssertEqual(app.playback?.channel.id, "1:b")
    }

    func testGoToNumberNeedsTheFlagForGuideLookup() throws {
        let browse = try browse(numbers: false)
        let app = AppModel()
        app.configureClientForTesting(browse.client, browse: browse)
        app.beginPlayback(browse.asChannel(browse.guide[0]))
        XCTAssertNil(app.channel(number: 504))
        XCTAssertFalse(app.goToChannel(numberText: "504"))
    }
}
