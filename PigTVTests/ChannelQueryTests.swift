import XCTest
@testable import PigTV

// A4.5: the Siri "Play channel" entity query's matching.
final class ChannelQueryTests: XCTestCase {
    private let entries: [ChannelDirectory.Entry] = [
        .init(id: "1", sourceId: 1, name: "Fox Footy", number: 503),
        .init(id: "2", sourceId: 1, name: "Fox Sports 505", number: 505),
        .init(id: "3", sourceId: 1, name: "Sky Sports Main Event", number: 401),
        .init(id: "4", sourceId: 2, name: "Télé Sports", number: nil),
        .init(id: "5", sourceId: 1, name: "ABC", number: 2),
        .init(id: "6", sourceId: 1, name: "ABC Kids", number: 22),
        .init(id: "7", sourceId: 1, name: "Nick ABC Jr", number: 23)
    ]

    private func names(_ text: String) -> [String] { ChannelDirectory.match(text, in: entries).map(\.name) }

    func testNumbersMatchExactly() {
        XCTAssertEqual(names("503"), ["Fox Footy"])
        XCTAssertEqual(names("channel 22"), ["ABC Kids"])
        XCTAssertEqual(names(" Number 401 "), ["Sky Sports Main Event"])
        XCTAssertEqual(names("999"), [])
    }

    func testNamesRankEqualThenPrefixThenContains() {
        XCTAssertEqual(names("abc"), ["ABC", "ABC Kids", "Nick ABC Jr"])
        XCTAssertEqual(names("FOX"), ["Fox Footy", "Fox Sports 505"])
        XCTAssertEqual(names("tele sports"), ["Télé Sports"], "accents and case are ignored")
        XCTAssertEqual(names("sky  main"), ["Sky Sports Main Event"], "every word, in any position")
        XCTAssertEqual(names("fox footy"), ["Fox Footy"])
        XCTAssertEqual(names("  "), [])
        XCTAssertEqual(names("cnn"), [])
    }

    func testDuplicatesAndLimit() {
        let doubled = entries + [entries[0]]
        XCTAssertEqual(ChannelDirectory.match("fox footy", in: doubled).count, 1)
        XCTAssertEqual(ChannelDirectory.match("a", in: entries, limit: 2).count, 2)
    }

    func testEntryTitlesAndKeys() {
        XCTAssertEqual(entries[0].title, "503 Fox Footy")
        XCTAssertEqual(entries[3].title, "Télé Sports")
        XCTAssertEqual(entries[3].key, "2:4")
        let decoded = try? JSONDecoder().decode(ChannelDirectory.self,
                                                from: JSONEncoder().encode(ChannelDirectory(channels: entries)))
        XCTAssertEqual(decoded?.channels, entries)
    }
}
