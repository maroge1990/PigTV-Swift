import Foundation
import Combine

@MainActor
final class BrowseModel: ObservableObject {
    // Audit R05: the published state lives in small stores (BrowseStores.swift)
    // so a screen observes only what it draws. This model publishes nothing
    // itself; its old properties forward to the stores.
    let guideStore = GuideStore()
    let recordingStore = RecordingsStore()
    let library = LibraryStore()
    let actions = ActionState()
    let marks: ScheduleMarks

    var guide: [GuideChannel] { get { guideStore.guide } set { guideStore.guide = newValue } }
    var guideBusy: Bool { get { guideStore.guideBusy } set { guideStore.change(\.guideBusy, to: newValue) } }
    var guideError: String? { get { guideStore.guideError } set { guideStore.change(\.guideError, to: newValue) } }
    var guideHasMore: Bool { get { guideStore.guideHasMore } set { guideStore.change(\.guideHasMore, to: newValue) } }
    /// Later guide pages are being fetched now (not the retry cursor `guideHasMore`).
    var guidePaging: Bool { get { guideStore.guidePaging } set { guideStore.change(\.guidePaging, to: newValue) } }
    /// What the Guide treats as "more channels coming": a page in flight or paging that is still running.
    var guidePagingActive: Bool { guideBusy || guidePaging }
    var window: Date { get { guideStore.window } set { guideStore.change(\.window, to: newValue) } }
    private(set) var guideTotal: Int { get { guideStore.guideTotal } set { guideStore.change(\.guideTotal, to: newValue) } }
    private(set) var guideLoadedAt: Date? { get { guideStore.guideLoadedAt } set { guideStore.change(\.guideLoadedAt, to: newValue) } }
    private(set) var fromCache: Bool { get { guideStore.fromCache } set { guideStore.change(\.fromCache, to: newValue) } }
    private(set) var guideLoadedUntil: Date { get { guideStore.guideLoadedUntil } set { guideStore.change(\.guideLoadedUntil, to: newValue) } }
    private(set) var guideEnded: Bool { get { guideStore.guideEnded } set { guideStore.change(\.guideEnded, to: newValue) } }
    private(set) var guideProgrammesVersion: Int { get { guideStore.guideProgrammesVersion } set { guideStore.guideProgrammesVersion = newValue } }
    var recordings: [Recording] { get { recordingStore.recordings } set { recordingStore.recordings = newValue } }
    var schedules: [ScheduledRecording] { get { recordingStore.schedules } set { recordingStore.schedules = newValue } }
    var recordingsBusy: Bool { get { recordingStore.recordingsBusy } set { recordingStore.change(\.recordingsBusy, to: newValue) } }
    var recordingsError: String? { get { recordingStore.recordingsError } set { recordingStore.change(\.recordingsError, to: newValue) } }
    var favourites: [Channel] { get { library.favourites } set { library.favourites = newValue } }
    var favouritesBusy: Bool { get { library.favouritesBusy } set { library.favouritesBusy = newValue } }
    var favouritesError: String? { get { library.favouritesError } set { library.favouritesError = newValue } }
    var mutationBusy: Bool { get { actions.mutationBusy } set { actions.change(\.mutationBusy, to: newValue) } }
    var actionMessage: String? { get { actions.actionMessage } set { actions.change(\.actionMessage, to: newValue) } }
    /// #148: the clash the last successful schedule() found (nil when none), for callers that word their own notice.
    private(set) var scheduleClash: String?
    /// #329: the last schedule found the game already set to record: what to say instead of "scheduled".
    private(set) var scheduleAlready: String?
    var actionError: String? { get { actions.actionError } set { actions.change(\.actionError, to: newValue) } }
    var scheduledKeys: Set<String> { marks.scheduledKeys }
    var recordingChannels: Set<String> { marks.recordingChannels }
    private var initialGuideLoad: Task<Void, Never>?
    /// Set only by the offline UI fixtures: Home then makes no requests.
    var isFixture = false
    let client: APIClient
    private var guideGeneration = UUID()
    // A1.1: the guide's paging cursor; nil before the first page and once the last has arrived.
    private var guideCursor: String?
    // Ids already appended to `guide` during the current load, kept up to date
    // incrementally instead of being rebuilt from `guide` on every page (that
    // rebuild made paging quadratic in the number of channels).
    private var loadedGuideIds = Set<String>()
    // The server's guide version (`library/guide/version`) tied to the data
    // currently held in `guide`/on disk. Captured once before a full load
    // starts and committed only when that load completes, so a change to the
    // guide mid-load is never masked by a stale "still fresh" version.
    private(set) var guideCacheVersion: String?
    private var loadingVersion: String?
    private var guidePrefetch: Task<Void, Never>?
    // Set during a refresh: the visible guide is kept until the first new page
    // arrives, then replaced, so a background refresh never blanks the grid.
    private var replacePending = false
    /// #360/#361 (C1): the rows on screen are the small first page (`fetchGuidePreview`), not a guide: the full guide's
    /// first page replaces them, and they are never saved, never commit a version and never set `guideLoadedUntil`.
    private(set) var guideIsPreview = false
    /// #360 (G6, C2): a refresh that keeps the rows on screen (`loadGuide(swap: true)`) collects its pages here and swaps
    /// the whole new guide in once its last page has arrived (one change of `guide`); nil otherwise.
    private var stagedGuide: [GuideChannel]?
    private var stagedLoadedAt: Date?
    /// Review of 383-385 (high): the day a staged load asks for. `window`, `guideLoadedUntil`, the version, the total and
    /// the rows on screen stay the old guide's until its last page, and change together then; a staged load that fails
    /// leaves every one of them as it was, so the next freshness pass sees the old guide's real age and coverage.
    private var stagedWindow: Date?
    private var guideExtending = false
    // Private to this server and account (R14); retired on sign-out.
    private let guideCache: GuideCacheStore
    /// A2 (build 48): the Top Shelf generation this session publishes under.
    let topShelfGeneration = TopShelfPublication.shared.current
    /// #362 (review of 373): false for the offline UI fixtures, whose synthetic line-up must never reach the shared Top
    /// Shelf snapshot or prune its cards: their exports then do nothing. True (publishing) everywhere else.
    var publishesTopShelf = true

    init(client: APIClient, accountID: Int? = nil, guideCacheDirectory: URL = GuideCacheStore.defaultDirectory) {
        self.client = client
        marks = ScheduleMarks(following: recordingStore)
        guideCache = GuideCacheStore(scope: CacheScope(address: client.address, accountID: accountID), directory: guideCacheDirectory)
    }

    /// The offline UI fixtures' Settings padding (they make no request).
    var fixtureRecordDefaults: RecordPlan.PadDefaults?

    /// #358: Settings' usual padding for the record page's steppers (`GET /api/settings`, C-M), read every time a record
    /// page opens and never kept: Codex sign-off of 368 (high), a session-long copy went stale once Finish late changed on
    /// the web (5 to 30) and one + sent 6. Nil when it can't be read (the page's steppers then stay off) or the session
    /// has been retired.
    func loadRecordDefaults() async -> RecordPlan.PadDefaults? {
        if isFixture { return fixtureRecordDefaults }
        guard !isRetired, let answer = try? await client.response("settings") else { return nil }
        guard !isRetired else { return nil }
        return RecordPlan.PadDefaults.decode(answer.data)
    }

    /// Sign-out or a server/account switch: delete this account's guide cache
    /// and drop any save still in flight.
    func retirePrivateCaches() {
        // #357 (Codex sign-off of 359-364, high): retired for good, before its workers are cancelled, so a press-time read
        // or a late answer that returns afterwards sends nothing on this session's token.
        isRetired = true
        guideCache.retire()
        // #357 (Codex review of 359-360): an old session's scheduled-list reads stop with it (never sent on its token).
        for worker in reconcilers.values { worker.cancel() }
        reconcilers.removeAll()
        // A2: and its Top Shelf publication: nothing it still exports is written.
        // #362 (review of 374): not for an offline fixture, which never published (its sign-out leaves the Top Shelf alone).
        if publishesTopShelf, topShelfGeneration == TopShelfPublication.shared.current { TopShelfPublication.shared.retire() }
    }

    // Loads the first page immediately, then keeps paging in the background
    // until every channel is present. Filters and search then work locally,
    // and a full day of programme data per channel is already in memory.
    // `preview` (#360/#361, C1; the launch load): with nothing on screen, a small page first (`fetchGuidePreview`).
    // `swap` (#360 G6, C2; the stale-guide refresh and Try again on a guide on screen): the rows on screen stay until the
    // whole new guide has arrived, then it replaces them at once (never page 1's 500 rows first, then the rest).
    // `day` (a staged refresh): the window the new guide is for; it becomes `window` only when that guide is swapped in.
    func loadGuide(reset: Bool = true, keepVisible: Bool = false, preview: Bool = false, swap: Bool = false,
                   day: Date? = nil) async {
        let sp = PigTVSignpost.begin("GuideLoad"); defer { PigTVSignpost.end("GuideLoad", sp) }
        let generation: UUID
        if reset {
            guidePrefetch?.cancel()
            guidePrefetch = nil
            guidePaging = false
            guideGeneration = UUID()
            // Review of 383-385 (medium): this load is claimed before its first await; an overlapping reset (a second
            // Try again) takes the generation from it, and this one stops after its version answer.
            generation = guideGeneration
            guideCursor = nil
            loadedGuideIds = []
            replacePending = keepVisible && !guide.isEmpty
            stagedGuide = swap && replacePending ? [] : nil
            stagedLoadedAt = nil
            if !replacePending { guide = []; guideIsPreview = false }
            if stagedGuide != nil {
                replacePending = false
                stagedWindow = day ?? window
            } else {
                stagedWindow = nil
                if let day { window = day }
                guideTotal = 0
                // Build 33: a fresh load/reload always starts a new one-day
                // window; any in-flight forward extension is stale (the
                // generation bump above makes its result a no-op if it lands).
                guideLoadedUntil = window.addingTimeInterval(GuideNavigation.loadedDuration)
                guideEnded = false
            }
            guideHasMore = false
            guideBusy = true
            // A1.1: captured once before the load starts and committed only on
            // completion, so a version change mid-load is never masked.
            let version = try? await client.guideVersion()
            guard generation == guideGeneration else { return }
            loadingVersion = version
        } else if guideBusy || guidePaging || !guideHasMore {
            return // a page in flight, or the paging already running, has this cursor
        } else {
            generation = guideGeneration
        }
        guideBusy = true
        // #280 (review of 205, H2): the last failure stays until an attempt succeeds (fetchGuidePage clears it), so a
        // retry never swaps the error, or the stale notice, for the loading placeholders while it waits for its answer.
        defer { if generation == guideGeneration { guideBusy = false } }
        // Not while a failure shows: a failing server is asked once per pass, as before (PageStatesTests).
        if reset, preview, guide.isEmpty, guideError == nil {
            await fetchGuidePreview(generation: generation)
            guard generation == guideGeneration else { return }
        }
        await fetchGuidePage(generation: generation)
        // #355: a retried page (`reset: false`) that succeeds with a cursor left resumes the paging too; before, only a
        // fresh load paged on, so the pages after a retried one were never fetched.
        guard generation == guideGeneration, guideHasMore, guideError == nil else { return }
        guidePaging = true
        guidePrefetch = Task { [weak self] in
            defer { if let self, generation == self.guideGeneration { self.guidePaging = false } }
            while !Task.isCancelled {
                guard let self, generation == self.guideGeneration,
                      self.guideHasMore, self.guideError == nil else { return }
                await self.fetchGuidePage(generation: generation)
            }
        }
    }

