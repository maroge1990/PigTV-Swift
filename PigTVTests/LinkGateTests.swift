import XCTest
@testable import PigTV

// Codex review of Apple 325 (medium): with the foreground reset gone, a warm pigtv:// or Top Shelf link delivered after a
// trip to the background but before the scene was active opened at once, and the trip's clean-up (AppModel.background(),
// which cancels a waiting play or hand-off) could then cancel it. Now it waits for the active scene and the clean-up.
// (No LinkGate: these fail to compile on the commit before.)
final class LinkGateTests: XCTestCase {
    private let play = URL(string: "pigtv://play?id=7&name=BBC%20One")!
    private let game = URL(string: "pigtv://game?id=nrl-1")!

    func testALinkDeliveredBeforeActivationWaitsForTheActiveSceneAndTheCleanUp() {
        var gate = LinkGate()
        XCTAssertTrue(gate.sceneChanged(active: true).isEmpty)
        // To the background: the clean-up starts.
        _ = gate.sceneChanged(active: false)
        gate.cleanupStarted()
        // Coming back: the Top Shelf's link arrives while the scene is still inactive.
        XCTAssertFalse(gate.arrived(play), "held: the scene is not active")
        XCTAssertEqual(gate.sceneChanged(active: true), [], "active, but the clean-up has not run: still held")
        XCTAssertFalse(gate.arrived(game), "held behind the first, in order")
        XCTAssertEqual(gate.cleanupFinished(), [play, game], "the clean-up has run: both open, in order")
        XCTAssertTrue(gate.held.isEmpty)
    }

    func testTheCleanUpFinishingFirstReleasesOnActivation() {
        var gate = LinkGate()
        gate.cleanupStarted()
        XCTAssertFalse(gate.arrived(play))
        XCTAssertEqual(gate.cleanupFinished(), [], "not active yet")
        XCTAssertEqual(gate.sceneChanged(active: true), [play])
    }

    func testALinkWhileActiveOpensAtOnce() {
        var gate = LinkGate()
        _ = gate.sceneChanged(active: true)
        XCTAssertTrue(gate.arrived(play))
        XCTAssertTrue(gate.held.isEmpty)
        // An .inactive blip (Control Center) with no trip to the background: held only until active again.
        _ = gate.sceneChanged(active: false)
        XCTAssertFalse(gate.arrived(game))
        XCTAssertEqual(gate.sceneChanged(active: true), [game])
    }
}
