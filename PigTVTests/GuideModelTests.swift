import XCTest
@testable import PigTV

// Guide model behaviour that the large (~18 000 channel) real guide depends
// on: indexed channel lookup (R18) and reorder-stable identity (R12).
@MainActor
final class GuideModelTests: XCTestCase {
    private func model() throws -> BrowseModel {
        BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
    }

    private func guideChannel(_ raw: String, stable: String? = nil, category: String = "News") -> GuideChannel {
        GuideChannel(rawID: raw, sourceId: 1, name: "Channel \(raw)", logo: nil, category: category,
                     programmes: [], stableId: stable)
    }

    private func channel(_ raw: String, stable: String? = nil) -> Channel {
        Channel(rawID: raw, sourceId: 1, name: "Channel \(raw)", logo: nil, category: nil,
                now: nil, next: nil, stableId: stable)
    }

    func testIndexedLookupFollowsGuideChanges() throws {
        let browse = try model()
        browse.guide = (0..<18_000).map { guideChannel("pos_\($0)") }
        XCTAssertEqual(browse.guideChannel(id: "1:pos_17999")?.name, "Channel pos_17999")
        XCTAssertNil(browse.guideChannel(id: "1:missing"))
        // A replaced guide (refresh or provider reorder) invalidates the index.
        browse.guide = [guideChannel("pos_0", stable: "abc")]
        XCTAssertNil(browse.guideChannel(id: "1:pos_17999"))
        XCTAssertEqual(browse.guideChannel(id: "1:pos_0")?.stableId, "abc")
        browse.guide.append(guideChannel("pos_1"))
        XCTAssertEqual(browse.guideChannel(id: "1:pos_1")?.name, "Channel pos_1")
    }

    func testIdentityKeyPrefersStableIdAndFallsBack() {
        XCTAssertEqual(guideChannel("pos_4", stable: "s1").identityKey, "1:s:s1")
        XCTAssertEqual(guideChannel("pos_4").identityKey, "1:pos_4")
        XCTAssertEqual(channel("pos_9", stable: "s1").identityKey, guideChannel("pos_4", stable: "s1").identityKey)
    }

    func testFavouriteCoversEveryListingOfACrossListedChannel() throws {
        let browse = try model()
        // Server 0097: one favourite, returned under one listing's id.
        browse.favourites = [channel("pos_10", stable: "s1")]
        XCTAssertTrue(browse.isFavourite(channel("pos_10", stable: "s1")))
        XCTAssertTrue(browse.isFavourite(channel("pos_250", stable: "s1")), "other listing of the same channel")
        XCTAssertFalse(browse.isFavourite(channel("pos_11", stable: "s2")))
        // Older servers without stableId keep plain id matching.
        browse.favourites = [channel("pos_10")]
        XCTAssertTrue(browse.isFavourite(channel("pos_10")))
        XCTAssertFalse(browse.isFavourite(channel("pos_11")))
    }

    func testProgrammeLookupUsesIndexOnLargeGuide() throws {
        let browse = try model()
        browse.guide = (0..<18_000).map { guideChannel("pos_\($0)") }
        let targets = (0..<500).map { channel("pos_\($0 * 36)") }
        measure {
            for target in targets { _ = browse.programmes(for: target) }
        }
    }
}