    /// #360/#361 (C1): the small first page (`GuideNavigation.previewChannels` channels, `previewDuration` from the
    /// window), shown at once while the full guide's first page (500 channels, 24 h) is fetched behind it and replaces it.
    /// Asked once, without the page retries: a failure only leaves the full load to show what it shows. It sets the rows
    /// and the channel total only: no cursor, no loaded time, no version, no save, no Top Shelf export, and
    /// `guideLoadedUntil` stays where the load put it, so moving right past its 6 hours reloads or extends nothing
    /// (`guideBusy` holds both off until the full page has landed); the rows beyond it simply fill in then.
    private func fetchGuidePreview(generation: UUID) async {
        let sp = PigTVSignpost.begin("GuidePage"); defer { PigTVSignpost.end("GuidePage", sp) }
        let start = window.timeIntervalSince1970 * 1000
        let query = [
            URLQueryItem(name: "start", value: String(Int64(start))),
            URLQueryItem(name: "end", value: String(Int64(start + GuideNavigation.previewDuration * 1000))),
            URLQueryItem(name: "limit", value: String(GuideNavigation.previewChannels))
        ]
        guard let answer = try? await client.sizedGuidePage(query: query),
              generation == guideGeneration, guide.isEmpty, !answer.page.channels.isEmpty else { return }
        guide = answer.page.channels
        guideTotal = answer.page.total
        guideIsPreview = true
        replacePending = true
        if guideError != nil { guideError = nil }
        GuidePerf.firstGuidePage(bytes: answer.bytes)
    }

    private func fetchGuidePage(generation: UUID) async {
        let sp = PigTVSignpost.begin("GuidePage"); defer { PigTVSignpost.end("GuidePage", sp) }
        // A1.1: cursor paging, 500 at a time.
        let isFirstPage = guideCursor == nil
        let start = (stagedWindow ?? window).timeIntervalSince1970 * 1000
        var query = [
            URLQueryItem(name: "start", value: String(Int64(start))),
            URLQueryItem(name: "end", value: String(Int64(start + GuideNavigation.loadedDuration * 1000)))
        ]
        query.append(URLQueryItem(name: "limit", value: "500"))
        if let guideCursor { query.append(URLQueryItem(name: "cursor", value: guideCursor)) }
        do {
            let (page, bytes) = try await requestGuidePage(query, generation: generation)
            guard generation == guideGeneration else { return }
            if isFirstPage && guide.isEmpty { GuidePerf.firstGuidePage(bytes: bytes) }
            let staged = stagedGuide != nil
            if staged {
                // C2: collected off screen (in place, one copy of the array) against the same id set as an append.
                let additions = page.channels.filter { loadedGuideIds.insert($0.id).inserted }
                stagedGuide?.append(contentsOf: additions)
                if isFirstPage { stagedLoadedAt = Date() }
            } else if replacePending {
                replacePending = false
                guide = page.channels
                loadedGuideIds = Set(page.channels.map(\.id))
                // C1: the rows replaced were the small page's: told as a programme change, since a guide of 50 channels
                // or fewer keeps its count and ids, and the Guide would keep drawing the small page's 6 hours.
                if guideIsPreview { guideIsPreview = false; guideProgrammesVersion += 1 }
            } else {
                // A single mutation of `guide` per page, against a persistent
                // id set, instead of rebuilding `Set(guide.map(\.id))` (and
                // re-filtering into a fresh array) on every page.
                let additions = page.channels.filter { loadedGuideIds.insert($0.id).inserted }
                // In place on the store: through the forwarding property it would
                // copy the whole array for every page.
                guideStore.guide.append(contentsOf: additions)
            }
            if guideError != nil { guideError = nil }
            if !staged { guideTotal = page.total; fromCache = false }
            guideCursor = page.nextCursor
            guideHasMore = page.nextCursor != nil
            if isFirstPage && !staged { guideLoadedAt = Date() }
            if !guideHasMore, let complete = stagedGuide {
                // C2: the swap. One change of `guide`; told as a programme change too, because the new guide usually has
                // the same channels (count, first and last id) and the Guide would otherwise keep its old rows.
                stagedGuide = nil
                // Review of 383-385 (high): the new day, its loaded edge, its total and its rows, together.
                if let day = stagedWindow { window = day }
                stagedWindow = nil
                guideLoadedUntil = window.addingTimeInterval(GuideNavigation.loadedDuration)
                guideEnded = false
                guideTotal = page.total
                guide = complete
                guideIsPreview = false
                fromCache = false
                guideLoadedAt = stagedLoadedAt ?? Date()
                stagedLoadedAt = nil
                guideProgrammesVersion += 1
            }
            if !guideHasMore {
                guideCacheVersion = loadingVersion
                saveCache()
            }
            // A4.1: the Top Shelf snapshot (first rows / favourites' now-next). C2: a swap exports once, at the swap (until
            // then the guide on screen is the one already exported).
            if (isFirstPage && !staged) || !guideHasMore { exportTopShelf() }
        } catch {
            // A cancelled request (the task that asked went away, URLError's own "cancelled" too) is not a failure.
            guard generation == guideGeneration, !UserMessage.isCancellation(error) else { return }
            guideError = UserMessage.text(for: error) ?? UserMessage.somethingFailed
            // C1: the small page never stands in for a guide whose load failed: the error shows on its own, as it did
            // before the small page existed (and nothing extends or keeps its 6 hours).
            if isFirstPage, replacePending, guideIsPreview {
                replacePending = false
                guideIsPreview = false
                guide = []
                guideTotal = 0
            }
        }
    }

    /// One guide page, retried with backoff (`GuideNavigation.guidePageRetryDelays`)
    /// before rethrowing — the same failed page each time (nothing about
    /// `query` changes between attempts), so a caller that gives up leaves
    /// its paging cursor exactly where a retry can resume it.
    private func requestGuidePage(_ query: [URLQueryItem], generation: UUID) async throws -> (page: GuidePage, bytes: Int) {
        var attempt = 0
        #if DEBUG
        let delays = Self.guidePageRetryDelaysOverride ?? GuideNavigation.guidePageRetryDelays
        #else
        let delays = GuideNavigation.guidePageRetryDelays
        #endif
        while true {
            do { return try await client.sizedGuidePage(query: query) }
            catch {
                guard generation == guideGeneration, !UserMessage.isCancellation(error) else { throw CancellationError() }
                guard attempt < delays.count else { throw error }
                let delay = delays[attempt]
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
                guard generation == guideGeneration else { throw CancellationError() }
            }
        }
    }

    #if DEBUG
    /// Tests (C3): told, as each forward extension's merge runs, whether it runs on the main thread.
    nonisolated(unsafe) static var extendMergeObserver: (@Sendable (_ onMainThread: Bool) -> Void)?
    nonisolated static func noteExtendMerge() { extendMergeObserver?(Thread.isMainThread) }

    // Test seam: shrinks (or removes) the retry backoff so tests can
    // exercise `requestGuidePage`'s retry behaviour without waiting ~20 s in
    // real time. Never read outside DEBUG builds.
    static var guidePageRetryDelaysOverride: [TimeInterval]?
    #endif

    /// The guide error's and stale notice's "Try again": an empty guide (the very first page
    /// never arrived) starts over, a stopped paging resumes from `guideCursor` — wherever it
    /// stopped — instead of restarting the whole guide, and a refresh that failed with every
    /// channel on screen is asked again with those channels kept. #280 (H2): the failure stays
    /// on screen until the attempt succeeds (it was cleared first, so the page showed its
    /// loading shape, or a failed refresh's notice vanished without a request being made).
    func retryGuide() async {
        #if DEBUG
        if fixtureHoldsGuide { return }
        #endif
        if guide.isEmpty || !guideHasMore {
            // A refresh that failed before its first page asks again for the day it was for (review of 383-385).
            await loadGuide(reset: true, keepVisible: true, swap: true, day: stagedWindow)
        } else {
            await loadGuide(reset: false)
        }
    }

