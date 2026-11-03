import XCTest
@testable import PigTV

/// #49 groundwork (Apple 105): the app-level presenter shows one thing at a time and closes what is open first; the
/// Undo toast's action commits when its time runs out or the app goes to the background, never after Undo.
@MainActor
final class AppPresenterTests: XCTestCase {
    private func recording(_ id: Int) throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(#"{"id":\#(id),"title":"Show \#(id)","status":"completed"}"#.utf8))
    }

    func testPresentingWhileSomethingIsOpenClosesItFirst() throws {
        let presenter = AppPresenter()
        presenter.present(.recording(try recording(1)))
        XCTAssertEqual(presenter.presented?.id, "recording:1")
        presenter.present(.recording(try recording(2)))
        XCTAssertNil(presenter.presented, "the open page closes first")
        XCTAssertEqual(presenter.queued?.id, "recording:2")
        presenter.present(.recording(try recording(3)))
        XCTAssertNil(presenter.presented, "still one at a time while the first is closing")
        presenter.didDismiss()
        XCTAssertEqual(presenter.presented?.id, "recording:3", "the latest request, once the first has gone")
        XCTAssertNil(presenter.queued)
    }

    func testDismissThenRunsTheActionOnlyOnceThePageHasGone() throws {
        let presenter = AppPresenter()
        var ran = 0
        presenter.dismiss { ran += 1 }
        XCTAssertEqual(ran, 1, "nothing open: at once")
        presenter.present(.recording(try recording(1)))
        presenter.dismiss { ran += 1 }
        XCTAssertNil(presenter.presented)
        XCTAssertEqual(ran, 1, "not while the page is still closing")
        presenter.didDismiss()
        XCTAssertEqual(ran, 2)
    }

    func testTheViewerClosingThePageIsAClose() throws {
        let presenter = AppPresenter()
        presenter.present(.recording(try recording(1)))
        presenter.hostSet(nil)
        XCTAssertTrue(presenter.closing)
        presenter.present(.recording(try recording(2)))
        XCTAssertNil(presenter.presented, "not over a page that is still going")
        presenter.didDismiss()
        XCTAssertEqual(presenter.presented?.id, "recording:2")
    }

    /// A clock the test moves on by hand.
    private final class Clock: @unchecked Sendable {
        var waiting: [CheckedContinuation<Void, Never>] = []
        func sleep(_: Duration) async { await withCheckedContinuation { waiting.append($0) } }
        func fire() { let all = waiting; waiting = []; all.forEach { $0.resume() } }
    }

    private func presenterWithClock() -> (AppPresenter, Clock) {
        let presenter = AppPresenter()
        let clock = Clock()
        presenter.sleep = { _ in await clock.sleep(.zero) }
        return (presenter, clock)
    }

    private func settle(_ clock: Clock? = nil) async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testTheActionCommitsWhenTheTimeRunsOut() async {
        let (presenter, clock) = presenterWithClock()
        var committed = 0
        presenter.offerUndo("Recording deleted") { committed += 1 }
        await settle()
        XCTAssertEqual(presenter.pendingUndo?.message, "Recording deleted")
        XCTAssertEqual(committed, 0, "not before the 10 s")
        clock.fire()
        await settle()
        XCTAssertEqual(committed, 1)
        XCTAssertNil(presenter.pendingUndo)
    }

    func testUndoCancelsTheAction() async {
        let (presenter, clock) = presenterWithClock()
        var committed = 0
        presenter.offerUndo("Recording deleted") { committed += 1 }
        await settle()
        presenter.undoPending()
        clock.fire()
        await settle()
        XCTAssertEqual(committed, 0)
        XCTAssertNil(presenter.pendingUndo)
    }

    func testGoingToTheBackgroundCommitsOnceAndANewOfferCommitsTheOldOne() async {
        let (presenter, clock) = presenterWithClock()
        var committed: [String] = []
        presenter.offerUndo("A") { committed.append("A") }
        presenter.offerUndo("B") { committed.append("B") }
        XCTAssertEqual(committed, ["A"], "a new offer commits the one before it")
        presenter.commitPendingUndo() // the app goes to the background
        XCTAssertEqual(committed, ["A", "B"])
        clock.fire()
        await settle()
        XCTAssertEqual(committed, ["A", "B"], "the timer never commits a second time")
    }

    /// Apple 122: Undo runs the action's `undone` (it shows again what the action hid); a commit never does.
    func testUndoRunsUndoneAndACommitDoesNot() async {
        let (presenter, _) = presenterWithClock()
        var log: [String] = []
        presenter.offerUndo("A", undone: { log.append("undone A") }) { log.append("commit A") }
        presenter.undoPending()
        presenter.offerUndo("B", undone: { log.append("undone B") }) { log.append("commit B") }
        presenter.commitPendingUndo()
        XCTAssertEqual(log, ["undone A", "commit B"])
    }
}
