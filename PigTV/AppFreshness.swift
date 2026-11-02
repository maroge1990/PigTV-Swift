import Foundation

/// #216 (Apple 102), the Top Shelf half of #46: Home's minute and return-to-foreground refresh, moved to the app root
/// (ContentView) so it no longer depends on a tab being on screen. While the app is active and signed in, it brings
/// the guide up to date (the cache, then the network, when nothing is loaded; a version check, then a reload, when it
/// is stale) and the favourites, then exports the Top Shelf, whose "on now" moves with the clock.
@MainActor
enum AppFreshness {
    static let interval: Duration = .seconds(60)

    /// One pass. `export` is the Top Shelf export (tests count it).
    static func refresh(_ browse: BrowseModel, export: (BrowseModel) -> Void = { $0.exportTopShelf() }) async {
        guard !browse.isFixture else { return }
        if browse.guide.isEmpty {
            async let guide: Void = browse.loadInitialGuide()
            await browse.loadFavouritesIfStale()
            await guide
        } else {
            await browse.loadFavouritesIfStale()
            await browse.refreshGuideIfStale()
        }
        export(browse)
    }

    /// A pass now, then one after every `interval` until the task is cancelled (the app leaves the foreground or the
    /// session ends). `sleep` is the clock (tests inject one).
    static func run(every interval: Duration = interval,
                    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    _ pass: () async -> Void) async {
        await pass()
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            await pass()
        }
    }
}
