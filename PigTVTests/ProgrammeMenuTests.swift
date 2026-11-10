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
        let items = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "ABC TV", programme: later,
                                                             canWatchFromStart: true), now: now)
        XCTAssertEqual(items.map(\.title), ["Record this programme", "Record every new episode", "More options…",
                                            "Watch from start", "Programme details", "Channel schedule",
                                            "Add ABC TV to favourites"])
        XCTAssertEqual(items.filter(\.isRecordSection).count, 3)
        XCTAssertEqual(items[0].detail, "\(later.timeRange), with the usual padding")
        XCTAssertEqual(items[1].detail, "Four Corners on ABC TV")
    }

    /// Apple 114: a scheduled programme offers Change recording (the record page), not batch 4's Cancel this recording.
    func testAScheduledProgrammeOffersChangeRecording() {
        let live = programme(-600, 3000)
        let items = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "Fox Footy", programme: live,
                                                             recordingStatus: "Recording now",
                                                             isFavourite: true), now: now)
        XCTAssertEqual(items.map(\.title), ["Change recording", "Record every new episode", "More options…",
                                            "Programme details", "Channel schedule", "Remove Fox Footy from favourites"])
        XCTAssertEqual(items[0].detail, "Recording now", "the state is said in words")
        XCTAssertEqual(items[0].id, "changeRecording")
    }

    /// Apple 115: a Sport card's RECORD section: this game, every game of the team, More options….
    func testASportCardRecordsThisGameOrEveryGameOfTheTeam() {
        let later = programme(2400, 9000)
        let items = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "Optus Sport 1", programme: later,
                                                             everyGameTeam: "Liverpool", isGame: true), now: now)
            .filter(\.isRecordSection)
        XCTAssertEqual(items.map(\.title), ["Record this game", "Record every Liverpool game", "More options…"])
        let noTeam = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "Optus Sport 1", programme: later, isGame: true), now: now)
        XCTAssertFalse(noTeam.contains { $0.id == "recordEvery" }, "never a series rule for a game, no team rule without a team")
    }

    func testEndedProgrammesAndTilesHaveNoRecordSection() {
        let ended = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "SBS", programme: programme(-7200, -60)), now: now)
        XCTAssertEqual(ended.map(\.title), ["Programme details", "Channel schedule", "Add SBS to favourites"])
        let tile = ProgrammeMenu.items(ProgrammeMenuSubject(channelName: "SBS", programme: nil), now: now)
        XCTAssertEqual(tile.map(\.title), ["Channel schedule", "Add SBS to favourites"])
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
