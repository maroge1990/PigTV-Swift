import Foundation
#if canImport(PigTV)
@testable import PigTV
#endif

// #52 (the Apple half): the server's golden API answers (`../PigTV/test/golden`, made by its contract-golden test from the
// real handlers) decoded with the client's own models, so a shape the client cannot decode fails here as well as there.
// The folder is found beside this repository (`../PigTV/test/golden`) or at PIGTV_GOLDEN_DIR; without it the checks are
// skipped with a note (CI checks out this repository alone). Each file whose shape the client models is decoded with
// the model the app uses for that route, and a few of its values are read back.

private struct GoldenFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum GoldenChecks {
    /// The files the client models (by name, without `.json`), and the ones it does not, with why.
    static let notModelled: [String: String] = [
        "info-fallback": "no `version`: ServerInfo requires it (the client rejects this answer; reported to the lead)",
        "playback-resolve-200": "resolve is decoded by the playback path's own tests (RealPlaybackTests)",
        "playback-resolve-404": "an error body, read as text (C-B)",
        "playback-resolve-409": "the conflict body, read by the playback path",
        "playback-resolve-error": "an error body, read as text (C-B)",
        "recordings-watch-409": "an error body",
        "sports-page-events-400": "an error body",
    ]

    static func folder() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let fromEnv = (env["PIGTV_GOLDEN_DIR"] ?? env["SIMULATOR_PIGTV_GOLDEN_DIR"]).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PigTV/test/golden")
        for candidate in [fromEnv, beside].compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("routes.json").path) {
            return candidate
        }
        return nil
    }

    /// Runs the checks; returns how many passed (0 and a printed note when the folder is not there).
    static func run() throws -> Int {
        guard let dir = folder() else {
            print("Golden answers not found (../PigTV/test/golden or PIGTV_GOLDEN_DIR): golden decode checks skipped.")
            return 0
        }
        var count = 0
        func data(_ name: String) throws -> Data {
            do { return try Data(contentsOf: dir.appendingPathComponent("\(name).json")) }
            catch { throw GoldenFailure(description: "golden \(name).json is missing") }
        }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            do { let value = try JSONDecoder().decode(T.self, from: data(name)); count += 1; return value }
            catch let failure as GoldenFailure { throw failure }
            catch { throw GoldenFailure(description: "golden \(name).json does not decode as \(T.self): \(error)") }
        }
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw GoldenFailure(description: "golden: \(message)") }
            count += 1
        }

        // Every file routes.json lists is either decoded below or named in `notModelled`.
        let routes = try JSONSerialization.jsonObject(with: data("routes")) as? [String: Any] ?? [:]
        var decoded: Set<String> = []
        func mark(_ name: String) { decoded.insert(name) }

        let info = try decode(ServerInfo.self, "info"); mark("info")
        try expect(info.features.sportPageLeagues?.items == ["AFL", "NBA"] && info.features.sportPageEvents == true,
                   "info: sportPageLeagues is a list of leagues, sportPageEvents a flag")
        let page = try decode(GuidePage.self, "library-guide"); mark("library-guide")
        try expect(!page.channels.isEmpty, "library-guide: channels")
        let recordings = try decode([Recording].self, "recordings"); mark("recordings")
        try expect(!recordings.isEmpty, "recordings: a list")
        _ = try decode(RecordingRule.self, "recordings-rule-series"); mark("recordings-rule-series")
        _ = try decode([RecordingRule].self, "recordings-rules"); mark("recordings-rules")
        for name in ["recordings-schedule", "recordings-schedule-clash", "recordings-schedule-existing", "recordings-scheduled-cancel"] {
            _ = try decode(ScheduledRecording.self, name); mark(name)
        }
        _ = try decode([ScheduledRecording].self, "recordings-scheduled"); mark("recordings-scheduled")
        _ = try decode(RecordingWatch.self, "recordings-watch-200"); mark("recordings-watch-200")
        _ = try decode(RecordingPreparing.self, "recordings-watch-202"); mark("recordings-watch-202")

        let catalog = try decode(SportCatalog.self, "sports-catalog"); mark("sports-catalog")
        try expect(SportLabels.labels(catalog)["EPL"] != nil, "sports-catalog: labels by league")
        _ = try decode(SportEventsResponse.self, "sports-events"); mark("sports-events")
        _ = try decode(SportFollows.self, "sports-follows"); mark("sports-follows")
        _ = try decode(SportFollows.self, "sports-follows-put"); mark("sports-follows-put")
        _ = try decode(SportNames.self, "sports-names"); mark("sports-names")
        _ = try decode(SportSuggestions.self, "sports-suggestions"); mark("sports-suggestions")
        _ = try decode(SportPagePreferences.self, "sports-pages-preferences"); mark("sports-pages-preferences")
        let front = try decode(SportFront.self, "sports-front"); mark("sports-front")
        try expect(!front.games.isEmpty && !front.follows.isEmpty, "sports-front: games and follows")
        let f1 = try decode(F1Page.self, "sports-page-f1"); mark("sports-page-f1")
        try expect(f1.available && f1.weekend != nil && !(f1.weekend?.sessions.isEmpty ?? true), "sports-page-f1: the weekend's sessions")
        let cricket = try decode(CricketPage.self, "sports-page-cricket"); mark("sports-page-cricket")
        try expect(cricket.available && cricket.lead != nil, "sports-page-cricket: the lead")
        let nfl = try decode(NFLPage.self, "sports-page-nfl"); mark("sports-page-nfl")
        try expect(nfl.available && !nfl.weeks.isEmpty, "sports-page-nfl: the weeks")
        let afl = try decode(LeaguePage.self, "sports-page-league-afl"); mark("sports-page-league-afl")
        try expect(afl.available && afl.rounds.count == 2 && afl.rounds[1].current && afl.following == "17"
                   && afl.teams["17"]?.name == "Collingwood" && afl.standings.first?.columns.first?.label == "P",
                   "sports-page-league-afl: rounds, teams by id, the followed team, standings")
        let fixture = FixtureText.league(afl, league: "AFL", following: [], spoilerFree: false)
        try expect(fixture.rounds.count == 2 && fixture.views.count == 1, "sports-page-league-afl: as a fixture league")

        let ufc = try decode(SportEventsPage.self, "sports-page-events-ufc"); mark("sports-page-events-ufc")
        try expect(ufc.kind == "fight" && ufc.events.count == 2 && ufc.events[1].bouts.contains { $0.card == "main" }
                   && ufc.events[0].bouts.first?.result?.clock == "3:20", "events-ufc: bouts with their card and result")
        let nascar = try decode(SportEventsPage.self, "sports-page-events-nascar"); mark("sports-page-events-nascar")
        try expect(nascar.kind == "race" && nascar.lastWinner?.name == "Kyle Larson" && nascar.next?.start != nil
                   && nascar.events.first?.entryList == ["Austin Cindric", "Denny Hamlin"], "events-nascar: entry list, last winner, next")
        let pga = try decode(SportEventsPage.self, "sports-page-events-pga-tour"); mark("sports-page-events-pga-tour")
        try expect(pga.kind == "golf" && pga.events.first?.leaderboard.count == 3 && pga.events.first?.leaderboard[2].pos == nil
                   && pga.events.first?.leaderboard[0].rounds.count == 3, "events-pga-tour: the leaderboard")
        for name in ["sports-page-events-atp-tour", "sports-page-events-wta-tour"] {
            let tennis = try decode(SportEventsPage.self, name); mark(name)
            try expect(tennis.kind == "tennis" && tennis.events.allSatisfy { !$0.matches.isEmpty && !$0.draws.isEmpty },
                       "\(name): matches and draws")
        }
        let majors = try decode(SportEventsPage.self, "sports-page-events-majors"); mark("sports-page-events-majors")
        try expect(majors.available && majors.events.isEmpty, "events-majors: an empty week")

        let unlisted = Set(routes.keys).subtracting(decoded).subtracting(notModelled.keys)
        try expect(unlisted.isEmpty, "every golden answer is decoded or named as not modelled; new: \(unlisted.sorted())")
        return count
    }
}