    /// Build 33 ("the guide hits a wall moving forward in time"): fetches the
    /// next `GuideNavigation.loadedDuration` slice — every channel, paged the
    /// same way as the initial load — and merges it into the existing rows
    /// (`GuideNavigation.mergeProgrammes`, deduped by start time) instead of
    /// replacing them, so scroll position, focus and the rows array are all
    /// untouched. Programmes far enough in the past are trimmed at the same
    /// time to keep memory bounded over a long session. Called by GuideView
    /// as the viewport approaches the loaded edge (`GuideNavigation.
    /// needsExtension`); guarded so only one extension runs at a time. Ends
    /// for good, with nothing left to retry, once a slice comes back with no
    /// programmes at all — the provider's guide has ended. A page failure is
    /// retried like the initial load; if it still fails, `guideLoadedUntil`
    /// is simply left where it was and the next viewport move tries again.
    func extendGuideForward() async {
        guard !guideExtending, !guideEnded, !guideBusy, !guideHasMore, !guide.isEmpty, !guideIsPreview else { return }
        let sp = PigTVSignpost.begin("GuideExtend"); defer { PigTVSignpost.end("GuideExtend", sp) }
        guideExtending = true
        defer { guideExtending = false }
        let generation = guideGeneration
        let sliceStart = guideLoadedUntil
        let sliceEnd = sliceStart.addingTimeInterval(GuideNavigation.loadedDuration)
        let sliceQueryTimes = [
            URLQueryItem(name: "start", value: String(Int64(sliceStart.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "end", value: String(Int64(sliceEnd.timeIntervalSince1970 * 1000)))
        ]
        var merged: [String: [GuideProgramme]] = [:]
        var anyProgrammes = false
        var cursor: String?
        while true {
            var query = sliceQueryTimes
            query.append(URLQueryItem(name: "limit", value: "500"))
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: GuidePage
            do { page = try await requestGuidePage(query, generation: generation).page }
            catch { return } // transient: guideLoadedUntil unchanged, retried on the next viewport move
            guard generation == guideGeneration else { return }
            for channel in page.channels where !channel.programmes.isEmpty {
                merged[channel.id, default: []].append(contentsOf: channel.programmes)
                anyProgrammes = true
            }
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        guard generation == guideGeneration else { return }
        guard anyProgrammes else { guideEnded = true; return }
        let keepFrom = Date().addingTimeInterval(-GuideNavigation.pastTrimMargin)
        // #360 (G7, C3): the merge and trim (every channel) run off the main actor on value copies; the result comes back
        // in one assignment. A reload or a refresh (a new generation) or a sign-out meanwhile wins: the result is dropped.
        let current = guide
        let slice = merged
        let updated = await Task.detached(priority: .userInitiated) {
            #if DEBUG
            BrowseModel.noteExtendMerge()
            #endif
            return GuideNavigation.extended(current, with: slice, keepFrom: keepFrom)
        }.value
        guard generation == guideGeneration, !isRetired else { return }
        guide = updated
        guideLoadedUntil = sliceEnd
        guideProgrammesVersion += 1
    }

    /// The first guide load, shared by whichever screen appears first (Home
    /// or the Guide): the cached guide when it still covers the present,
    /// then the network. A second caller waits for the same load.
    func loadInitialGuide() async {
        #if DEBUG
        if fixtureHoldsGuide { return }
        #endif
        if let initialGuideLoad { await initialGuideLoad.value; return }
        guard guide.isEmpty else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            // Review of 387-388 (medium): a load started while the cached guide's version answer was awaited (Jump to…)
            // owns the guide: this launch's fallback reset must not take its generation (and refetch its first page).
            let generation = self.guideGeneration
            await self.loadCachedGuide()
            guard generation == self.guideGeneration else { return }
            if self.guide.isEmpty || self.fromCache {
                if !self.fromCache {
                    self.window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
                }
                await self.loadGuide(reset: true, keepVisible: self.fromCache, preview: true)
            }
        }
        initialGuideLoad = task
        await task.value
        initialGuideLoad = nil
    }

    // Cached guide: used only while nothing is loaded, and only if it still
    // covers the present. The network load that follows replaces it, unless a
    // version check (below) shows that load is unnecessary.
    func loadCachedGuide() async {
        guard guide.isEmpty else { return }
        let store = guideCache
        let cached: GuideCache? = await Task.detached(priority: .userInitiated) {
            guard let data = store.load() else { return nil }
            return try? JSONDecoder().decode(GuideCache.self, from: data)
        }.value
        guard let cached, guide.isEmpty,
              cached.savedAt > Date().addingTimeInterval(-12 * 3600),
              cached.window <= Date(), cached.window.addingTimeInterval(GuideNavigation.loadedDuration) > Date().addingTimeInterval(4 * 3600) else { return }
        window = cached.window
        guide = cached.channels
        guideTotal = cached.channels.count
        fromCache = true
        guideCacheVersion = cached.version
        loadedGuideIds = Set(cached.channels.map(\.id))
        guideLoadedUntil = cached.window.addingTimeInterval(GuideNavigation.loadedDuration)
        guideEnded = false
        exportTopShelf()
        _ = await tryMarkFreshByVersion()
    }

    private func saveCache() {
        let snapshot = GuideCache(savedAt: Date(), window: window, channels: guide, version: guideCacheVersion)
        let store = guideCache
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { store.save(data) }
        }
    }

    // A1.1: a cheap version check (`library/guide/version`) that avoids a
    // full guide download when nothing has changed and the loaded window
    // still covers the near future. Updates freshness state and returns true
    // when it did so; a failed fetch falls back to the normal reload.
    /// Review of 386 (medium): the answer counts only for the guide it was asked about. A load started while it was in flight
    /// (Jump to…, a reload) owns the guide now: the answer changes nothing (false; the caller revalidates too).
    private func tryMarkFreshByVersion(now: Date = Date()) async -> Bool {
        guard !guide.isEmpty else { return false }
        let generation = guideGeneration
        guard let serverVersion = try? await client.guideVersion(), generation == guideGeneration else { return false }
        guard GuideNavigation.guideStillCovers(cachedVersion: guideCacheVersion, serverVersion: serverVersion,
                                                window: window, now: now) else { return false }
        fromCache = false
        guideLoadedAt = now
        return true
    }

    // Refresh in place when the loaded day is getting stale.
    // Review of 383-385 (medium): a load still paging (a staged refresh on a slow connection) is joined, never restarted;
    // a staged refresh whose paging stopped on a failure resumes from its cursor (the same day and limit: the server's
    // cursor is an offset into that query), and is committed only when its last page arrives.
    func refreshGuideIfStale(maxAge: TimeInterval = 4 * 3600) async {
        let loaded = guideLoadedAt ?? .distantPast
        guard fromCache || Date().timeIntervalSince(loaded) > maxAge, !guideBusy, !guidePaging else { return }
        if stagedGuide != nil, guideHasMore {
            await loadGuide(reset: false)
            return
        }
        // Review of 386 (medium): a load started while the version answer was awaited (Jump to…'s day) is newer than this
        // pass: its paging is never cancelled for the day this pass was about.
        let generation = guideGeneration
        if await tryMarkFreshByVersion() { return }
        guard generation == guideGeneration, !guideBusy, !guidePaging else { return }
        await loadGuide(reset: true, keepVisible: true, swap: true,
                        day: GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn))
    }

