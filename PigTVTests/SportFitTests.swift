import SwiftUI
import XCTest
@testable import PigTV

/// #298 (batch L, 11 Nov 2026): real Sport layouts that kept the Apple TV's fixed widths on screens with less room. Each is
/// measured as its page lays it out, in a hosting controller proposed a width (`PlaceholderWidthTests`' way): it must
/// choose a width no greater than the one given, and a row of buttons must stay one line (no taller than at unlimited
/// width: a button whose words wrap, "Watc/h", is taller).
@MainActor
final class SportFitTests: XCTestCase {
    private func size(_ view: some View, width: CGFloat, narrow: Bool = false) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view.environment(\.sportNarrow, narrow)))
        return host.sizeThatFits(in: CGSize(width: width, height: 3_000))
    }

    private func browse(live: Bool) throws -> BrowseModel {
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture")
        let browse = BrowseModel(client: client, accountID: 1,
                                 guideCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("fit-\(UUID())"))
        browse.f1Page.setFixture(F1PageFixtures.page(live: live, guide: []))
        return browse
    }

    /// The Formula 1 page under the banner (the session tiles, the circuit, the grid and both standings) at the widths its
    /// page gives it: the Apple TV's (1,920 less the 80 pt safe area each side), and the iPad's (the screen less the
    /// page's 24 pt sides; below `SportColumns.narrowBelow` the page is narrow). Before #298 the tiles were 5 x 190 pt and
    /// the circuit 300 (iPad), so 1,330 pt; 5 x 262 and 400 (Apple TV), so 1,810.
    func testTheFormula1PageFitsTheWidthItIsGiven() throws {
        let app = AppModel()
        #if os(tvOS)
        let widths: [CGFloat] = [1_760, 1_700]
        #else
        // 13-inch and 11-inch landscape, just over narrow; then narrow: 11-inch and mini portrait, an iPhone's league page.
        let widths: [CGFloat] = [1_318, 1_146, 1_100, 786, 696, 393]
        #endif
        for live in [false, true] {
            let browse = try browse(live: live)
            for width in widths {
                #if os(iOS)
                let narrow = width < SportColumns.narrowBelow
                #else
                let narrow = false
                #endif
                let taken = size(SportF1Content(app: app, browse: browse), width: width, narrow: narrow).width
                XCTAssertLessThanOrEqual(taken, width + 0.5, "Formula 1\(live ? " (live)" : "") at \(Int(width)) pt takes \(Int(taken.rounded())) pt")
            }
        }
    }
}
