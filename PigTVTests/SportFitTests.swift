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

    /// The hero's buttons as the front page draws them (Remind me or Watch, Record, Open <sport>) at the hero's width: on
    /// an iPad mini in portrait about 300 pt, on an 11-inch iPad 390 (the banner less its list, 340, and padding). They
    /// stay one line and inside the width.
    func testTheBannersButtonsStayOneLineInTheHerosWidth() throws {
        let front = try JSONDecoder().decode(SportFront.self, from: SportFrontLayoutTests.fixture())
        let app = AppModel()
        let flow = SportRecordFlow()
        var games: [(SportsGame, Date)] = []
        for game in front.games {
            guard let event = SportFrontText.event(game), let best = event.best else { continue }
            let start = event.start(on: best)
            let before = start.addingTimeInterval(-3_600), during = start.addingTimeInterval(600)
            if games.allSatisfy({ SportFrontText.action($0.0, now: $0.1) != .remind }), SportFrontText.action(game, now: before) == .remind {
                games.append((game, before))
            }
            if games.allSatisfy({ SportFrontText.action($0.0, now: $0.1) != .watch }), SportFrontText.action(game, now: during) == .watch {
                games.append((game, during))
            }
        }
        XCTAssertEqual(Set(games.map { SportFrontText.action($0.0, now: $0.1) }), [.remind, .watch], "a game to remind and one to watch")
        #if os(tvOS)
        let widths: [CGFloat] = [1_100, 800]
        #else
        let widths: [CGFloat] = [480, 392, 302]
        #endif
        for (game, now) in games {
            let buttons = SportBannerActions {
                SportHeroButtons(game: game, now: now, app: app, flow: flow, team: nil,
                                 open: (label: "Open Australian football", action: {}))
            }
            let line = size(buttons, width: 5_000).height
            for width in widths {
                let fitted = size(buttons, width: width)
                let label = "\(SportFrontText.actionLabel(game, now: now)) at \(Int(width)) pt"
                XCTAssertLessThanOrEqual(fitted.width, width + 0.5, "\(label): the buttons take \(Int(fitted.width.rounded())) pt")
                XCTAssertLessThanOrEqual(fitted.height, line + 0.5, "\(label): the buttons are \(Int(fitted.height)) pt tall, one line is \(Int(line)): a word wrapped")
            }
        }
    }
}
