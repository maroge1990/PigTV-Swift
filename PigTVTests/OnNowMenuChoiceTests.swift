#if os(iOS)
import XCTest
@testable import PigTV

/// Codex batch 4 (medium): the iPhone's On now menu showed one programme, but choosing an item recomputed "what is on
/// now" with the clock at that moment, so a menu left open across a programme boundary acted on the next programme
/// (Cancel recording could cancel the wrong schedule). A choice now carries the programme the menu was built with.
@MainActor
final class OnNowMenuChoiceTests: XCTestCase {
    func testAChoiceActsOnTheProgrammeTheMenuShowedAfterItHasEnded() throws {
        let now = Date().timeIntervalSince1970 * 1000
        let shown = GuideProgramme(title: "Ending news", description: nil, startTime: now - 3_600_000, endTime: now - 1_000)
        let next = GuideProgramme(title: "Next show", description: nil, startTime: now - 1_000, endTime: now + 3_600_000)
        let channel = GuideChannel(rawID: "a", sourceId: 1, name: "ABC", logo: nil, category: nil, programmes: [shown, next])
        let model = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1), accountID: 1)
        var chosen: GuideProgramme?
        let list = OnNowList(rows: [channel], model: model, clock: Date(), play: { _ in }, info: { _ in },
                             choose: { _, programme, _ in chosen = programme })
        list.select(channel, shown, .details)
        XCTAssertEqual(chosen?.title, "Ending news", "the menu's programme, not the one on now when the item is chosen")
    }
}
#endif
