import XCTest
@testable import PigTV

// #349: one tuning card from the resolve until the first picture, whether or not the item is installed underneath yet.
// Before, PlayerScreen drew "Tuning…" in two places (the resolving state, and an overlay over the installed player) and
// the card was rebuilt when `ready` flipped (PlayerSlowStartUITests sees it; PlayerScreenLayers does not exist on 319).
final class PlayerTuningCardTests: XCTestCase {
    func testOneTuningCardFromTheResolveToTheFirstPicture() {
        XCTAssertTrue(PlayerScreenLayers.showsTuningCard(ready: false, hasPlayed: false), "resolving")
        XCTAssertTrue(PlayerScreenLayers.showsTuningCard(ready: true, hasPlayed: false), "installed, no picture yet")
        XCTAssertFalse(PlayerScreenLayers.showsTuningCard(ready: true, hasPlayed: true), "the picture shows")
    }
}
