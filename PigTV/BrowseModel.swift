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
    private var guideCacheVersion: String?
    private var loadingVersion: String?
    private var guidePrefetch: Task<Void, Never>?
    // Set during a refresh: the visible guide is kept until the first new page
    // arrives, then replaced, so a background refresh never blanks the grid.
    private var replacePending = false
    private var guideExtending = false
    // Private to this server and account (R14); retired on sign-out.
    private let guideCache: GuideCacheStore
    /// A2 (build 48): the Top Shelf generation this session publishes under.
    let topShelfGeneration = TopShelfPublication.shared.current

    init(client: APIClient, accountID: Int? = nil, guideCacheDirectory: URL = GuideCacheStore.defaultDirectory) {
        self.client = client
        marks = ScheduleMarks(following: recordingStore)
        guideCache = GuideCacheStore(scope: CacheScope(address: client.address, accountID: accountID), directory: guideCacheDirectory)
    }

    /// Sign-out or a server/account switch: delete this account's guide cache
    /// and drop any save still in flight.
    func retirePrivateCaches() {
        guideCache.retire()
        // A2: and its Top Shelf publication: nothing it still exports is written.
        if topShelfGeneration == TopShelfPublication.shared.current { TopShelfPublication.shared.retire() }
    }

    // Loads the first page immediately, then keeps paging in the background
    // until every channel is present. Filters and search then work locally,
    // and a full day of programme data per channel is already in memory.
    func loadGuide(reset: Bool = true, keepVisible: Bool = false) async {
        let sp = PigTVSignpost.begin("GuideLoad"); defer { PigTVSignpost.end("GuideLoad", sp) }
        if reset {
            guidePrefetch?.cancel()
            guidePrefetch = nil
            guideGeneration = UUID()
            guideCursor = nil
            loadedGuideIds = []
            replacePending = keepVisible && !guide.isEmpty
            if !replacePending { guide = [] }
            guideTotal = 0
            guideHasMore = false
            // Build 33: a fresh load/reload always starts a new one-day
            // window; any in-flight forward extension is stale (the
            // generation bump above makes its result a no-op if it lands).
            guideLoadedUntil = window.addingTimeInterval(GuideNavigation.loadedDuration)
            guideEnded = false
            // A1.1: captured once before the load starts and committed only on
            // completion, so a version change mid-load is never masked.
            loadingVersion = try? await client.guideVersion()
        } else if guideBusy || !guideHasMore {
            return
        }
        let generation = guideGeneration
        guideBusy = true
        // #280 (review of 205, H2): the last failure stays until an attempt succeeds (fetchGuidePage clears it), so a
        // retry never swaps the error, or the stale notice, for the loading placeholders while it waits for its answer.
        defer { if generation == guideGeneration { guideBusy = false } }
        await fetchGuidePage(generation: generation)
        guard reset, generation == guideGeneration, guideHasMore, guideError == nil else { return }
        guidePrefetch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.guideGeneration,
                      self.guideHasMore, self.guideError == nil else { return }
                await self.fetchGuidePage(generation: generation)
            }
        }
    }

    private func fetchGuidePage(generation: UUID) async {
        let sp = PigTVSignpost.begin("GuidePage"); defer { PigTVSignpost.end("GuidePage", sp) }
        // A1.1: cursor paging, 500 at a time.
        let isFirstPage = guideCursor == nil
        let start = window.timeIntervalSince1970 * 1000
        var query = [
            URLQueryItem(name: "start", value: String(Int64(start))),
            URLQueryItem(name: "end", value: String(Int64(start + GuideNavigation.loadedDuration * 1000)))
        ]
        query.append(URLQueryItem(name: "limit", value: "500"))
        if let guideCursor { query.append(URLQueryItem(name: "cursor", value: guideCursor)) }
        do {
            let page = try await requestGuidePage(query, generation: generation)
            guard generation == guideGeneration else { return }
            if replacePending {
                replacePending = false
                guide = page.channels
                loadedGuideIds = Set(page.channels.map(\.id))
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
            guideTotal = page.total
            fromCache = false
            guideCursor = page.nextCursor
            guideHasMore = page.nextCursor != nil
            if isFirstPage { guideLoadedAt = Date() }
            if !guideHasMore {
                guideCacheVersion = loadingVersion
                saveCache()
            }
            // A4.1: the Top Shelf snapshot (first rows / favourites' now-next).
            if isFirstPage || !guideHasMore { exportTopShelf() }
        } catch {
            // A cancelled request (the task that asked went away, URLError's own "cancelled" too) is not a failure.
            guard generation == guideGeneration, !UserMessage.isCancellation(error) else { return }
            guideError = UserMessage.text(for: error) ?? UserMessage.somethingFailed
        }
    }

    /// One guide page, retried with backoff (`GuideNavigation.guidePageRetryDelays`)
    /// before rethrowing — the same failed page each time (nothing about
    /// `query` changes between attempts), so a caller that gives up leaves
    /// its paging cursor exactly where a retry can resume it.
    private func requestGuidePage(_ query: [URLQueryItem], generation: UUID) async throws -> GuidePage {
        var attempt = 0
        #if DEBUG
        let delays = Self.guidePageRetryDelaysOverride ?? GuideNavigation.guidePageRetryDelays
        #else
        let delays = GuideNavigation.guidePageRetryDelays
        #endif
        while true {
            do { return try await client.guidePage(query: query) }
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
            await loadGuide(reset: true, keepVisible: true)
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
        guard !guideExtending, !guideEnded, !guideBusy, !guideHasMore, !guide.isEmpty else { return }
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
            do { page = try await requestGuidePage(query, generation: generation) }
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
        var updated = guide
        for index in updated.indices {
            var programmes = updated[index].programmes
            if let additions = merged[updated[index].id] {
                programmes = GuideNavigation.mergeProgrammes(programmes, adding: additions)
            }
            updated[index] = updated[index].withProgrammes(GuideNavigation.trimmed(programmes, keepFrom: keepFrom))
        }
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
            await self.loadCachedGuide()
            if self.guide.isEmpty || self.fromCache {
                if !self.fromCache {
                    self.window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
                }
                await self.loadGuide(reset: true, keepVisible: self.fromCache)
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
    private func tryMarkFreshByVersion(now: Date = Date()) async -> Bool {
        guard !guide.isEmpty else { return false }
        guard let serverVersion = try? await client.guideVersion() else { return false }
        guard GuideNavigation.guideStillCovers(cachedVersion: guideCacheVersion, serverVersion: serverVersion,
                                                window: window, now: now) else { return false }
        fromCache = false
        guideLoadedAt = now
        return true
    }

    // Refresh in place when the loaded day is getting stale.
    func refreshGuideIfStale(maxAge: TimeInterval = 4 * 3600) async {
        let loaded = guideLoadedAt ?? .distantPast
        guard fromCache || Date().timeIntervalSince(loaded) > maxAge, !guideBusy else { return }
        if await tryMarkFreshByVersion() { return }
        window = GuideNavigation.rounded(Date()).addingTimeInterval(-GuideNavigation.leadIn)
        await loadGuide(reset: true, keepVisible: true)
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
            number: number(for: channel))
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
    func loadRecordings(quietly: Bool = false) async {
        let sp = PigTVSignpost.begin("RecordingsLoad"); defer { PigTVSignpost.end("RecordingsLoad", sp) }
        guard !recordingsLoading else { return }
        lastLoads["recordings"] = Date()
        recordingsLoading = true
        if !quietly { recordingsBusy = true }
        // #280 (review of 205, H2): the last failure stays until a request succeeds, so a poll or "Try again" never swaps
        // the error for the loading placeholders, or makes the stale notice blink, while it waits for its answer.
        defer { recordingsLoading = false; if !quietly { recordingsBusy = false } }
        let began = Date()
        do {
            let loaded: [Recording] = try await client.decodedOffMain("recordings")
            let fetched: [ScheduledRecording] = try await client.decodedOffMain("recordings/scheduled",
                                                                                query: [URLQueryItem(name: "include", value: "recent")])
            // Apple 125: nothing the server confirmed removed comes back from a list fetched before (or around) it.
            let stones = recordingStore.tombstones
            let files = loaded.filter { stones[RecordingsHome.key($0)] == nil }
            let planned = fetched.filter { stones[RecordingsHome.key($0)] == nil }
            if files != recordings { recordings = files }
            if planned != schedules { schedules = planned }
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
        if favouritesError != nil { favouritesError = nil }
        defer { favouritesBusy = false }
        do {
            let loaded: [Channel] = try await client.request("library/favourites")
            if loaded != favourites { favourites = loaded }
            exportTopShelf()
        }
        catch { favouritesError = UserMessage.text(for: error) }
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
    /// #214: the Sport tab's pushed sport pages (the tab bar returns it to the front page).
    private(set) lazy var sportNavigation = SportNavigation()
    /// C-U (#200): Settings › Sport, only with the server's `sportFollows` flag. A spoiler-free change saved there makes
    /// the sport pages (whose preferences the F1 page model holds) ask for the choice again.
    private(set) lazy var sportFollows: SportFollowSettingsModel = {
        let model = SportFollowSettingsModel(client: client)
        // #278: its "Record every game" switches read and change the one set of rules (Scheduled's).
        model.ruleOwner = self
        model.onSpoilerFreeChange = { [weak self] in
            guard let pages = self?.f1Page else { return }
            pages.invalidatePreferences()
            Task { await pages.revalidatePreferences() }
        }
        return model
    }()
    var sportFollowsEnabled: Bool { client.info?.features.sportFollows == true }
    /// #278 (audit D5): the sport pages' Hide scores chip; it saves through `sportFollows`, the choice's one writer.
    private(set) lazy var hideScores = HideScoresChip(pages: f1Page) { [weak self] on in
        await self?.sportFollows.setSpoilerFreeFromPage(on) ?? false
    }

    /// The Channel the player needs for one of an event's channels: its
    /// guide row when loaded (logo fallback, stable identity), else the
    /// event's own fields.
    func playable(_ channel: SportEventChannel) -> Channel {
        let row = guideRow(id: channel.id, identityKey: channel.identityKey)
        return Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name, logo: logo(for: channel),
                       category: row?.category, now: nil, next: nil, stableId: channel.stableId ?? row?.stableId,
                       number: channel.number ?? row?.number)
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
    func schedule(channel: GuideChannel, programme: GuideProgramme, before: Int?, after: Int?,
                  gameId: String? = nil) async -> Bool {
        guard !mutationBusy else { return false }
        guard programme.end > Date(), programme.end > programme.start else {
            actionError = "This programme has ended. Refresh the guide to choose another programme."
            return false
        }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        scheduleClash = nil
        defer { mutationBusy = false }
        do {
            let made: ScheduledRecording = try await client.request("recordings/schedule", method: "POST",
                body: ScheduleBody(sourceId: channel.sourceId, channelItemId: channel.rawID,
                    channelName: channel.name, channelLogo: channel.logo, title: programme.title,
                    description: programme.description, programStart: programme.startTime,
                    programEnd: programme.endTime, preBufferMin: before, postBufferMin: after, gameId: gameId))
            await loadRecordings()
            // #12 (D-28): a clash is said when scheduling, never found later as a wait or a miss.
            if let clash = made.clashText(in: schedules) {
                scheduleClash = clash
                actionMessage = "Recording scheduled. \(clash)"
            } else {
                actionMessage = "Recording scheduled. You can review it in Recordings."
            }
            PigHaptic.play(.record)
            return true
        } catch {
            actionError = Self.actionText(PageWords.scheduleUnconfirmed, error)
            return false
        }
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
            await loadRecordings()
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
            await loadRecordings()
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
        PigHaptic.play(.delete)
        recordingStore.pendingRemovals.insert(key)
        // Apple 126 (Codex 5b round 2, high): while its Undo is open, a logged removal of this item is never replayed.
        openUndoKeys.insert(key)
        presenter.offerUndo(message, undone: { [weak self] in
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

    /// Sends one removal (a committed Undo, or one replayed from the log) and settles the log and the lists.
    private func sendRemoval(_ kind: PendingRemoval.Kind, id: Int, logged op: PendingRemoval?) {
        let key = PendingRemoval.key(kind, id)
        if let op { removalLog.inFlight.insert(op.flightKey) }
        BackgroundWork.run("PigTV: \(key)") {
            defer { if let op { self.removalLog.inFlight.remove(op.flightKey) } }
            await self.waitForMutation()
            // Done meanwhile by another send of the same operation: nothing to do.
            if let op, !self.removalLog.contains(op) { return }
            switch await self.performRemoval(kind, id: id) {
            case .done:
                if let op { self.removalLog.remove(op) }
                // Apple 125: hidden until a refresh that began after now has loaded (`settleTombstones`); a refresh
                // already running, or one that fails, never shows it again.
                self.recordingStore.tombstones[key] = Date()
                await self.loadRecordings()
                if kind == .rule { await self.reloadRules() }
            case .failed(let message):
                // Apple 126: the item is back with the reason; nothing of it runs later without a new decision.
                if let op { self.removalLog.remove(op) }
                self.actionError = message
                self.recordingStore.pendingRemovals.remove(key)
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

    enum RemovalOutcome: Equatable { case done, failed(String) }

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
    func addGameRule(_ game: SportsGame) async -> Int? {
        guard !mutationBusy else { return nil }
        mutationBusy = true
        actionError = nil
        defer { mutationBusy = false }
        do {
            let rule: RecordingRule = try await client.request("recordings/rules", method: "POST",
                                                               body: RuleBody(kind: "game", match: game.title, gameId: game.id))
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
    /// yet, the rules neither), `empty` (an answer with nothing recorded or scheduled, and no rules), `failed` (the first
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
    /// #301: commits the removal whose Undo is open, now (a rule's Undo, before an unfollow decides about its rule).
    func settlePendingRemovals()
}

extension BrowseModel: RecordingRuleOwner {
    func settlePendingRemovals() { presenter?.commitPendingUndo() }
}
