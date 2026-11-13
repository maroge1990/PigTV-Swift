import SwiftUI
import XCTest
@testable import PigTV

// maroge1990/PigTV#293 (Codex, Apple 198–203, item 10): every focused control on the television lifts, carries the ring
// and takes the pink focus fill (the owner's #279 pick, confirmed 14 Nov 2026). Before the fix a surface built with
// `drawSurface: false` (the Sport list cards, the golf player card, the Recordings "All" link, a sport's rail header)
// and the TV Guide's channel tile kept their resting colour under focus: lift and ring, no tint. (Both tests fail to
// compile on the old code: neither function existed.)
@MainActor
final class PigFocusFillTests: XCTestCase {
    func testAFocusedSurfaceTakesTheFocusFillWhetherOrNotTheStyleDrawsTheSurface() {
        // The style draws the surface: the fill replaces the resting colour, under the content.
        XCTAssertEqual(PigFocus.fillLayer(focused: true, drawsSurface: true), .underContent)
        // The content draws its own surface: the fill goes over it (under it, it would be hidden by the card's own
        // background, which is what happened before).
        XCTAssertEqual(PigFocus.fillLayer(focused: true, drawsSurface: false), .overContent)
        // At rest: no fill either way (`drawSurface` decides only the resting background).
        XCTAssertEqual(PigFocus.fillLayer(focused: false, drawsSurface: true), .none)
        XCTAssertEqual(PigFocus.fillLayer(focused: false, drawsSurface: false), .none)
    }

    func testTheGuidesChannelTileTakesTheFocusFillWhenFocused() {
        XCTAssertEqual(ChannelTile.focusFill(focused: true), PigFocus.fill)
        XCTAssertNil(ChannelTile.focusFill(focused: false))
    }
}
