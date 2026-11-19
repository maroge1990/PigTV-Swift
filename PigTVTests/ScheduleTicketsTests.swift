import XCTest
@testable import PigTV

// Codex sign-off of #347 (medium): a lost cancellation's own read of the scheduled list (a higher ticket) that its reader
// then dropped (the attempt was no longer its own) had already advanced the watermark when it arrived, so a valid
// refresh asked before it (a lower ticket) was refused and its list never shown. The watermark now moves only when an
// answer is published, after its owner is checked. (No ScheduleTickets: fails to compile on the commit before.)
final class ScheduleTicketsTests: XCTestCase {
    func testADroppedNewerAnswerDoesNotRefuseAnOlderOne() {
        var tickets = ScheduleTickets()
        let refresh = tickets.ask()        // a recordings refresh asks first
        let reconcile = tickets.ask()      // then a lost cancellation's own read
        // The reconcile answer arrives first; its attempt was answered meanwhile, so its reader drops it unpublished.
        XCTAssertTrue(tickets.publish(refresh), "the refresh's answer is still the newest published: shown")
        XCTAssertEqual(tickets.published, refresh)
        _ = reconcile
    }

    func testAnOlderAnswerAfterANewerPublishedOneIsRefused() {
        var tickets = ScheduleTickets()
        let first = tickets.ask(), second = tickets.ask()
        XCTAssertTrue(tickets.publish(second))
        XCTAssertFalse(tickets.publish(first), "older than what is shown: never put back")
        XCTAssertFalse(tickets.publish(second), "once")
        XCTAssertTrue(tickets.publish(tickets.ask()), "a read asked after it is newer")
    }
}
