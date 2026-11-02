import XCTest
@testable import PigTV

// D-44 (Apple 108–110): the TV Guide's pages.
final class GuidePagesTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    /// Friday 15 January 2027, 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String, hour: Double, minutes: Double) -> GuideProgramme {
        let start = now.timeIntervalSince1970 + hour * 3600
        return GuideProgramme(title: title, description: nil, startTime: start * 1000, endTime: (start + minutes * 60) * 1000)
    }

    func testAlsoOnListsTheRestOfThatEvening() {
        // 22:20–23:20 UTC, then the late news, the overnight and the next morning.
        let corners = programme("Four Corners", hour: 14 + 1.0 / 3, minutes: 60)
        let list = [programme("Media Watch", hour: 15 + 1.0 / 3, minutes: 15), corners,
                    programme("Late News", hour: 15.5833, minutes: 25), programme("Q+A", hour: 16, minutes: 65),
                    programme("Rage", hour: 17.0833, minutes: 300), programme("Morning", hour: 23, minutes: 60),
                    programme("Earlier", hour: 13, minutes: 60)]
        XCTAssertEqual(AlsoOn.programmes(after: corners, in: list, calendar: utc).map(\.title),
                       ["Media Watch", "Late News", "Q+A", "Rage"], "the next four, in order, never itself or earlier ones")
        XCTAssertEqual(AlsoOn.programmes(after: corners, in: list, limit: 10, calendar: utc).map(\.title),
                       ["Media Watch", "Late News", "Q+A", "Rage"], "nothing after 6 am the next day")
        XCTAssertEqual(AlsoOn.heading(channel: "ABC TV", programme: corners, now: now, calendar: utc), "Also on ABC TV tonight")
        XCTAssertEqual(AlsoOn.heading(channel: "ABC TV", programme: programme("Gruen", hour: 2, minutes: 30), now: now, calendar: utc),
                       "Also on ABC TV today")
        XCTAssertEqual(AlsoOn.heading(channel: "ABC TV", programme: programme("Rage", hour: 20, minutes: 60), now: now, calendar: utc),
                       "Also on ABC TV tomorrow")
    }

    func testTheChannelPageListsWhatComesAfterTheProgrammeOnNow() {
        let live = programme("Test, Day 1", hour: -1, minutes: 480)
        let wrap = programme("Day 1 Wrap", hour: 7, minutes: 30)
        let gone = programme("Pre-match", hour: -2, minutes: 60)
        let days = ScheduleDays.upcoming([gone, live, wrap], now: now, calendar: utc)
        XCTAssertEqual(days.flatMap(\.programmes).map(\.title), ["Day 1 Wrap"], "the hero has the one on now; finished ones go")
        XCTAssertEqual(ScheduleDays.upcoming([live], now: now, calendar: utc), [])
    }

    func testSearchFindsChannelsAndTheNext24HoursOfProgrammes() {
        let soon = programme("Cricket: Day 1 Wrap", hour: 1, minutes: 30)
        let live = programme("Australia v India · 1st Test", hour: -1, minutes: 480)
        let later = programme("Inside Cricket", hour: 30, minutes: 60)
        let gone = programme("Cricket Classics", hour: -3, minutes: 60)
        let fox = GuideChannel(rawID: "501", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil,
                               programmes: [soon, live, later, gone], stableId: "fox")
        let foxAgain = GuideChannel(rawID: "pos_9", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil,
                                    programmes: [], stableId: "fox")
        let abc = GuideChannel(rawID: "2", sourceId: 1, name: "ABC TV", logo: nil, category: nil,
                               programmes: [programme("Cricket Talk", hour: 2, minutes: 30)])
        let found = GuideSearch.run("cricket", in: [fox, foxAgain, abc], now: now)
        XCTAssertEqual(found.channels.map(\.rawID), ["501"], "a cross-listed channel is found once")
        XCTAssertEqual(found.programmes.map(\.programme.title), ["Cricket: Day 1 Wrap", "Cricket Talk"],
                       "only titles that match, not ended, starting in the next 24 hours, soonest first")
        XCTAssertEqual(found.programmes.first?.id, "1:501|\(soon.startTime)", "results are keyed by stable ids, not offsets")
        XCTAssertEqual(GuideSearch.run("c", in: [fox], now: now), GuideSearch.Results(), "two letters at least")
        XCTAssertEqual(GuideSearch.run("india", in: [fox], now: now).programmes.map(\.programme.title), ["Australia v India · 1st Test"],
                       "the programme on now is included")
    }

    func testJumpToKeepsTheHourAcrossDaysAndTheDayAcrossHours() {
        let days = GuideJump.days(now: now, calendar: utc)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.prefix(2).map(\.title), ["Today", "Tomorrow"])
        let eight = GuideJump.moving(now, toHour: 20, calendar: utc)
        XCTAssertEqual(utc.component(.hour, from: eight), 20)
        XCTAssertTrue(utc.isDate(eight, inSameDayAs: now))
        let tomorrowAtEight = GuideJump.moving(eight, toDay: days[1].date, calendar: utc)
        XCTAssertEqual(utc.component(.hour, from: tomorrowAtEight), 20)
        XCTAssertTrue(utc.isDate(tomorrowAtEight, inSameDayAs: days[1].date))
    }
}
