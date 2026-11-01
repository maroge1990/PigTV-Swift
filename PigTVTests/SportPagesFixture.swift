import XCTest
@testable import PigTV

/// `sport-pages-d43.json` (Apple 99, made from the server's golden answers by the batch's fixture script): one front page
/// (C-R) with Motorsport (F1, NASCAR), Australian football (AFL), Cricket (International (men) and WBBL), Combat (UFC),
/// Tennis (WTA Tour) and Golf (PGA Tour), and each league's page (C-T, C-S, C-V), all around `now` (1 Nov 2026 08:10 UTC).
enum SportPagesFixture {
    static let now = Date(timeIntervalSince1970: 1_793_525_400)

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SportFrontLayoutTests.fixture("sport-pages-d43.json")) as? [String: Any])
    }

    static func part<T: Decodable>(_ path: [String], change: (inout [String: Any]) -> Void = { _ in }) throws -> T {
        var value: Any = try json()
        for key in path { value = try XCTUnwrap((value as? [String: Any])?[key], "no \(key)") }
        var dict = try XCTUnwrap(value as? [String: Any])
        change(&dict)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    static func front() throws -> SportFront { try part(["front"]) }
    static func events(_ league: String, change: (inout [String: Any]) -> Void = { _ in }) throws -> SportEventsPage {
        try part(["events", league], change: change)
    }
}
