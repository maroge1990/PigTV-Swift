import XCTest
@testable import PigTV

// Codex sign-off of #347 (medium): Try again cleared the favourites' failure as it started, so while the retry waited the
// Guide's Favourites chip showed "No favourites" (and lost its Try again), and a cancelled retry left that in place.
// The failure now stays until a request succeeds, and through a cancellation. (Fails on the commit before.)
@MainActor
final class FavouritesRetryTests: XCTestCase {
    func testTheFailureStaysVisibleThroughADelayedRetry() async throws {
        let mode = Locked("fail")
        let http = try LocalHTTPServer { request in
            guard request.path == "/api/library/favourites" else { return .notFound }
            switch mode.value {
            case "fail": return .json(#"{"error":"down"}"#, status: 500)
            default:
                var slow = LocalHTTPServer.Response.json("[]")
                slow.delay = 0.6
                return slow
            }
        }
        defer { http.stop() }
        let m = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        await m.loadFavourites()
        XCTAssertNotNil(m.favouritesError)
        func chip() -> PageState {
            PageState.guideChip(.empty, favouritesChip: true, favouritesEmpty: m.favourites.isEmpty, favouritesFailed: m.favouritesError != nil)
        }
        mode.value = "slow"
        let retry = Task { await m.loadFavourites() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(chip(), .failed(PageWords.favouritesFailed), "while the retry waits, the failure (and Try again) stays")
        await retry.value
        XCTAssertNil(m.favouritesError)
        XCTAssertEqual(chip(), .empty, "a successful empty answer: No favourites")
    }

    func testACancelledRetryKeepsTheFailure() async throws {
        let mode = Locked("fail")
        let http = try LocalHTTPServer { request in
            guard request.path == "/api/library/favourites" else { return .notFound }
            if mode.value == "fail" { return .json(#"{"error":"down"}"#, status: 500) }
            var slow = LocalHTTPServer.Response.json("[]")
            slow.delay = 5
            return slow
        }
        defer { http.stop() }
        let m = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        await m.loadFavourites()
        mode.value = "slow"
        let retry = Task { await m.loadFavourites() }
        try await Task.sleep(for: .milliseconds(200))
        retry.cancel()
        await retry.value
        XCTAssertNotNil(m.favouritesError, "cancelled: the failure stays")
    }
}
