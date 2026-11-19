import XCTest
@testable import PigTV

// #355 (Codex final sign-off of 325-335, medium 2): a failed first favourites request set `favouritesAnswered`, and the
// Guide never read `favouritesError`, so a cold launch with the Favourites chip saved landed on "No favourites" with only
// Show all channels and no retry. The chip's page now carries the favourites' outcome: their failure, with Try again;
// "No favourites" only for a successful empty answer. (No guideChip or favouritesFailed: fails to compile on the commit
// before.)
@MainActor
final class FavouritesChipStateTests: XCTestCase {
    func testTheFavouritesChipCarriesTheFavouritesOutcome() {
        let failed = PageState.failed(PageWords.favouritesFailed)
        XCTAssertEqual(PageState.guideChip(.empty, favouritesChip: true, favouritesEmpty: true, favouritesFailed: true), failed)
        XCTAssertEqual(PageState.guideChip(.content, favouritesChip: true, favouritesEmpty: true, favouritesFailed: true), failed,
                       "channels loaded, none to show for the chip: the failure")
        XCTAssertEqual(PageState.guideChip(.empty, favouritesChip: true, favouritesEmpty: true, favouritesFailed: false), .empty,
                       "a successful empty answer: No favourites")
        XCTAssertEqual(PageState.guideChip(.loading, favouritesChip: true, favouritesEmpty: true, favouritesFailed: true), .loading)
        XCTAssertEqual(PageState.guideChip(.content, favouritesChip: true, favouritesEmpty: false, favouritesFailed: true), .content,
                       "favourites known from before: shown")
        XCTAssertEqual(PageState.guideChip(.empty, favouritesChip: false, favouritesEmpty: true, favouritesFailed: true), .empty,
                       "another chip: its own state")
        XCTAssertTrue(PageState.guideSplashReady(failed, rowsEmpty: true), "the splash lands on the error")
    }

    func testAFailedFavouritesRequestIsKeptAndAnsweredByAGoodOne() async throws {
        let failing = Locked(true)
        let http = try LocalHTTPServer { request in
            guard request.path == "/api/library/favourites" else { return .notFound }
            return failing.value ? .json(#"{"error":"down"}"#, status: 500) : .json("[]")
        }
        defer { http.stop() }
        let m = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        await m.loadFavourites()
        XCTAssertNotNil(m.favouritesError)
        XCTAssertEqual(PageState.guideChip(.empty, favouritesChip: true, favouritesEmpty: m.favourites.isEmpty,
                                           favouritesFailed: m.favouritesError != nil), .failed(PageWords.favouritesFailed))
        failing.value = false
        await m.loadFavourites() // Try again
        XCTAssertNil(m.favouritesError)
        XCTAssertEqual(PageState.guideChip(.empty, favouritesChip: true, favouritesEmpty: m.favourites.isEmpty,
                                           favouritesFailed: m.favouritesError != nil), .empty, "now No favourites")
    }
}
