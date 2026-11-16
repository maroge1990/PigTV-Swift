import Foundation

/// #216 (Apple 102), the Top Shelf half of #46: Home's minute and return-to-foreground refresh, moved to the app root
/// (ContentView) so it no longer depends on a tab being on screen. While the app is active and signed in, it brings
/// the guide up to date (the cache, then the network, when nothing is loaded; a version check, then a reload, when it
/// is stale) and the favourites, then exports the Top Shelf, whose "on now" moves with the clock.
@MainActor
enum AppFreshness {
    static let interval: Duration = .seconds(60)
    /// Just under the interval, so each minute's pass finds them stale unless a page has just loaded them.
    static let recordingsMaxAge: TimeInterval = 55

    /// Favourites change only when this device or another edits them, so the minute pass asks at most every 5 minutes
    /// (pages that show them keep the 60 s `appearMaxAge`).
    static let favouritesMaxAge: TimeInterval = 300
    /// How often the loop looks again while the player is up (no request, only a flag read), so a pass follows the
    /// player's closing within about a second.
    static let playerPoll: Duration = .seconds(1)

    /// One pass. `export` is the Top Shelf export (tests count it). #278: while the full-screen player is up nobody can
    /// see the pages underneath, so a pass sends nothing and exports nothing (the retry clock rests with it).
    static func refresh(_ browse: BrowseModel, playing: Bool = false,
                        export: (BrowseModel) -> Void = { $0.exportTopShelf() }) async {
        guard !browse.isFixture, !playing else { return }
        if browse.guide.isEmpty {
            async let guide: Void = browse.loadInitialGuide()
            await browse.loadFavouritesIfStale(maxAge: favouritesMaxAge)
            await guide
        } else {
            await browse.loadFavouritesIfStale(maxAge: favouritesMaxAge)
            await browse.refreshGuideIfStale()
        }
        // #239: recordings and schedules too, so no page needs its own idle timer for them (pages that need them sooner,
        // while something records, ask through the same staleness check).
        await browse.loadRecordingsIfStale(maxAge: recordingsMaxAge, quietly: true)
        // #232 (D-66): the Top Shelf's live games come from the Sport front page's answer, which only its page keeps
        // fresh; with the page elsewhere the pass asks for it, at most once a minute.
        await refreshSportFrontIfStale(browse)
        export(browse)
        // #280 (one retry clock): a guide or recordings list that failed is retried by the next pass, nothing sooner;
        // its error page counts down to it.
        browse.notePolls(recordingsAfter: interval, guideAfter: interval)
    }

    /// #232: the Sport front page's answer, when the server has one (`sportFront`) and the last is older than
    /// `sportFrontMaxAge` (the page polls every 20 to 60 s while it is on screen, so this then sends nothing). tvOS only:
    /// the Top Shelf is its only reader off the page.
    static let sportFrontMaxAge: TimeInterval = 55

    static func refreshSportFrontIfStale(_ browse: BrowseModel, now: Date = Date(), topShelf: Bool = topShelfExists) async {
        guard topShelf, browse.client.info?.features.sportFront == true else { return }
        let front = browse.sportFront
        if let at = front.updatedAt, now.timeIntervalSince(at) < sportFrontMaxAge { return }
        await front.load()
    }

    #if os(tvOS)
    static let topShelfExists = true
    #else
    static let topShelfExists = false
    #endif

    /// #301: the Top Shelf is written once as the app goes to the background, with no request (no pass runs while a
    /// player is up, so what the TV button shows would be as it was when playback began).
    /// #313 item 1: the export runs as background work (a UIApplication background task, `BackgroundWork`), held until
    /// the snapshot is written, so the app is not suspended between the logo loads and the write. `export` and `hold`
    /// are the export and the background task (tests inject them).
    static func exportOnBackground(_ browse: BrowseModel,
                                   export: @escaping @MainActor (BrowseModel) async -> Void = { await $0.exportTopShelfUntilWritten() },
                                   hold: @MainActor (String, @escaping @MainActor () async -> Void) -> Void = BackgroundWork.run) {
        guard !browse.isFixture else { return }
        hold("PigTV: Top Shelf export") { await export(browse) }
    }

    /// A pass now, then one after every `interval` until the task is cancelled (the app leaves the foreground or the
    /// session ends). `sleep` is the clock (tests inject one). #278: while `playing()` is true no pass runs; the loop
    /// only looks again every `playerPoll`, and runs a pass as soon as the player has closed.
    static func run(every interval: Duration = interval,
                    playing: () -> Bool = { false },
                    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    _ pass: () async -> Void) async {
        var wasPlaying = playing()
        if !wasPlaying { await pass() }
        while !Task.isCancelled {
            if playing() {
                wasPlaying = true
                do { try await sleep(playerPoll) } catch { return }
                continue
            }
            if wasPlaying {
                wasPlaying = false
                await pass()
                continue
            }
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            if playing() { wasPlaying = true; continue }
            await pass()
        }
    }
}