    func guideChannel(id: String) -> GuideChannel? {
        guideStore.channel(id: id)
    }
    func programmes(for channel: Channel) -> [GuideProgramme] {
        guideChannel(id: channel.id)?.programmes ?? []
    }
    func asChannel(_ channel: GuideChannel) -> Channel {
        Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name,
            logo: logo(for: channel), category: channel.category, now: nil, next: nil, stableId: channel.stableId,
            number: number(for: channel), measured: channel.measured?.known)
    }
    // C-A: the channel's number, a label only.
    func number(for channel: GuideChannel) -> Int? { channel.number }
    // C-G: the guide marks a channel unreliable from its `health`.
    func isFlaky(_ channel: GuideChannel) -> Bool { channel.health == "flaky" }
    // C-X (#265, Mark 9 Nov 2026): a channel's picture quality, with `channelQuality` (an older server, or a stale
    // cache, has none). The record page shows any label; the guide's channel column only the two that tell you
    // something (`guideQuality`): UHD, and SD as a warning. Plain HD is nearly every channel, so it shows nothing.
    func quality(of channel: GuideChannel) -> SportQuality? {
        client.info?.features.channelQuality == true ? SportQuality(label: channel.quality) : nil
    }
    func guideQuality(of channel: GuideChannel) -> SportQuality? {
        quality(of: channel).flatMap { $0 == .uhd || $0 == .sd ? $0 : nil }
    }
    /// D-67 (#265): a channel's measured quality: its own, else its guide row's; nil when the server has not measured it.
    func measured(for channel: Channel) -> MeasuredQuality? {
        channel.measured?.known ?? guideChannel(id: channel.id)?.measured?.known
    }
    // The row's own logo, or nil when it has none.
    func logo(for channel: GuideChannel) -> String? { logo(current: channel.logo) }
    func logo(for channel: Channel) -> String? { logo(current: channel.logo) }
    private func logo(current: String?) -> String? {
        guard let current = current?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty else { return nil }
        return current
    }

    // MARK: Loads that screens repeat on appear (build 31)
    //
    // Mark: "switching between the five tabs is slow … it seems to get stuck
    // loading the one you moved from". Every tab reloaded favourites,
    // recordings (and Home the history) each time it appeared, and every
    // load published several changes (busy, data, error, busy) that
    // re-rendered all five tabs, since they all observe this model. Now a
    // tab's appearance loads only what is older than `appearMaxAge`; unchanged
    // data, errors and flags are not re-published. Explicit Refresh/Retry
    // and the periodic refreshes still call the plain loads.

    static let appearMaxAge: TimeInterval = 60
    private var lastLoads: [String: Date] = [:]
    private var recordingsLoading = false
    /// #345 (Codex review): the recordings load in flight, which a second caller joins instead of returning before it
    /// has an answer; and when a load last published its answer (freshness for a choice made from the list).
    private var recordingsInFlight: RecordingsLoad?
    /// A recordings load: `files`, the `/recordings` answer (nil when it arrived and was published, else its error);
    /// `task`, the whole load (with `/recordings/scheduled`).
    private struct RecordingsLoad {
        let id: UUID
        let began: Date
        let files: Task<Error?, Never>
        let task: Task<Void, Never>
    }
    private(set) var recordingsPublishedAt: Date?

    private func isFresh(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        lastLoads[key].map { now.timeIntervalSince($0) < maxAge } ?? false
    }

    /// #239: every view that wants recordings current asks through here, so two pages (or a page and the app's minute
    /// loop, AppFreshness) asking within `maxAge` of each other make one request.
    func loadRecordingsIfStale(maxAge: TimeInterval = appearMaxAge, quietly: Bool = false) async {
        // The offline fixture has no server: a failed load would only add a
        // "Could not connect" banner (or, on a machine with a server, replace it).
        guard !isFixture, !isFresh("recordings", maxAge: maxAge) else { return }
        await loadRecordings(quietly: quietly)
    }

    /// #345: the recordings to choose from (a finished game's Sport card): joins a load in flight, then loads unless the
    /// last recordings answer is younger than `maxAge`. Nil when there is no answer that fresh (the loads failed): the
    /// caller then chooses nothing rather than from a stale list.
    func freshRecordings(maxAge: TimeInterval, now: () -> Date = { Date() }) async -> [Recording]? {
        guard !isFixture else { return recordings }
        // Codex sign-off: only the `/recordings` answer is waited for, never the scheduled list after it.
        if let inFlight = recordingsInFlight { _ = await inFlight.files.value }
        if let at = recordingsPublishedAt, now().timeIntervalSince(at) < maxAge { return recordings }
        _ = await beginRecordingsLoad(quietly: true).files.value
        if let at = recordingsPublishedAt, now().timeIntervalSince(at) < maxAge { return recordings }
        return nil
    }

    func loadFavouritesIfStale(maxAge: TimeInterval = appearMaxAge) async {
        guard !isFresh("favourites", maxAge: maxAge) else { return }
        await loadFavourites()
    }

    #if DEBUG
    /// Tests: when the favourites were last loaded, so a test can age them without waiting.
    func setFavouritesLoaded(at date: Date) { lastLoads["favourites"] = date }
    #endif

    /// `quietly`: a refresh nobody asked for (Home's minute loop, the Guide's
    /// periodic one) does not raise `recordingsBusy`, so the Recordings tab
    /// is not re-rendered, twice, by a refresh that finds nothing new.
    /// A call while one is in flight waits for that one's answer (#345, Codex review: it returned at once, before
    /// anything was published).
    func loadRecordings(quietly: Bool = false) async {
        await beginRecordingsLoad(quietly: quietly).task.value
    }

    /// After a write (a schedule made, changed or cancelled): a load whose reads began after `write`. A load in flight
    /// that began before it is waited out, never joined: its scheduled list may have been read before the write (Codex
    /// sign-off of #347: the new schedule was then missing from the list `schedule()` returned with).
    func loadRecordings(startedAfter write: Date) async {
        while let inFlight = recordingsInFlight, inFlight.began < write { await inFlight.task.value }
        await beginRecordingsLoad(quietly: false).task.value
    }

    /// The load in flight, else a new one: its `/recordings` answer is published as soon as it arrives (#345), then the
    /// scheduled list is asked for.
    private func beginRecordingsLoad(quietly: Bool) -> RecordingsLoad {
        if let inFlight = recordingsInFlight { return inFlight }
        let id = UUID()
        let began = Date()
        lastLoads["recordings"] = began
        recordingsLoading = true
        if !quietly { recordingsBusy = true }
        let files = Task { await self.fetchRecordingFiles() }
        let task = Task {
            await self.fetchRecordings(quietly: quietly, began: began, files: files)
            if self.recordingsInFlight?.id == id { self.recordingsInFlight = nil }
        }
        let load = RecordingsLoad(id: id, began: began, files: files, task: task)
        recordingsInFlight = load
        return load
    }

    /// `/recordings`: published, and timed, when its own answer arrives (#345, Codex sign-off), not after the scheduled
    /// list's. Its error when it failed (the whole load's), else nil.
    private func fetchRecordingFiles() async -> Error? {
        do {
            let loaded: [Recording] = try await client.decodedOffMain("recordings")
            // Apple 125: nothing the server confirmed removed comes back from a list fetched before (or around) it.
            let files = loaded.filter { recordingStore.tombstones[RecordingsHome.key($0)] == nil }
            if files != recordings { recordings = files }
            recordingsPublishedAt = Date()
            return nil
        } catch {
            return error
        }
    }

    private func fetchRecordings(quietly: Bool, began: Date, files: Task<Error?, Never>) async {
        let sp = PigTVSignpost.begin("RecordingsLoad"); defer { PigTVSignpost.end("RecordingsLoad", sp) }
        // #280 (review of 205, H2): the last failure stays until a request succeeds, so a poll or "Try again" never swaps
        // the error for the loading placeholders, or makes the stale notice blink, while it waits for its answer.
        defer { recordingsLoading = false; if !quietly { recordingsBusy = false } }
        do {
            if let failure = await files.value { throw failure }
            let read = try await readSchedules()
            // A list asked for before one already published is older than it (Codex check of 320): not published, and
            // it settles nothing the newer one has not. Published here, where it is used (Codex sign-off of #347).
            if scheduleTickets.publish(read.ticket) { publishSchedules(read) }
            settleTombstones(loadedSince: began) { !$0.hasPrefix("rule:") }
            recordingStore.updatedAt = Date()
            if recordingsError != nil { recordingsError = nil }
            recordingStore.change(\.loaded, to: true)
        } catch {
            // A cancelled request is not a failure (and must not clear one either).
            guard !UserMessage.isCancellation(error) else { return }
            recordingsError = UserMessage.text(for: error) ?? UserMessage.somethingFailed
        }
    }

    // MARK: Page states (#280)

    /// #280: what an action that did not work says: `plain` (what could not be done), or a sentence the server or this
    /// app wrote to be shown (C-B, #147); never the system's description of the error or a code. Nil when it was
    /// cancelled (not a failure).
    static func actionText(_ plain: String, _ error: Error) -> String? {
        if UserMessage.isCancellation(error) { return nil }
        switch error as? PigTVError {
        case .serverMessage(let text, _), .viewerConflict(let text), .message(let text): return text
        // Trying again cannot help an account the server refuses: say so (review of 206, low 8).
        case .forbidden: return PigTVError.forbidden.errorDescription ?? plain
        default: return plain
        }
    }

    /// What the TV Guide shows (and Search, which looks through it).
    var guideState: PageState {
        PageState.guide(channels: guide.count, busy: guideBusy, paging: guideHasMore, failed: guideError != nil,
                        loadedAt: guideLoadedAt)
    }

    /// What a page drawn from the recordings answer shows (`isEmpty`: what it lists is empty), with `failure` its words.
    func recordingsState(isEmpty: Bool, failure: PageFailure = PageWords.recordingsFailed) -> PageState {
        PageState.list(loaded: recordingStore.loaded, isEmpty: isEmpty, failed: recordingsError != nil,
                       since: recordingStore.updatedAt, failure: failure)
    }

    /// One retry clock (#280): the polling says when it asks next. Published only while that list has failed (it is the
    /// failed page's countdown), so a healthy page is not redrawn by it.
    func notePolls(recordingsAfter recordings: Duration?, guideAfter guide: Duration?) {
        if let recordings, recordingsError != nil { recordingStore.schedule = RefreshSchedule(after: recordings) }
        if let guide, guideError != nil, self.guide.isEmpty { guideStore.schedule = RefreshSchedule(after: guide) }
    }

    func loadFavourites() async {
        guard !favouritesBusy else { return }
        lastLoads["favourites"] = Date()
        favouritesBusy = true
        // Codex sign-off of #347: a failure stays until a request succeeds. Cleared as a retry started, the Guide's
        // Favourites chip fell back to "No favourites" (and lost its Try again) while it waited, and for good when the
        // retry was cancelled.
        defer { favouritesBusy = false }
        do {
            let loaded: [Channel] = try await client.request("library/favourites")
            if loaded != favourites { favourites = loaded }
            if favouritesError != nil { favouritesError = nil }
            if !library.favouritesAnswered { library.favouritesAnswered = true }
            exportTopShelf()
        }
        catch {
            guard !UserMessage.isCancellation(error) else { return } // cancelled: what was shown stays
            favouritesError = UserMessage.text(for: error)
            if !library.favouritesAnswered { library.favouritesAnswered = true }
        }
    }

    /// The guide's row for a channel: by id, else by stable identity (a
    /// playlist reorder changes the id but not the identity).
    func guideRow(id: String, identityKey: String) -> GuideChannel? {
        if let row = guideChannel(id: id) { return row }
        guard identityKey != id else { return nil }
        return guide.first { $0.identityKey == identityKey }
    }

    // MARK: Sport (C-I)

    /// Sport events (the Guide's "Watch on…").
    private(set) lazy var sport = SportModel(client: client)
    var sportEnabled: Bool { client.info?.features.sportsEvents == true }
    /// C-P (#21): the Formula 1 page, only with the server's `sportPages` flag.
    private(set) lazy var f1Page = F1PageModel(client: client)
    var sportPagesEnabled: Bool { client.info?.features.sportPages == true }
    /// C-Q (#21): the NFL page, only with the server's `sportPageNfl` flag.
    private(set) lazy var nflPage = NFLPageModel(client: client)
    var nflPageEnabled: Bool { client.info?.features.sportPageNfl == true }
    /// C-S (#21): the Cricket page, only with the server's `sportPageCricket` flag.
    private(set) lazy var cricketPage = CricketPageModel(client: client)
    var cricketPageEnabled: Bool { client.info?.features.sportPageCricket == true }
    /// C-T (#21, D-43): any team league's page, only for the leagues the server's `sportPageLeagues` lists.
    private(set) lazy var leaguePages = LeaguePageModel(client: client)
    var leaguePageLeagues: [String] { client.info?.features.sportPageLeagues?.items ?? [] }
    /// C-V (#197, D-43): the tennis, golf, UFC, IndyCar and NASCAR pages, only with the server's `sportPageEvents` flag.
    private(set) lazy var eventPages = SportEventsPageModel(client: client)
    var eventPagesEnabled: Bool { client.info?.features.sportPageEvents == true }
    /// C-R (#21, D-39): the Sport front page (the Sport tab).
    private(set) lazy var sportFront = SportFrontModel(client: client)
    /// #232: the minute pass has asked for the account's Hide scores for the Top Shelf this session (`AppFreshness`).
    var topShelfPreferencesAsked = false
    /// #214: the Sport tab's pushed sport pages (the tab bar returns it to the front page).
    private(set) lazy var sportNavigation = SportNavigation()
    /// C-U (#200): Settings › Sport, only with the server's `sportFollows` flag. A spoiler-free change saved there makes
    /// the sport pages (whose preferences the F1 page model holds) ask for the choice again.
    private(set) lazy var sportFollows: SportFollowSettingsModel = {
        let model = SportFollowSettingsModel(client: client)
        // #278: its "Record every game" switches read and change the one set of rules (Scheduled's).
        model.ruleOwner = self
        model.onSpoilerFreeChange = { [weak self] in
            guard let self else { return }
            let pages = self.f1Page
            pages.invalidatePreferences()
            // #232 (D-66): the saved Top Shelf drops its scores at once (the choice is unknown until it is read again, and
            // unknown hides); the next export, once the choice is read, writes what it allows.
            if self.publishesTopShelf { TopShelfExport.hideScores(generation: self.topShelfGeneration) }
            Task { [weak self] in
                await pages.revalidatePreferences()
                self?.exportTopShelf()
            }
        }
        return model
    }()
    var sportFollowsEnabled: Bool { client.info?.features.sportFollows == true }

    /// The Channel the player needs for one of an event's channels: its
    /// guide row when loaded (logo fallback, stable identity), else the
    /// event's own fields.
    func playable(_ channel: SportEventChannel) -> Channel {
        let row = guideRow(id: channel.id, identityKey: channel.identityKey)
        return Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name, logo: logo(for: channel),
                       category: row?.category, now: nil, next: nil, stableId: channel.stableId ?? row?.stableId,
                       number: channel.number ?? row?.number, measured: channel.measured ?? row?.measured?.known)
    }

    /// The logo to draw for an event's channel (the event's, else the guide's).
    func logo(for channel: SportEventChannel) -> String? {
        if let logo = channel.logo { return logo }
        return guideRow(id: channel.id, identityKey: channel.identityKey).flatMap { logo(for: $0) }
    }

    /// A guide row for recording an event on one of its channels: the event
    /// is the only programme, so `schedule` records exactly its times.
    func recordingRow(_ event: SportEvent, on channel: SportEventChannel) -> GuideChannel {
        GuideChannel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name, logo: logo(for: channel),
                     category: nil, programmes: [event.programme(on: channel)], stableId: channel.stableId, number: channel.number)
    }

    /// True when a recording of this event on this channel is scheduled.
    func isScheduled(_ event: SportEvent, on channel: SportEventChannel) -> Bool {
        scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: event.airing(on: channel).start))
    }

    // Matched on the stable identity (server 0097): one favourite covers every
    // listing of a cross-listed channel, as it does on the server.
    func isFavourite(_ channel: Channel) -> Bool {
        favourites.contains { $0.identityKey == channel.identityKey || $0.id == channel.id }
    }

    // Used by the player's action row; the favourites list is reloaded so the
    // guide filter and the heart stay in agreement with the server.
    func setFavourite(_ channel: Channel, _ value: Bool) async -> Bool {
        do {
            let result: ActionResult = try await client.request("favorites", method: value ? "POST" : "DELETE",
                body: FavouriteBody(sourceId: channel.sourceId, itemId: channel.rawID))
            guard result.success else { return false }
            await loadFavourites()
            return true
        } catch { return false }
    }

    /// `before`/`after` nil: the server's own start-early and finish-late minutes (D-44's "Record this programme").
    /// `gameId` (C-M since 0440): a Sport card's game, so the recording stops when the game ends.
    /// `guideEnd` (C-R #353): the airing's own guide end when `programme.endTime` is rolled on for an overrun; the
    /// Cancelling… check uses guide bounds, while `programEnd` still sends the rolled end (C-M unchanged).
    /// `context` (Codex sign-off of #347): the sport request and the airing being recorded, so the write is checked by the
    /// same rule as the page shows (its slots resolve each cancelling schedule to its own guide slot); never a stricter one.
    func schedule(channel: GuideChannel, programme: GuideProgramme, guideEnd: Double? = nil, before: Int?, after: Int?,
                  gameId: String? = nil, context: (request: RecordRequest, airing: RecordRequest.Airing)? = nil) async -> Bool {
        // The request is checked before anything else happens (Codex review of 320: never settle a cancellation for a
        // request that is then refused).
        guard programme.end > Date(), programme.end > programme.start else {
            actionError = "This programme has ended. Refresh the guide to choose another programme."
            return false
        }
        // Mark, 19 Nov 2026: while an earlier recording of this (the same game, or this channel's overlapping airing) is
        // being cancelled, recording it again is not offered; a path that still gets here is refused, never raced.
        let waits = context.map { cancellingEarlier($0.request, airing: $0.airing) }
            ?? cancellingEarlier(gameId: gameId, channel: channel, start: programme.startTime, end: guideEnd ?? programme.endTime)
        if waits {
            actionError = PageWords.cancellingEarlierText
            return false
        }
        guard !mutationBusy else { return false }
        // #357 (Codex sign-off of 359-364, high): never on a retired session's token.
        guard !isRetired else { return false }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        scheduleClash = nil
        scheduleAlready = nil
        defer { mutationBusy = false }
        do {
            let made: ScheduledRecording = try await client.request("recordings/schedule", method: "POST",
                body: ScheduleBody(sourceId: channel.sourceId, channelItemId: channel.rawID,
                    channelName: channel.name, channelLogo: channel.logo, title: programme.title,
                    description: programme.description, programStart: programme.startTime,
                    programEnd: programme.endTime, preBufferMin: before, postBufferMin: after, gameId: gameId))
            await loadRecordings(startedAfter: Date())
            // Codex sign-off of #347 (high): an older server answers with the existing schedule of the channel and start,
            // whatever its game. One naming another game is not this game's recording: nothing was made for it.
            if let gameId, let named = made.game, named != gameId {
                actionError = PageWords.slotTakenText
                return false
            }
            // #329: the game was already set to record (perhaps on another channel): that one stands, nothing new.
            if let already = made.alreadyScheduledText {
                scheduleAlready = already
                actionMessage = already
            } else if let clash = made.clashText(in: schedules) {
                // #12 (D-28): a clash is said when scheduling, never found later as a wait or a miss.
                scheduleClash = clash
                actionMessage = "Recording scheduled. \(clash)"
            } else {
                actionMessage = "Recording scheduled. You can review it in Recordings."
            }
            PigHaptic.play(.record)
            return true
        } catch PigTVError.scheduleRefused(let code, let refusedBy) {
            guard !isRetired else { return false } // answered after sign-out: nothing more on its token (#357)
            // The server's refusal (0876+): the lists are read again, so the page shows why (Cancelling…, or the slot's
            // own schedule), and nothing was made.
            // #347 finding 2 (Codex sign-off, medium): a "cancelling" refusal names the schedule being cancelled. The
            // airing tried waits at once (Cancelling… on the page whatever the reload below does, which stops at a failed
            // `/recordings` before reading the scheduled list), tied to the airing as well as the schedule, so it waits
            // even when the list on show has no such row (#357, Codex review of 359-360: one made and cancelled on another
            // device since the press read). Its own scheduled-list reads go on until an accepted read asked for after the
            // refusal shows that schedule not "cancelling", or gone (`publishSchedules`, `reconcileLostRemoval`).
            if code == "cancelling", let refusedBy {
                let key = PendingRemoval.key(.cancelSchedule, refusedBy)
                let refusal = RefusedAiring(
                    scheduleId: refusedBy, gameId: gameId, sourceId: channel.sourceId, rawID: channel.rawID,
                    stableId: channel.stableId, channelName: channel.name, start: programme.startTime,
                    end: guideEnd ?? programme.endTime, since: Date())
                // Codex sign-off of 359-364 (medium): added to the schedule's other refused airings, never over them (a
                // Sport attempt on one channel and a Guide attempt on another both wait); the same airing again is
                // held from this, the later refusal.
                var held = (recordingStore.refusedAirings[key] ?? []).filter { !$0.sameAiring(refusal) }
                held.append(refusal)
                recordingStore.refusedAirings[key] = held
                startReconciling(key)
            }
            await loadRecordings(startedAfter: Date())
            actionError = code == "cancelling" ? PageWords.cancellingEarlierText : PageWords.slotTakenText
            return false
        } catch {
            actionError = Self.actionText(PageWords.scheduleUnconfirmed, error)
            return false
        }
    }

    /// The record page's Record for a sport airing (Codex sign-off of #347, high): the scheduled list is read fresh at the
    /// press, and only a successful answer lets it go on, so a cancellation another device started since the last poll is
    /// seen (Cancelling…) before anything is sent; then the page's own per-airing rule, then the write. A server that
    /// still finds the airing being cancelled answers 409 "cancelling" (`schedule()`): the lists are read again, the
    /// page shows Cancelling… for that airing and stays open.
    /// #347 finding 1 (Codex sign-off, high): only the press-time read's own answer authorizes the write. One that loses
    /// its ticket check to a newer list (a poll answered first) is discarded, and the list on show is then not what the
    /// press read: it is read once more, and if that is superseded too (or any read fails) nothing is sent.
    /// Signed out or switched while a read was out (#357, Codex sign-off of 359-364, high): nothing is sent and nothing
    /// is said (the session has gone).
    func record(_ request: RecordRequest, airing: RecordRequest.Airing, before: Int?, after: Int?) async -> Bool {
        var outcome = await readSchedulesOnce()
        guard !isRetired else { return false }
        if outcome == .superseded {
            outcome = await readSchedulesOnce()
            guard !isRetired else { return false }
        }
        guard outcome == .published else {
            actionError = PageWords.scheduleCheckFailed
            return false
        }
        if cancellingEarlier(request, airing: airing) {
            actionError = PageWords.cancellingEarlierText
            return false
        }
        return await schedule(channel: airing.channel, programme: airing.programme, guideEnd: airing.guideEnd,
                              before: before, after: after, gameId: request.gameId, context: (request, airing))
    }

    /// An accepted scheduled-list read: when it was asked for, and an open record page waiting on one is told.
    private func noteScheduleRead(_ askedAt: Date) {
        recordingStore.schedulesAskedAt = askedAt
        if recordingStore.readWaiters > 0 { recordingStore.readsSeen += 1 }
    }

    /// What one scheduled-list read came to: `published` (its answer is the list on show), `superseded` (it answered, but
    /// a newer list was published first, so its answer was discarded), or `failed` (no answer).
    enum ScheduleReadOutcome: Equatable { case published, superseded, failed }

    /// One read of the scheduled list now, published when it is the newest: true when it answered.
    @discardableResult
    func readSchedulesNow() async -> Bool {
        await readSchedulesOnce() != .failed
    }

    /// One read of the scheduled list now, published when it is the newest (#347 finding 1: the press needs to know which).
    func readSchedulesOnce() async -> ScheduleReadOutcome {
        guard let read = try? await readSchedules() else { return .failed }
        guard scheduleTickets.publish(read.ticket) else { return .superseded }
        publishSchedules(read)
        return .published
    }

    /// An accepted (newest) scheduled-list read, by any reader: shown, and it settles every cancellation in progress
    /// marked before it was asked for (#357, Codex review of 359-360: any such read, not only a cancellation's own).
    /// A removal with no answer is settled by a list asked for after it: the row there (it stands) or not (gone). A row
    /// still listed "cancelling" keeps it in progress (#347), so its own reads go on until the server has finished (Codex
    /// check of 320: a refresh then ended them, and the row stayed "cancelling").
    private func publishSchedules(_ read: ScheduleRead) {
        let stones = recordingStore.tombstones
        let planned = read.list.filter { stones[RecordingsHome.key($0)] == nil }
        if planned != schedules { schedules = planned }
        noteScheduleRead(read.askedAt)
        let unsure = recordingStore.uncertainRemovals.filter { $0.value >= read.askedAt || read.cancelling.contains($0.key) }
        if unsure.count != recordingStore.uncertainRemovals.count { recordingStore.uncertainRemovals = unsure }
        // Each refused airing by its own refusal: one made after this read was asked for still waits.
        var refused: [String: [RefusedAiring]] = [:]
        for (key, airings) in recordingStore.refusedAirings {
            let held = read.cancelling.contains(key) ? airings : airings.filter { $0.since >= read.askedAt }
            if !held.isEmpty { refused[key] = held }
        }
        if refused != recordingStore.refusedAirings { recordingStore.refusedAirings = refused }
    }

    func cancel(_ item: ScheduledRecording) async {
        guard !mutationBusy else { return }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let updated: ScheduledRecording = try await client.request("recordings/scheduled/\(item.id)", method: "DELETE")
            guard !updated.canCancel else {
                throw PigTVError.message("The server still lists this recording as active. Refresh, then try again.")
            }
            actionMessage = "Schedule cancelled or recording stopped."
            await loadRecordings(startedAfter: Date())
        } catch { actionError = Self.actionText(PageWords.cancelFailed, error) }
    }

    static let cannotChangeText = "This server can't change recordings yet."

    /// C-M since 0444 (Apple 114, the record page's Change recording): a schedule's padding. Only the fields given are
    /// sent (Start early not once it records: 409). An older server has no such route (404/405): it says so rather than
    /// failing quietly; a 404 for a schedule that has finished or gone says that. The server's own words for a value it
    /// refuses (400, 409) are shown. True when it changed.
    func changeSchedule(_ item: ScheduledRecording, _ change: ScheduleChangeBody) async -> Bool {
        guard !mutationBusy else { return false }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let _: ScheduledRecording = try await client.request("recordings/scheduled/\(item.id)", method: "PUT", body: change)
            actionMessage = "Recording changed."
            await loadRecordings(startedAfter: Date())
            return true
        } catch PigTVError.http(405) {
            actionError = Self.cannotChangeText
        } catch PigTVError.http(404) {
            await loadRecordings()
            actionError = schedules.contains(where: { $0.id == item.id && $0.isActive })
                ? Self.cannotChangeText : "This recording has finished or no longer exists."
        } catch PigTVError.serverMessage(let text, _) {
            // A 409 usually means it changed meanwhile (it started recording): the list says how it is now.
            await loadRecordings()
            actionError = text
        } catch {
            actionError = Self.actionText(PageWords.changeFailed, error)
        }
        return false
    }

    /// An Undo whose time ran out (Codex, batch 4 high): `cancel` returns at once while another change is in flight,
    /// so the committed cancel waits for that change to finish instead of being dropped.
    func cancelCommitted(_ item: ScheduledRecording) async {
        await waitForMutation()
        await cancel(item)
    }

    /// Until no other change is in flight (each mutation returns at once while one is).
    func waitForMutation() async {
        while mutationBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Undo (Apple 122, D-44 point 9; persisted since 124)

    /// The removals this process has committed and not yet seen confirmed (shared by every session; tests use their own).
    var removalLog = PendingRemovalLog.shared
    /// The app's Undo presenter (set by `AppModel`), so Settings › Sport can settle a removal's open Undo (#301).
    weak var presenter: AppPresenter?

    /// This server and account, for the removal log (nil without an account: then nothing is persisted).
    private var removalScope: String? {
        client.accountID.map { CacheScope(address: client.address, accountID: $0).digest }
    }

    /// Delete a recording, cancel a schedule, remove a rule or delete a failed item: it goes from every list at once and
    /// the toast offers Undo for 10 s. When the Undo commits (its 10 s end, or the app goes to the background,
    /// `AppPresenter.commitPendingUndo`) the operation is first written to the removal log, then sent: after any change
    /// still in flight (never dropped, Codex batch 4), as background work. It leaves the log only once the server
    /// confirms it, or says the item is already gone; a process killed before that replays it at the next launch or
    /// return to the foreground (`replayPendingRemovals`, Codex 5b round 1, high). Undo puts the item back with no
    /// call; a refused call puts it back, says why and stays in the log. The server stops a recording still being made
    /// before deleting it (C-M).
    private func removeWithUndo(_ kind: PendingRemoval.Kind, id: Int, message: String, presenter: AppPresenter) {
        let key = PendingRemoval.key(kind, id)
        // Codex check of 320: a second removal of something whose removal is already in progress is not made (it would
        // commit the first one's Undo early).
        guard !recordingStore.pendingRemovals.contains(key), recordingStore.uncertainRemovals[key] == nil else { return }
        PigHaptic.play(.delete)
        recordingStore.pendingRemovals.insert(key)
        // Apple 126 (Codex 5b round 2, high): while its Undo is open, a logged removal of this item is never replayed.
        openUndoKeys.insert(key)
        presenter.offerUndo(message, key: key, undone: { [weak self] in
            guard let self else { return }
            self.openUndoKeys.remove(key)
            self.recordingStore.pendingRemovals.remove(key)
            // Undo is a decision: nothing of this item runs later, whatever an earlier attempt left logged.
            if let scope = self.removalScope { self.removalLog.remove(scope: scope, key: key) }
        }) { [weak self] in
            guard let self else { return }
            self.openUndoKeys.remove(key)
            let op = self.removalScope.map { PendingRemoval(kind: kind, id: id, scope: $0) }
            if let op, !self.isFixture { self.removalLog.add(op) }
            self.sendRemoval(kind, id: id, logged: self.isFixture ? nil : op)
        }
    }

    /// The items whose Undo is on screen now (never replayed meanwhile).
    private var openUndoKeys: Set<String> = []

    // MARK: Cancellations in progress (Mark, 19 Nov 2026)

    /// A schedule's cancellation is in progress: made (its Undo open), sent and not yet answered, or sent with no answer
    /// (a transport error) until a scheduled-list refresh has answered. A refused one is not (the schedule stands); a
    /// confirmed one is not (the schedule is gone).
    func cancellationInProgress(_ schedule: ScheduledRecording) -> Bool {
        schedule.isCancelling // the server's own state (#347 C-M "Cancelling"), whoever cancelled it
            || cancellingHere(schedule)
    }

    /// A cancellation this device has made and the server may not list yet: its Undo open, or sent with no answer.
    func cancellingHere(_ schedule: ScheduledRecording) -> Bool {
        let key = PendingRemoval.key(.cancelSchedule, schedule.id)
        return (recordingStore.pendingRemovals.contains(key) && recordingStore.tombstones[key] == nil)
            || recordingStore.uncertainRemovals[key] != nil
    }

    /// Recording this waits for an earlier recording of it being cancelled: a schedule whose cancellation is in progress
    /// overlaps the airing and is the same game (`gameId`) or the same channel. Another day of a multi-day game does not
    /// overlap, so it stays recordable.
    /// Both sides are compared by guide bounds (C-R #353): `start`/`end` the airing's guide slot, a schedule's its guide
    /// end (`guideEnd`), never a rolled end, so the programme after an overrunning game is not the game's.
    /// `slots`: a sport request's airings, which resolve a schedule to its own slot first (`scheduleGuideEnd`).
    /// A Record the server refused 409 "cancelling" (#357) waits too, by the airing it tried, whatever the list on show.
    func cancellingEarlier(gameId: String?, channel: GuideChannel, start: Double, end: Double,
                           onlyHere: Bool = false, slots: [RecordRequest.Airing] = []) -> Bool {
        if recordingStore.refusedAirings.values.joined().contains(where: { $0.covers(gameId: gameId, channel: channel, start: start, end: end) }) {
            return true
        }
        return schedules.contains { schedule in
            schedule.program_start < end
                && ((gameId != nil && schedule.game == gameId) || Self.sameChannel(schedule, channel))
                && (onlyHere ? cancellingHere(schedule) : cancellationInProgress(schedule))
                && scheduleGuideEnd(schedule, channel: channel, slots: slots) > start
        }
    }

    /// A schedule's guide end (C-R #353; Codex review of #347): its own guide slot first, by channel identity and start
    /// (a sport request's airing, the channel being asked about, or the loaded guide), since a schedule made while its
    /// game overran stores the rolled end as `program_end` and may have no `program_end_original`; the stored end only
    /// when no slot is found (the server does the same since 0874).
    func scheduleGuideEnd(_ schedule: ScheduledRecording, channel: GuideChannel? = nil, slots: [RecordRequest.Airing] = []) -> Double {
        let start = Int64(schedule.program_start)
        if let slot = slots.first(where: { Int64($0.programme.startTime) == start && Self.sameChannel(schedule, $0.channel) }) {
            return slot.guideBounds.end
        }
        if let channel, Self.sameChannel(schedule, channel),
           let own = channel.programmes.first(where: { Int64($0.startTime) == start }) {
            return own.endTime
        }
        if let source = schedule.source_id, let item = schedule.channel_item_id, !item.isEmpty,
           let listed = guideStore.channel(id: "\(source):\(item)"),
           let own = listed.programmes.first(where: { Int64($0.startTime) == start }) {
            return own.endTime
        }
        return schedule.guideEnd
    }

    /// The server's identity of a schedule's channel (Codex check of 320): its source and item, or stable id where both
    /// have one; the display name only for a row without identity (an older server). A renamed channel is the same one.
    nonisolated static func sameChannel(_ schedule: ScheduledRecording, _ channel: GuideChannel) -> Bool {
        guard let source = schedule.source_id else { return schedule.channel_name == channel.name }
        guard source == channel.sourceId else { return false }
        if let stable = schedule.channel_stable_id, !stable.isEmpty, let mine = channel.stableId, !mine.isEmpty {
            return stable == mine
        }
        if let item = schedule.channel_item_id, !item.isEmpty { return item == channel.rawID }
        return schedule.channel_name == channel.name
    }

    /// A record page's airing waits (`cancellingEarlier`), by its guide bounds. With the card's `recordingCancelling`
    /// (C-R #353) the server's list decides what it is cancelling, by overlap with the airing; the client adds only what
    /// the server cannot know yet (a cancellation made here, its Undo open or its answer not in). Without it (an older
    /// server, or nothing being cancelled) the client's own inference decides.
    func cancellingEarlier(_ request: RecordRequest, airing: RecordRequest.Airing) -> Bool {
        let bounds = airing.guideBounds
        guard var entries = request.serverCancelling else {
            return cancellingEarlier(gameId: request.gameId, channel: airing.channel, start: bounds.start, end: bounds.end,
                                     slots: request.airings)
        }
        // Codex review of #347: the card's list is as old as the card. A scheduled list asked for after the request was
        // built decides instead: an entry stands only while that list still has its schedule "cancelling", and a
        // cancellation that list shows (another device's, on another airing) counts too. The open page follows it.
        if let asked = recordingStore.schedulesAskedAt, asked > request.builtAt {
            let cancelling = Set(schedules.filter(\.isCancelling).map(\.id))
            entries = entries.filter { cancelling.contains($0.scheduleId) }
            if entries.contains(where: { $0.start < bounds.end && $0.end > bounds.start }) { return true }
            return cancellingEarlier(gameId: request.gameId, channel: airing.channel, start: bounds.start, end: bounds.end,
                                     slots: request.airings)
        }
        if entries.contains(where: { $0.start < bounds.end && $0.end > bounds.start }) { return true }
        return cancellingEarlier(gameId: request.gameId, channel: airing.channel, start: bounds.start, end: bounds.end,
                                 onlyHere: true, slots: request.airings)
    }

    /// Any of a request's airings waits.
    func cancellingEarlier(_ request: RecordRequest) -> Bool {
        request.airings.contains { cancellingEarlier(request, airing: $0) }
    }

    /// After a cancellation with no answer: its own read of the scheduled list, begun after the failure and apart from
    /// the recordings files (Codex check of 320), again every `reconcileRetry` for `reconcileTries` reads, then less
    /// often (each wait doubled, at most `reconcileMaxRetry`) for as long as it is unresolved (#357, Codex review of
    /// 359-360: it gave up, and Record stayed disabled for the session while `/recordings` was down).
    /// The answer decides: the row gone (cancelled), or listed with another status than "cancelling" (the cancel failed:
    /// it stands); while the server lists it "cancelling" (C-M, #347) it is still in progress and the reads go on.
    var reconcileRetry: Duration = .seconds(5)
    var reconcileTries = 24
    var reconcileMaxRetry: Duration = .seconds(60)

    /// The wait before read `attempt` (from 0) of a cancellation's own reads.
    func reconcileWait(before attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        guard attempt >= reconcileTries else { return reconcileRetry }
        let doubled = reconcileRetry * (1 << min(attempt - reconcileTries + 1, 16))
        return min(doubled, max(reconcileMaxRetry, reconcileRetry))
    }

    /// Signed out, or replaced by another server or account (`retirePrivateCaches`): for good.
    private(set) var isRetired = false

    /// The reads settling each unresolved cancellation, by its key (#357, Codex review of 359-360): one worker per
    /// schedule (a new mark replaces it, so its first read is at once), running while any mark of that schedule is
    /// set, all cancelled when the session is retired (`retirePrivateCaches`).
    private var reconcilers: [String: Task<Void, Never>] = [:]

    /// Starts the reads that settle `key` (replacing any still running for it); the task ends when they do.
    @discardableResult
    private func startReconciling(_ key: String) -> Task<Void, Never> {
        // A late answer (a 409, a lost cancel) on a retired session starts nothing (Codex sign-off of 359-364, medium).
        guard !isRetired else { return Task {} }
        reconcilers[key]?.cancel()
        let worker = Task { [weak self] in
            await self?.reconcileLostRemoval(key)
            // Only a worker nobody replaced or retired is still listed (each one replaced or retired was cancelled).
            if !Task.isCancelled { self?.reconcilers[key] = nil }
        }
        reconcilers[key] = worker
        return worker
    }

    /// What keeps a cancellation in progress: no answer to it (`uncertainRemovals`), or a Record refused for it
    /// (`refusedAirings`). Either one keeps its reads going; each is cleared only by an accepted read asked for after it
    /// was set (`publishSchedules`).
    private func cancellationPending(_ key: String) -> Bool {
        recordingStore.uncertainRemovals[key] != nil || recordingStore.refusedAirings[key] != nil
    }

    private func reconcileLostRemoval(_ key: String) async {
        // #357 (Codex sign-off of 359-364, medium): the worker is the schedule's, not one marker pair's. An accepted read
        // asked for between a refusal and a later lost cancel clears the refusal and keeps the cancel; the reads go on
        // while either is set (they ended when the pair changed, and the cancel was left with nothing to settle it).
        var attempt = 0
        while cancellationPending(key) {
            // Cancelled (signed out, switched account, or replaced): no more reads, and nothing it has read is published.
            let wait = reconcileWait(before: attempt)
            attempt += 1
            if wait > .zero { do { try await Task.sleep(for: wait) } catch { return } }
            guard !Task.isCancelled else { return }
            guard cancellationPending(key) else { return } // a read asked for after both marks has answered
            guard let read = try? await readSchedules() else { continue }
            guard !Task.isCancelled else { return }
            // Codex check of 320 (high): checked again after the answer, which can arrive after a newer list (a refresh,
            // a new schedule or cancel) has been published: then it is older than what is shown and decides nothing.
            // Its owner is checked before its ticket (Codex sign-off of #347, medium): an answer for a cancellation
            // already settled is dropped without taking the watermark, which would have refused a valid older-ticket answer.
            guard cancellationPending(key) else { return }
            guard scheduleTickets.publish(read.ticket) else { continue }
            publishSchedules(read) // settles each mark set before it was asked for, unless the server still lists it "cancelling"
        }
    }

    /// One read of the scheduled list, by either reader (a recordings load, or a lost cancellation's own reads). Codex
    /// check of 320 (high): answers can arrive out of order, so each read takes a number when it is asked for, and only an
    /// answer asked for after the last one published is `newest` (to be published); an older one would put back what a
    /// newer list (after a schedule or a cancel) no longer has. `cancelling`: the cancellation keys of the rows listed
    /// "cancelling" (#347). The read only takes its ticket; whoever publishes the answer advances the watermark
    /// (`ScheduleTickets.publish`), after checking it still owns the answer (Codex sign-off of #347).
    typealias ScheduleRead = (list: [ScheduledRecording], ticket: Int, cancelling: Set<String>, askedAt: Date)

    private func readSchedules() async throws -> ScheduleRead {
        let ticket = scheduleTickets.ask()
        let askedAt = Date()
        let fetched: [ScheduledRecording] = try await client.decodedOffMain(
            "recordings/scheduled", query: [URLQueryItem(name: "include", value: "recent")])
        let cancelling = Set(fetched.filter(\.isCancelling).map { PendingRemoval.key(.cancelSchedule, $0.id) })
        return (fetched, ticket, cancelling, askedAt)
    }

    /// The scheduled-list reads asked for, and the last one published (`readSchedules`).
    private var scheduleTickets = ScheduleTickets()

    /// Sends one removal (a committed Undo, or one replayed from the log) and settles the log and the lists.
    private func sendRemoval(_ kind: PendingRemoval.Kind, id: Int, logged op: PendingRemoval?) {
        let key = PendingRemoval.key(kind, id)
        if let op { removalLog.inFlight.insert(op.flightKey) }
        BackgroundWork.run("PigTV: \(key)") {
            defer { if let op { self.removalLog.inFlight.remove(op.flightKey) } }
            await self.waitForMutation()
            // Done meanwhile by another send of the same operation: nothing to do.
            if let op, !self.removalLog.contains(op) { return }
            let outcome = await self.performRemoval(kind, id: id)
            switch outcome {
            case .done:
                if let op { self.removalLog.remove(op) }
                // Apple 125: hidden until a refresh that began after now has loaded (`settleTombstones`); a refresh
                // already running, or one that fails, never shows it again.
                self.recordingStore.tombstones[key] = Date()
                await self.loadRecordings()
                if kind == .rule { await self.reloadRules() }
            case .failed(let message), .unknown(let message):
                // Apple 126: the item is back with the reason; nothing of it runs later without a new decision.
                if let op { self.removalLog.remove(op) }
                self.actionError = message
                // No answer: still in progress until the schedules, read again at once, say whether it is there.
                if case .unknown = outcome { self.recordingStore.uncertainRemovals[key] = Date() }
                self.recordingStore.pendingRemovals.remove(key)
                if case .unknown = outcome { await self.startReconciling(key).value }
            }
        }
    }

    /// A list that began loading after a removal was confirmed has loaded: that removal is settled (no longer hidden).
    private func settleTombstones(loadedSince began: Date, _ applies: (String) -> Bool) {
        for (key, at) in recordingStore.tombstones where at < began && applies(key) {
            recordingStore.tombstones[key] = nil
            recordingStore.pendingRemovals.remove(key)
        }
    }

    /// The removals committed but never confirmed, for this server and account (a process killed in the background
    /// before they were sent): each is hidden and sent once, through the same path. At launch and on every return to
    /// the foreground while signed in (ContentView).
    func replayPendingRemovals() {
        guard !isFixture, let scope = removalScope else { return }
        for op in removalLog.pending(scope: scope)
        where !removalLog.inFlight.contains(op.flightKey) && !openUndoKeys.contains(op.key) {
            recordingStore.pendingRemovals.insert(op.key)
            sendRemoval(op.kind, id: op.id, logged: op)
        }
    }

    /// `unknown`: no answer came (a transport error or a timeout): the server may or may not have done it.
    enum RemovalOutcome: Equatable { case done, failed(String), unknown(String) }

    /// One removal's call. The item already gone (404, or the server's "not found") counts as done.
    private func performRemoval(_ kind: PendingRemoval.Kind, id: Int) async -> RemovalOutcome {
        struct Deleted: Decodable { let cancelled: Int? }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            switch kind {
            case .recording:
                let result: ActionResult = try await client.request("recordings/\(id)", method: "DELETE")
                guard result.success else { throw PigTVError.message("The server did not confirm the change.") }
                actionMessage = "Recording deleted."
            case .cancelSchedule:
                let updated: ScheduledRecording = try await client.request("recordings/scheduled/\(id)", method: "DELETE")
                guard !updated.canCancel else {
                    throw PigTVError.message("The server still lists this recording as active. Refresh, then try again.")
                }
                actionMessage = "Schedule cancelled or recording stopped."
            case .deleteSchedule:
                _ = try await client.response("recordings/scheduled/\(id)", method: "DELETE")
                actionMessage = "Schedule deleted."
            case .rule:
                let result: Deleted = try await client.request("recordings/rules/\(id)", method: "DELETE")
                let n = result.cancelled ?? 0
                actionMessage = n == 0 ? "Rule deleted." : "Rule deleted; \(n) upcoming recording\(n == 1 ? "" : "s") cancelled."
            }
            return .done
        } catch PigTVError.http(404) {
            return .done
        } catch let error as URLError {
            // Codex sign-off of 320: no answer is not a refusal; the server may still have cancelled it.
            return .unknown(Self.actionText(PageWords.removeFailed, error) ?? PageWords.removeFailed)
        } catch {
            return .failed(Self.actionText(PageWords.removeFailed, error) ?? PageWords.removeFailed)
        }
    }

    func deleteWithUndo(_ item: Recording, presenter: AppPresenter) {
        removeWithUndo(.recording, id: item.id, message: "\(item.title) deleted with its file", presenter: presenter)
    }

    func cancelWithUndo(_ item: ScheduledRecording, presenter: AppPresenter) {
        let message = item.status == "recording" ? "Recording of \(item.title) stopped" : "Recording of \(item.title) cancelled"
        removeWithUndo(.cancelSchedule, id: item.id, message: message, presenter: presenter)
    }

    /// A failed or missed schedule (Needs attention), with its partial files.
    func deleteScheduleWithUndo(_ item: ScheduledRecording, presenter: AppPresenter) {
        removeWithUndo(.deleteSchedule, id: item.id, message: "\(item.title) deleted", presenter: presenter)
    }

    func removeRuleWithUndo(_ rule: RecordingRule, presenter: AppPresenter) {
        removeWithUndo(.rule, id: rule.id, message: "Rule removed: \(rule.summary)", presenter: presenter)
    }

    /// Server 0410 (#12, D-42): "Record this one instead": the schedule wins its clashes from then on, and the ones
    /// it beat wait. 404 when it has already started or is gone. The schedules are reloaded either way.
    func choose(_ item: ScheduledRecording) async {
        guard !mutationBusy else { return }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            _ = try await client.response("recordings/scheduled/\(item.id)/choose", method: "POST")
        } catch PigTVError.http(404) {
            actionError = "That recording has already started or no longer exists."
        } catch {
            actionError = Self.actionText(PageWords.chooseFailed, error)
        }
        await loadRecordings()
    }

    /// Deletes a failed or missed schedule (server 0207 also removes its
    /// partial files). The reply body is not needed, so any 2xx counts.
    func deleteSchedule(_ item: ScheduledRecording) async {
        guard !mutationBusy else { return }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            _ = try await client.response("recordings/scheduled/\(item.id)", method: "DELETE")
            actionMessage = "Schedule deleted."
            await loadRecordings()
        } catch { actionError = Self.actionText(PageWords.deleteFailed, error) }
    }

    /// Resume fraction and watched state, from the server's per-login values on the recordings list.
    func progress(for recording: Recording) -> RecordingProgress { recording.progress() }

    func delete(_ item: Recording) async {
        await mutate("recordings/\(item.id)", method: "DELETE", success: "Recording deleted.")
    }

    // MARK: C-M recording rules

    func loadRules() async throws -> [RecordingRule] {
        try await client.request("recordings/rules")
    }

    /// Apple 120: Scheduled's rules, kept in the recordings store (the fixture keeps its own).
    /// Apple 127 (Codex 5b round 2, medium): rule loads may overlap. Each takes a generation; an answer older than the
    /// last one published is dropped (it could hold a rule removed since), and the tombstones are read when an answer
    /// is accepted, not when its request went.
    func reloadRules() async {
        guard !isFixture else { return }
        rulesGeneration += 1
        let generation = rulesGeneration
        let began = Date()
        do {
            let fetched = try await loadRules()
            guard generation > rulesPublished else { return }
            rulesPublished = generation
            let stones = recordingStore.tombstones
            let loaded = fetched.filter { stones[RecordingsHome.key($0)] == nil }
            if loaded != recordingStore.rules { recordingStore.rules = loaded }
            settleTombstones(loadedSince: began) { $0.hasPrefix("rule:") }
            recordingStore.change(\.rulesError, to: nil)
            recordingStore.change(\.rulesLoaded, to: true)
        } catch {
            guard generation > rulesPublished, !UserMessage.isCancellation(error) else { return }
            // #280: plain words, never the system's text.
            recordingStore.change(\.rulesError, to: PageWords.rulesFailed)
        }
    }
    private var rulesGeneration = 0
    private var rulesPublished = 0

    /// Adds a rule; the message says how many it scheduled. False on failure.
    @discardableResult
    func addRule(_ body: RuleBody) async -> Bool {
        guard !mutationBusy else { return false }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let rule: RecordingRule = try await client.request("recordings/rules", method: "POST", body: body)
            let n = rule.scheduled ?? 0
            actionMessage = "\(rule.summary). \(n == 1 ? "1 recording" : "\(n) recordings") scheduled for now; more as the guide fills in."
            PigHaptic.play(.record)
            await loadRecordings()
            return true
        } catch {
            actionError = Self.actionText(PageWords.ruleAddFailed, error)
            return false
        }
    }

    /// A3 (build 48): one rule change at a time (the sheet's buttons are off meanwhile); the old
    /// message goes first, and a failure is kept in actionError, which the sheet shows. True when it worked.
    @discardableResult
    func setRule(_ rule: RecordingRule, enabled: Bool) async -> Bool {
        guard !mutationBusy else { return false }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let _: RecordingRule = try await client.request("recordings/rules/\(rule.id)", method: "PUT", body: RuleEnabledBody(enabled: enabled))
            actionMessage = enabled ? "Rule turned on." : "Rule turned off."
            await loadRecordings()
            await reloadRules()
            return true
        } catch {
            actionError = Self.actionText(PageWords.ruleChangeFailed, error)
            return false
        }
    }

    /// #278 (audit D4/S1): Settings › Sport's "Record every game" changes, through this one owner of the rules. It
    /// waits for any change in flight (never dropped; that page shows the row busy meanwhile), then makes one change,
    /// chosen by `choose` from the rules as they are once its turn comes (nil: nothing is sent). No banner and no
    /// haptic: that page says what happened itself, so the request's error is thrown to it. The lists are reloaded
    /// either way, so Scheduled shows the change at once. -> whether a request was sent.
    @discardableResult
    func changeRule(_ choose: () -> RuleChange?) async throws -> Bool {
        await waitForMutation()
        guard let change = choose() else { return false }
        struct Answer: Decodable { let id: Int? }
        mutationBusy = true
        defer { mutationBusy = false }
        var failure: Error?
        do {
            switch change {
            case .enable(let id):
                let _: Answer = try await client.request("recordings/rules/\(id)", method: "PUT", body: RuleEnabledBody(enabled: true))
            case .add(let body):
                let _: Answer = try await client.request("recordings/rules", method: "POST", body: body)
            case .delete(let id):
                let _: Answer = try await client.request("recordings/rules/\(id)", method: "DELETE")
            }
        } catch { failure = error }
        await loadRecordings()
        await reloadRules()
        if let failure { throw failure }
        return true
    }

    /// #234: "Record when it's listed": the game's `game` rule; its id, or nil (actionError says why).
    func addGameRule(_ game: SportsGame, before: Int? = nil, after: Int? = nil) async -> Int? {
        guard !mutationBusy else { return nil }
        mutationBusy = true
        actionError = nil
        defer { mutationBusy = false }
        do {
            let body = RuleBody(kind: "game", match: game.title, preBufferMin: before, postBufferMin: after, gameId: game.id)
            let rule: RecordingRule = try await client.request("recordings/rules", method: "POST", body: body)
            actionMessage = "It will record once it's in the TV guide."
            PigHaptic.play(.record)
            return rule.id
        } catch {
            actionError = Self.actionText(PageWords.recordWhenListedFailed, error)
            return nil
        }
    }

    /// #234: a rule known only by its id (a card's `recordWhenListed`).
    @discardableResult
    func deleteRule(id: Int) async -> Bool {
        struct Deleted: Decodable { let cancelled: Int? }
        guard !mutationBusy else { return false }
        mutationBusy = true
        actionError = nil
        defer { mutationBusy = false }
        do {
            let _: Deleted = try await client.request("recordings/rules/\(id)", method: "DELETE")
            actionMessage = "It won't be recorded."
            await loadRecordings()
            return true
        } catch {
            actionError = Self.actionText(PageWords.followChangeFailed, error)
            return false
        }
    }

    @discardableResult
    func deleteRule(_ rule: RecordingRule) async -> Bool {
        struct Deleted: Decodable { let cancelled: Int? }
        guard !mutationBusy else { return false }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let result: Deleted = try await client.request("recordings/rules/\(rule.id)", method: "DELETE")
            let n = result.cancelled ?? 0
            actionMessage = n == 0 ? "Rule deleted." : "Rule deleted; \(n) upcoming recording\(n == 1 ? "" : "s") cancelled."
            await loadRecordings()
            await reloadRules()
            return true
        } catch {
            actionError = Self.actionText(PageWords.ruleDeleteFailed, error)
            return false
        }
    }

    func detectAds(_ item: Recording) async {
        await mutate("recordings/\(item.id)/detect-ads", method: "POST", success: "Commercial-break analysis queued.")
    }

    private func mutate(_ path: String, method: String, success: String) async {
        guard !mutationBusy else { return }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let result: ActionResult = try await client.request(path, method: method)
            guard result.success else { throw PigTVError.message("The server did not confirm the change.") }
            actionMessage = success
            await loadRecordings()
        } catch { actionError = Self.actionText(PageWords.actionFailed, error) }
    }

    #if DEBUG
    /// Fixture/test seam (build 33): the offline guide fixture pre-generates
    /// its own programme data past a single loaded day, with no server to
    /// extend it from — this tells the grid how far that data actually
    /// reaches, exactly what `extendGuideForward()` would otherwise set.
    func setGuideLoadedUntilForFixture(_ date: Date) { guideLoadedUntil = date }

    /// #280: a guide fixture in one of its states makes no requests (else the empty fixture would try the network).
    private(set) var fixtureHoldsGuide = false

    /// #280 (`PIGTV_UI_TEST_GUIDE_STATE`): the TV Guide (and Search) in one of its states for the simulator and UI tests:
    /// `loading` (no channels, and none come), `empty` (an answer with no channels), `failed` (the first load failed),
    /// `stale` (the fixture's channels, a refresh failed 25 minutes after they came).
    func setGuideFixtureState(_ state: String) {
        fixtureHoldsGuide = true
        let past = Date().addingTimeInterval(-25 * 60)
        switch state {
        case "loading":
            guide = []
            guideLoadedAt = nil
            guideBusy = true
        case "empty":
            guide = []
            guideLoadedAt = past
        case "failed":
            guide = []
            guideLoadedAt = nil
            guideError = "fixture"
            guideStore.schedule = RefreshSchedule(after: AppFreshness.interval)
        case "stale":
            guideLoadedAt = past
            guideError = "fixture"
        default: break
        }
    }

    /// #280 (`PIGTV_UI_TEST_RECORDINGS_STATE`): Recordings and Scheduled in one of their states: `loading` (no answer
    /// yet, the rules neither), `empty` (an answer with nothing recorded or scheduled, and no rules), `no-recordings` (nothing recorded, the fixture's schedules kept), `failed` (the first
    /// load failed), `stale` (the fixture's lists, the last refresh failed 25 minutes after they came), `empty-stale` (an
    /// answer with nothing in it, the last refresh failed 25 minutes after it came).
    func setRecordingsFixtureState(_ state: String) {
        switch state {
        case "loading":
            recordings = []
            schedules = []
            recordingStore.rules = []
            recordingStore.loaded = false
            recordingStore.rulesLoaded = false
        case "empty":
            recordings = []
            schedules = []
            recordingStore.rules = []
        case "no-recordings":
            // #311: nothing recorded, but the fixture's schedules stay (the Coming up strip has something to show)
            recordings = []
        case "failed":
            recordings = []
            schedules = []
            recordingStore.loaded = false
            recordingsError = "fixture"
            recordingStore.schedule = RefreshSchedule(after: AppFreshness.interval)
        case "stale":
            recordingStore.updatedAt = Date().addingTimeInterval(-25 * 60)
            recordingsError = "fixture"
        case "empty-stale":
            recordings = []
            schedules = []
            recordingStore.rules = []
            recordingStore.updatedAt = Date().addingTimeInterval(-25 * 60)
            recordingsError = "fixture"
        default: break
        }
    }
    #endif
}

