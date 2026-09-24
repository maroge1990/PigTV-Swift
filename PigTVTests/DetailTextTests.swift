import XCTest
@testable import PigTV

// Build 28: wording and grouping used by the redesigned detail screens.
final class DetailTextTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func programme(_ title: String, _ start: Date, minutes: Double) -> GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: start.timeIntervalSince1970 * 1000,
                       endTime: start.timeIntervalSince1970 * 1000 + minutes * 60_000)
    }

    func testDurationWording() {
        XCTAssertEqual(DetailText.duration(45 * 60), "45 min")
        XCTAssertEqual(DetailText.duration(90 * 60), "1 h 30 min")
        XCTAssertEqual(DetailText.duration(2 * 3600), "2 h")
    }

    func testDayWording() {
        let now = date(25, 20)
        XCTAssertEqual(DetailText.day(date(25, 23), now: now, calendar: calendar), "Today")
        XCTAssertEqual(DetailText.day(date(26, 8), now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(DetailText.day(date(24, 8), now: now, calendar: calendar), "Yesterday")
    }

    func testScheduleGroupsByDayAndDropsFinishedAndDuplicates() {
        let now = date(25, 23)
        let programmes = [
            programme("Finished", date(25, 21), minutes: 60),
            programme("On now", date(25, 22, 30), minutes: 60),
            programme("On now", date(25, 22, 30), minutes: 60),
            programme("Late", date(25, 23, 30), minutes: 60),
            programme("Morning", date(26, 7), minutes: 30)]
        let days = ScheduleDays.group(programmes, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.title), ["Today", "Tomorrow"])
        XCTAssertEqual(days[0].programmes.map(\.title), ["On now", "Late"])
        XCTAssertEqual(days[1].programmes.map(\.title), ["Morning"])
    }
}
