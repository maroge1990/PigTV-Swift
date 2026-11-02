import XCTest
@testable import PigTV

// D-44 (Apple 107): the one long-press menu's items and its place beside the focused programme.
final class ProgrammeMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ start: TimeInterval, _ end: TimeInterval) -> GuideProgramme {
        GuideProgramme(title: "Four Corners", description: nil, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    func testRecordComesFirstThenWatchFromStartDetailsScheduleAndFavourites() {
        let later = programme(2400, 6000)
        let items = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "ABC TV", programme: later, rulesAvailable: true,
                                                             canWatchFromStart: true), now: now)
        XCTAssertEqual(items.map(\.title), ["Record this programme", "Record every new episode", "More options…",
                                            "Watch from start", "Programme details", "Channel schedule",
                                            "Add ABC TV to favourites"])
        XCTAssertEqual(items.filter(\.isRecordSection).count, 3)
        XCTAssertEqual(items[0].detail, "\(later.timeRange), with the usual padding")
        XCTAssertEqual(items[1].detail, "Four Corners on ABC TV")
    }

    func testSportRecordsEveryGameAndAScheduledProgrammeOffersCancel() {
        let live = programme(-600, 3000)
        let items = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "Fox Footy", programme: live,
                                                             recordingStatus: "Recording now", rulesAvailable: true,
                                                             everyGame: "Every Collingwood game", isFavourite: true), now: now)
        XCTAssertEqual(items.map(\.title), ["Cancel this recording", "Record every game", "More options…",
                                            "Programme details", "Channel schedule", "Remove Fox Footy from favourites"])
        XCTAssertEqual(items[0].detail, "Recording now", "the state is said in words")
    }

    func testEndedProgrammesAndTilesHaveNoRecordSection() {
        let ended = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "SBS", programme: programme(-7200, -60),
                                                             rulesAvailable: true), now: now)
        XCTAssertEqual(ended.map(\.title), ["Programme details", "Channel schedule", "Add SBS to favourites"])
        let tile = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "SBS", programme: nil), now: now)
        XCTAssertEqual(tile.map(\.title), ["Channel schedule", "Add SBS to favourites"])
        XCTAssertFalse(ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "SBS", programme: programme(60, 600)), now: now)
            .contains { $0.id == "recordEvery" }, "no series item without recording rules")
    }

    func testTheCardSitsBesideTheProgrammeAndOnScreen() {
        let card = CGSize(width: 500, height: 400)
        let screen = CGSize(width: 1920, height: 1080)
        // A programme on the right: the card on its left.
        let right = ProgrammeMenuPlacement.origin(card: card, beside: CGRect(x: 1300, y: 600, width: 500, height: 80), in: screen)
        XCTAssertEqual(right.x, 1300 - 20 - 500)
        XCTAssertEqual(right.y, 640 - 200)
        // On the left: on its right. Near the bottom: kept on screen.
        let left = ProgrammeMenuPlacement.origin(card: card, beside: CGRect(x: 200, y: 1000, width: 300, height: 80), in: screen)
        XCTAssertEqual(left.x, 520)
        XCTAssertEqual(left.y, 1080 - 24 - 400)
    }
}
