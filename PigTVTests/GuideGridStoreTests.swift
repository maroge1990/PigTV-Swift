import XCTest
@testable import PigTV

// The UIKit grid's row store: its per-channel programme cache must follow the
// model's revision, not just the shape of a channel's list (audit R14).
@MainActor
final class GuideGridStoreTests: XCTestCase {
    private func channel(_ title: String, end: Double = 3_600_000) -> GuideChannel {
        GuideChannel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil,
                     programmes: [GuideProgramme(title: title, description: nil, startTime: 0, endTime: end)])
    }

    func testASameShapeCorrectionIsNotServedStale() {
        let store = GuideGridStore()
        store.setRows([channel("Old title")], revision: GuideGridRevision(programmes: 1))
        XCTAssertEqual(store.programmes(in: 0).first?.title, "Old title")
        // Same channel, same count, same first start: only the title changed.
        store.setRows([channel("Corrected title")], revision: GuideGridRevision(programmes: 2))
        XCTAssertEqual(store.programmes(in: 0).first?.title, "Corrected title")
    }

    func testAReloadedGuideIsNotServedStale() {
        let store = GuideGridStore()
        let first = GuideGridRevision(programmes: 1, loadedAt: Date(timeIntervalSince1970: 100))
        store.setRows([channel("Before", end: 3_600_000)], revision: first)
        XCTAssertEqual(store.programmes(in: 0).first?.endTime, 3_600_000)
        store.setRows([channel("Before", end: 1_800_000)], revision: GuideGridRevision(programmes: 1, loadedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(store.programmes(in: 0).first?.endTime, 1_800_000)
    }

    func testTheSameRevisionKeepsItsCache() {
        let store = GuideGridStore()
        let revision = GuideGridRevision(programmes: 1)
        store.setRows([channel("Cached")], revision: revision)
        let first = store.programmes(in: 0)
        // Paging appends rows without a new revision; existing lists stay.
        store.setRows([channel("Cached"), GuideChannel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, programmes: [])],
                      revision: revision)
        XCTAssertEqual(store.programmes(in: 0), first)
        XCTAssertEqual(store.itemCount(in: 1), 2)
    }

    func testListsBuiltAheadAreUsedForTheirRevisionOnly() {
        let rows = [channel("Ahead")]
        let lists = GuideGridStore.orderedLists(for: rows)
        let store = GuideGridStore()
        store.prime(lists, revision: GuideGridRevision(programmes: 3))
        store.setRows([channel("Ahead")], revision: GuideGridRevision(programmes: 3))
        XCTAssertEqual(store.programmes(in: 0).first?.title, "Ahead")
        // Primed for an older revision, then the data moved on: recomputed.
        store.setRows([channel("Moved on")], revision: GuideGridRevision(programmes: 4))
        XCTAssertEqual(store.programmes(in: 0).first?.title, "Moved on")
    }
}
