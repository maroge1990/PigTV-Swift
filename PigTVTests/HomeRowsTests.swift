import XCTest
@testable import PigTV

// Build 28: the Home screen's row choices (pure `HomeRows`).
final class HomeRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String, from start: TimeInterval, minutes: Double) -> GuideProgramme {
        let begin = (now.timeIntervalSince1970 + start) * 1000
        return GuideProgramme(title: title, description: nil, startTime: begin, endTime: begin + minutes * 60_000)
    }

    private func channel(_ id: String, stable: String? = nil, category: String? = nil,
                         _ programmes: [GuideProgramme] = []) -> HomeChannel {
        HomeChannel(sourceId: 1, rawID: id, name: "Channel \(id)", category: category, stableId: stable, programmes: programmes)
    }

    // MARK: Continue watching

    func testContinueWatchingPrefersThisDevicesLastChannelResolvedAgainstTheGuide() {
        let last = LastWatched(sourceId: 1, rawID: "old-position", name: "Fox Footy", stableId: "fox")
        let guideRow = channel("new-position", stable: "fox", [programme("Match", from: -600, minutes: 60)])
        let recent = [channel("a"), channel("b")]
        let chosen = HomeRows.continueWatching(last: last, recent: recent) { $0.identityKey == guideRow.identityKey ? guideRow : nil }
        XCTAssertEqual(chosen, guideRow, "found by stable identity after a reorder")
    }

    func testContinueWatchingFallsBackToTheRememberedFieldsThenToHistory() {
        let last = LastWatched(sourceId: 1, rawID: "gone", name: "Old Channel", number: 7, logo: "/l.png")
        let fromMemory = HomeRows.continueWatching(last: last, recent: [channel("a")]) { _ in nil }
        XCTAssertEqual(fromMemory?.id, "1:gone")
        XCTAssertEqual(fromMemory?.number, 7)
        XCTAssertEqual(fromMemory?.logo, "/l.png")
        XCTAssertEqual(HomeRows.continueWatching(last: nil, recent: [channel("a"), channel("b")]) { _ in nil }?.id, "1:a")
        XCTAssertNil(HomeRows.continueWatching(last: nil, recent: []) { _ in nil })
    }

    func testRecentlyWatchedDropsTheHeroAndDuplicates() {
        let hero = channel("x", stable: "s1")
        let row = HomeRows.recentlyWatched([channel("y", stable: "s1"), channel("a"), channel("a"), channel("b")], excluding: hero)
        XCTAssertEqual(row.map(\.id), ["1:a", "1:b"])
    }

    func testLastWatchedRoundTripsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HomeRowsTests"))
        defaults.removePersistentDomain(forName: "HomeRowsTests")
        XCTAssertNil(LastWatched.load(from: defaults))
        let entry = LastWatched(sourceId: 2, rawID: "9", name: "Nine", number: 9, stableId: "n")
        entry.save(to: defaults)
        XCTAssertEqual(LastWatched.load(from: defaults), entry)
        LastWatched.clear(from: defaults)
        XCTAssertNil(LastWatched.load(from: defaults))
    }

    // MARK: On now and starting soon

    func testOnNowKeepsOrderAndSkipsChannelsWithNothingOn() {
        let on = channel("on", [programme("Now", from: -60, minutes: 30)])
        let off = channel("off", [programme("Later", from: 600, minutes: 30)])
        let empty = channel("none")
        XCTAssertEqual(HomeRows.onNow([off, on, empty], now: now).map(\.id), ["1:on"])
    }

    func testStartingSoonIsTheNextProgrammePerChannelWithinTheHourSoonestFirst() {
        let a = channel("a", [programme("A now", from: -600, minutes: 20),
                              programme("A next", from: 600, minutes: 30),
                              programme("A after", from: 2400, minutes: 30)])
        let b = channel("b", [programme("B soon", from: 120, minutes: 30)])
        let c = channel("c", [programme("C too late", from: 3700, minutes: 30)])
        let d = channel("d", [programme("D edge", from: 3600, minutes: 30)])
        let items = HomeRows.startingSoon([a, b, c, d], now: now)
        XCTAssertEqual(items.map(\.programme.title), ["B soon", "A next", "D edge"])
        XCTAssertFalse(items.contains { $0.programme.title == "A now" }, "already started")
    }

    func testCountdownWording() {
        XCTAssertEqual(HomeRows.countdown(to: now.addingTimeInterval(12 * 60), now: now), "in 12 min")
        XCTAssertEqual(HomeRows.countdown(to: now.addingTimeInterval(30), now: now), "in 1 min")
        XCTAssertEqual(HomeRows.countdown(to: now.addingTimeInterval(11 * 60 + 5), now: now), "in 12 min")
        XCTAssertEqual(HomeRows.countdown(to: now.addingTimeInterval(60 * 60), now: now), "in 1 h")
        XCTAssertEqual(HomeRows.countdown(to: now, now: now), "starting now")
    }

    // MARK: Sport (C-H)

    func testSportOnNowNeedsTheFlagAndAMarkedCategoryAndPutsLiveFirst() {
        let sport = PigTV.Category(rawID: "10", sourceId: 1, name: "Sport", channelCount: 3, sport: true)
        let news = PigTV.Category(rawID: "20", sourceId: 1, name: "News", channelCount: 1)
        let replay = channel("r", category: "10", [programme("Classic Replay", from: -60, minutes: 60)])
        let live = channel("l", category: "10", [programme("AFL: Round 12 Live", from: -60, minutes: 60)])
        let byName = channel("n", category: "Sport", [programme("LIVE: Premier League", from: -60, minutes: 60)])
        let idle = channel("i", category: "10", [programme("Tomorrow", from: 7200, minutes: 60)])
        let headlines = channel("h", category: "20", [programme("Live at Five", from: -60, minutes: 60)])
        let all = [replay, live, byName, idle, headlines]
        XCTAssertEqual(HomeRows.sportOnNow(all, categories: [sport, news], enabled: true, now: now).map(\.id),
                       ["1:l", "1:n", "1:r"], "sport categories only, something on now, live first")
        XCTAssertTrue(HomeRows.sportOnNow(all, categories: [sport, news], enabled: false, now: now).isEmpty, "no flag")
        XCTAssertTrue(HomeRows.sportOnNow(all, categories: [news], enabled: true, now: now).isEmpty, "nothing marked")
    }

    func testLiveEventMatchesTheWordOnly() {
        XCTAssertTrue(HomeRows.isLiveEvent(programme("LIVE: Premier League", from: 0, minutes: 1)))
        XCTAssertTrue(HomeRows.isLiveEvent(programme("F1 Practice (Live)", from: 0, minutes: 1)))
        XCTAssertTrue(HomeRows.isLiveEvent(programme("Cricket Live", from: 0, minutes: 1)))
        XCTAssertFalse(HomeRows.isLiveEvent(programme("Liverpool v Everton", from: 0, minutes: 1)))
        XCTAssertFalse(HomeRows.isLiveEvent(programme("Deliver Us", from: 0, minutes: 1)))
    }

    func testCategoriesDecodeSportTolerantly() throws {
        let rows = try JSONDecoder().decode([PigTV.Category].self, from: Data(#"[{"id":"1","sourceId":1,"name":"A","channelCount":2,"sport":true},{"id":"2","sourceId":1,"name":"B","channelCount":1}]"#.utf8))
        XCTAssertEqual(rows.map(\.sport), [true, false])
    }

    // MARK: Recordings

    func testRecordingsInProgressFirstThenNewestCompleted() throws {
        let json = #"""
        [{"id":1,"title":"Old","status":"completed","started_at":1000},
         {"id":2,"title":"New","status":"completed","started_at":5000},
         {"id":3,"title":"Now","status":"recording","started_at":4000},
         {"id":4,"title":"Planned","status":"scheduled","started_at":9000},
         {"id":5,"title":"Broken","status":"failed","started_at":8000},
         {"id":6,"title":"Middle","status":"completed","started_at":3000}]
        """#
        let recordings = try JSONDecoder().decode([Recording].self, from: Data(json.utf8))
        XCTAssertEqual(HomeRows.recordings(recordings).map(\.id), [3, 2, 6, 1])
        XCTAssertEqual(HomeRows.recordings(recordings, limit: 2).map(\.id), [3, 2])
    }

    func testResumeFraction() {
        XCTAssertEqual(HomeRows.resumeFraction(position: 900, duration: 1800), 0.5)
        XCTAssertNil(HomeRows.resumeFraction(position: 5, duration: 1800), "barely started")
        XCTAssertNil(HomeRows.resumeFraction(position: 1790, duration: 1800), "finished")
        XCTAssertNil(HomeRows.resumeFraction(position: 900, duration: nil))
    }
}
