import XCTest
@testable import PigTV

// D-43 (1 Nov): the Apple TV front page's layout from C-R. `sport-front-0427.json` follows Football (EPL two games live,
// Champions League), Motorsport (F1 only), Basketball (NBA, NBL; nothing on for the account) and Tennis (ATP Tour,
// nothing in 72 hours), with seven follows in the server's order (the two live first). Before Apple 97 the answer's
// `sport` was not read, and the follows were re-sorted ("live first, then soonest").
final class SportFrontLayoutTests: XCTestCase {
    nonisolated static func fixture(_ name: String = "sport-front-0427.json") throws -> Data {
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] where url.lastPathComponent == name {
                return try Data(contentsOf: url)
            }
        }
        throw XCTSkip("\(name) is not in the test bundle")
    }

    static func front(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> SportFront {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        change(&json)
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    /// A game's start as the page words it ("Sun 3:27 pm" in the fixture's zone; the format follows the locale).
    private func when(_ f: SportFront, _ id: String) -> String {
        SportFrontText.when(SportFrontText.date(f.game(id)?.start ?? 0), now: Date(timeIntervalSince1970: f.now / 1000),
                            calendar: calendar)
    }

    func testTheSportFieldsDecode() throws {
        let f = try Self.front()
        XCTAssertEqual(f.sports.map(\.sportName), ["Football", "Football", "Motorsport", "Basketball", "Basketball", "Tennis"])
        XCTAssertEqual(f.rails.map(\.sportName), ["Football", "Football", "Motorsport", "Basketball", "Basketball"])
        XCTAssertEqual(f.follows.count, 7)
        XCTAssertEqual(f.follows[2].sportName, "Motorsport")
        // An older server (0381) sends no `sport`: the league stands in for it.
        let old = try JSONDecoder().decode(SportFront.self, from: SportFrontTests.fixture())
        XCTAssertEqual(old.sports.map(\.sportName), ["F1", "NFL", "NBA", "Cricket"])
        XCTAssertNil(old.rails[0].sport)
    }

    func testRailsAreGroupedBySportInTheOrderSent() throws {
        let f = try Self.front()
        let sections = SportFrontLayout.sections(f)
        XCTAssertEqual(sections.map(\.sport), ["Football", "Motorsport", "Basketball"])
        XCTAssertEqual(sections[0].rails.map(\.league), ["EPL", "Champions League"], "one header, its leagues' rails beneath")
        XCTAssertEqual(sections[2].rails.map(\.league), ["NBA", "NBL"])
        // A rail whose ids match no card is no rail; a sport's first rail decides where its section sits.
        let moved = try Self.front { json in
            var rails = json["rails"] as? [[String: Any]] ?? []
            rails.insert(["league": "NBL", "sport": "Basketball", "gameIds": ["espn:basketball/nbl:1"]], at: 0)
            rails.append(["league": "ATP Tour", "sport": "Tennis", "gameIds": ["espn:tennis/atp:404"]])
            json["rails"] = rails
        }
        XCTAssertEqual(SportFrontLayout.sections(moved).map(\.sport), ["Basketball", "Football", "Motorsport"])
        XCTAssertEqual(SportFrontLayout.alsoInYourSports(moved), ["Tennis"])
    }

    func testSportsWithNoRailAreAlsoInYourSports() throws {
        let f = try Self.front()
        XCTAssertEqual(SportFrontLayout.alsoInYourSports(f), ["Tennis"])
        XCTAssertNil(SportFrontLayout.alsoLine("Tennis", in: f, now: Date(timeIntervalSince1970: f.now / 1000)), "nothing next")
        XCTAssertEqual(SportFrontLayout.sports(f), ["Football", "Motorsport", "Basketball", "Tennis"])
    }

    func testTheBannerListKeepsTheOrderSent() throws {
        // The server's order (playing now first, then the account's) is drawn as sent, never re-sorted (C-R since 0427).
        let f = try Self.front { json in
            var follows = json["follows"] as? [[String: Any]] ?? []
            follows.swapAt(0, 6)
            json["follows"] = follows
        }
        let now = Date(timeIntervalSince1970: f.now / 1000)
        let items = SportFrontLayout.followItems(f, now: now, calendar: calendar)
        XCTAssertEqual(items.map(\.title), ["Alex de Minaur", "Chelsea", "Oscar Piastri", "Arsenal", "Chicago Bulls",
                                            "Sydney Kings", "Liverpool"])
        XCTAssertEqual(items[6].trailing, "LIVE · v Man City")
        XCTAssertTrue(items[6].live)
        XCTAssertEqual(items[2].trailing, "Race · " + when(f, "espn:racing/f1:1"))
        XCTAssertEqual(items[0].trailing, "Nothing in 3 days")
        XCTAssertEqual(items[6].badge?.logo, "/api/logo/espn-liv")
    }

    func testTheHeaderLineAndTheHeroWords() throws {
        let f = try Self.front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        let sections = SportFrontLayout.sections(f)
        XCTAssertEqual(SportFrontLayout.headerLine(sections[0], in: f, now: now, calendar: calendar), "EPL, Champions League · 2 live")
        XCTAssertEqual(SportFrontLayout.headerLine(sections[1], in: f, now: now, calendar: calendar), "F1 · " + when(f, "espn:racing/f1:1"))
        let liverpool = try XCTUnwrap(f.game("espn:soccer/eng.1:1"))
        let hero = SportFrontLayout.hero(liverpool, in: f, hidden: false, now: now, calendar: calendar)
        XCTAssertEqual(hero.kicker, "LIVE · FOOTBALL · EPL · YOUR TEAM")
        XCTAssertTrue(hero.live)
        XCTAssertTrue(hero.line.hasPrefix("1–1 · "), hero.line)
        XCTAssertTrue(hero.line.hasSuffix("Optus Sport 1 HD"), hero.line)
        // Spoiler-free: never a score in the banner.
        let hidden = SportFrontLayout.hero(liverpool, in: f, hidden: true, now: now, calendar: calendar)
        XCTAssertFalse(hidden.line.contains("1–1"), hidden.line)
        XCTAssertTrue(hidden.line.hasSuffix("Optus Sport 1 HD"))
        let unwatched = try XCTUnwrap(f.game("espn:basketball/nbl:1"))
        XCTAssertEqual(SportFrontLayout.hero(unwatched, in: f, hidden: false, now: now, calendar: calendar).line,
                       when(f, "espn:basketball/nbl:1") + " · No TV listing found")
    }

    func testAFollowedCompetitorIsFoundForTheStar() throws {
        let f = try Self.front()
        let nba = try XCTUnwrap(f.game("espn:basketball/nba:1"))
        XCTAssertEqual(SportFrontLayout.followedSide(nba, names: ["Boston Celtics"]), 1, "\"Celtics\" ends the follow's name")
        XCTAssertNil(SportFrontLayout.followedSide(nba, names: ["Chicago Bulls"]))
        XCTAssertEqual(SportFrontLayout.followedSide(try XCTUnwrap(f.game("espn:soccer/eng.1:1")), names: f.follows.map(\.name)), 0)
    }

    func testTheEmptyStatePointsAtSettingsWithFollows() {
        XCTAssertTrue(SportFrontText.followHelp(settings: true).contains("Settings › Sport"))
        XCTAssertTrue(SportFrontText.followHelp(settings: false).contains("web app"))
    }
}