/// #278 (audit D4/S1): one change to a recording rule, as Settings › Sport asks `BrowseModel.changeRule` for it. The
/// requests are C-M's: `PUT rules/:id {enabled: true}`, `POST rules` with the body, `DELETE rules/:id`.
nonisolated enum RuleChange: Sendable {
    case enable(id: Int)
    case add(RuleBody)
    case delete(id: Int)
}

/// #278: what Settings › Sport needs of the one owner of the recording rules (`BrowseModel`, whose `RecordingsStore`
/// Scheduled lists too): the store to read and observe, its reload (generations and tombstones) and its one-at-a-time
/// change. Narrow, so a test can hand the page model a real `BrowseModel` over a local server.
protocol RecordingRuleOwner: AnyObject {
    var recordingStore: RecordingsStore { get }
    func reloadRules() async
    @discardableResult
    func changeRule(_ choose: () -> RuleChange?) async throws -> Bool
    /// #301: commits the removal of `key` (`PendingRemoval.key`) now when its Undo is open (a rule's Undo, before an
    /// unfollow decides about its rule). #313: only that one; another action's open Undo is left as it is.
    func settlePendingRemoval(_ key: String)
}

extension BrowseModel: RecordingRuleOwner {
    func settlePendingRemoval(_ key: String) { presenter?.commitPendingUndo(key: key) }
}

/// The scheduled list's read tickets (Codex check of 320; Codex sign-off of #347): each read takes a number when it is
/// asked for; an answer is published only if it was asked after the last one published, and only publishing advances
/// that watermark, so an answer its reader drops (no longer its own) never refuses an older one still to be published.
/// Pure (`ScheduleTicketsTests`).
nonisolated struct ScheduleTickets: Sendable, Equatable {
    private(set) var asked = 0
    private(set) var published = 0

    mutating func ask() -> Int {
        asked += 1
        return asked
    }

    /// True when `ticket`'s answer is newer than every one published: it is published, and the watermark moves to it.
    mutating func publish(_ ticket: Int) -> Bool {
        guard ticket > published else { return false }
        published = ticket
        return true
    }
}
