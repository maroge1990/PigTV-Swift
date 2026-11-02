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
}
