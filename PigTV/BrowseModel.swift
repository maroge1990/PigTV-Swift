import Foundation
import Combine

@MainActor
final class BrowseModel: ObservableObject {
    @Published var guide: [GuideChannel] = [] { didSet { guideIndex = nil } }
    // Channel id → position in `guide`, built lazily after each change. The
    // full guide is ~18 000 channels, so per-render `first(where:)` scans in
    // the guide header and player channel list were measurable work.
    private var guideIndex: [String: Int]?
    @Published var guideBusy = false
    @Published var guideError: String?
    @Published var guideHasMore = false
    @Published var window = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
    @Published var recordings: [Recording] = []
    @Published var schedules: [ScheduledRecording] = []
    @Published var recordingsBusy = false
    @Published var recordingsError: String?
    @Published var favourites: [Channel] = []
    @Published var favouritesBusy = false
    @Published var favouritesError: String?
    // Home (build 28): `GET library/recent`, most recent first.
    @Published var recent: [Channel] = []
    private var initialGuideLoad: Task<Void, Never>?
    /// Set only by the offline UI fixtures: Home then makes no requests.
    var isFixture = false
    @Published var mutationBusy = false
    @Published var actionMessage: String?
    @Published var actionError: String?
    let client: APIClient
    private var guideGeneration = UUID()
    private var guideOffset = 0
    // A1.1: cursor paging (server flag `guideCursor`) replaces offset when the
    // server supports it; nil once the last page has arrived.
    private var guideCursor: String?
    // Ids already appended to `guide` during the current load, kept up to date
    // incrementally instead of being rebuilt from `guide` on every page (that
    // rebuild made paging quadratic in the number of channels).
    private var loadedGuideIds = Set<String>()
    // The server's guide version (server flag `guideVersion`) tied to the data
    // currently held in `guide`/on disk. Captured once before a full load
    // starts and committed only when that load completes, so a change to the
    // guide mid-load is never masked by a stale "still fresh" version.
    private var guideCacheVersion: String?
    private var loadingVersion: String?
    private var guidePrefetch: Task<Void, Never>?
    @Published private(set) var artworkIndex = EPGArtworkIndex()
    @Published private(set) var artworkError: String?
    @Published private(set) var guideTotal = 0
    private var artworkBusy = false
    private var artworkLoaded = false
    // Set during a refresh: the visible guide is kept until the first new page
    // arrives, then replaced, so a background refresh never blanks the grid.
    private var replacePending = false
    @Published private(set) var guideLoadedAt: Date?
    @Published private(set) var fromCache = false
    // Build 33: how far ahead programme data actually reaches (initially
    // `window + GuideNavigation.loadedDuration`, then pushed forward as
    // `extendGuideForward()` merges in more slices). GuideGridLayout draws
    // content this wide; GuideView compares the viewport against it instead
    // of always assuming exactly one day is loaded.
    @Published private(set) var guideLoadedUntil = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
        .addingTimeInterval(GuideNavigation.loadedDuration)
    // True once a forward slice came back with no programmes at all (the
    // provider's guide has ended): stops further extension attempts.
    @Published private(set) var guideEnded = false
    private var guideExtending = false
    // Bumped whenever programmes are merged into (or trimmed from) existing
    // rows in place: `guide.count`/first/last id do not change, so this is
    // what tells GuideView's row-filter memoisation to recompute.
    @Published private(set) var guideProgrammesVersion = 0
    private static var cacheURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("pigtv-guide.json")
    }


    init(client: APIClient) { self.client = client }

    // Loads the first page immediately, then keeps paging in the background
    // until every channel is present. Filters and search then work locally,
    // and a full day of programme data per channel is already in memory.
    func loadGuide(reset: Bool = true, keepVisible: Bool = false) async {
        if reset {
            guidePrefetch?.cancel()
            guidePrefetch = nil
            guideGeneration = UUID()
            guideOffset = 0
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
            loadingVersion = client.info?.features.guideVersion == true ? try? await client.guideVersion() : nil
        } else if guideBusy || !guideHasMore {
            return
        }
        let generation = guideGeneration
        guideBusy = true
        guideError = nil
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
        // A1.1: cursor paging (server flag `guideCursor`) pages 500 at a time
        // instead of 50; an older server keeps limit/offset exactly as before.
        let cursorPaging = client.info?.features.guideCursor == true
        let isFirstPage = cursorPaging ? guideCursor == nil : guideOffset == 0
        let offset = guideOffset
        let start = window.timeIntervalSince1970 * 1000
        var query = [
            URLQueryItem(name: "start", value: String(Int64(start))),
            URLQueryItem(name: "end", value: String(Int64(start + GuideNavigation.loadedDuration * 1000)))
        ]
        if cursorPaging {
            query.append(URLQueryItem(name: "limit", value: "500"))
            if let guideCursor { query.append(URLQueryItem(name: "cursor", value: guideCursor)) }
        } else {
            query.append(URLQueryItem(name: "limit", value: "50"))
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
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
                guide.append(contentsOf: additions)
            }
            guideTotal = page.total
            fromCache = false
            if cursorPaging {
                guideCursor = page.nextCursor
                guideHasMore = page.nextCursor != nil
            } else {
                guideOffset = offset + page.channels.count
                guideHasMore = !page.channels.isEmpty && guideOffset < page.total
            }
            if isFirstPage { guideLoadedAt = Date() }
            if !guideHasMore {
                guideCacheVersion = loadingVersion
                saveCache()
            }
            // A4.1: the Top Shelf snapshot (first rows / favourites' now-next).
            if isFirstPage || !guideHasMore { exportTopShelf() }
            // A4.5: every channel's name and number for the Siri query.
            if !guideHasMore { exportChannelDirectory() }
        } catch {
            guard generation == guideGeneration, !(error is CancellationError) else { return }
            guideError = error.localizedDescription
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
                guard generation == guideGeneration, !(error is CancellationError) else { throw CancellationError() }
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

    /// The guide error banner's Retry: an empty guide (the very first page
    /// never arrived) starts over, otherwise this resumes background paging
    /// from `guideOffset`/`guideCursor` — wherever it stopped — instead of
    /// restarting the whole guide.
    func retryGuide() async {
        guideError = nil
        await loadGuide(reset: guide.isEmpty)
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
        guideExtending = true
        defer { guideExtending = false }
        let generation = guideGeneration
        let sliceStart = guideLoadedUntil
        let sliceEnd = sliceStart.addingTimeInterval(GuideNavigation.loadedDuration)
        let cursorPaging = client.info?.features.guideCursor == true
        let sliceQueryTimes = [
            URLQueryItem(name: "start", value: String(Int64(sliceStart.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "end", value: String(Int64(sliceEnd.timeIntervalSince1970 * 1000)))
        ]
        var merged: [String: [GuideProgramme]] = [:]
        var anyProgrammes = false
        var cursor: String?
        var offset = 0
        while true {
            var query = sliceQueryTimes
            if cursorPaging {
                query.append(URLQueryItem(name: "limit", value: "500"))
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            } else {
                query.append(URLQueryItem(name: "limit", value: "50"))
                query.append(URLQueryItem(name: "offset", value: String(offset)))
            }
            let page: GuidePage
            do { page = try await requestGuidePage(query, generation: generation) }
            catch { return } // transient: guideLoadedUntil unchanged, retried on the next viewport move
            guard generation == guideGeneration else { return }
            for channel in page.channels where !channel.programmes.isEmpty {
                merged[channel.id, default: []].append(contentsOf: channel.programmes)
                anyProgrammes = true
            }
            if cursorPaging {
                cursor = page.nextCursor
                if cursor == nil { break }
            } else {
                offset += page.channels.count
                if page.channels.isEmpty || offset >= page.total { break }
            }
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
        let url = Self.cacheURL
        let cached: GuideCache? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
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
        exportChannelDirectory()
        _ = await tryMarkFreshByVersion()
    }

    private func saveCache() {
        let snapshot = GuideCache(savedAt: Date(), window: window, channels: guide, version: guideCacheVersion)
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // A1.1: a cheap version check (server flag `guideVersion`) that avoids a
    // full guide download when nothing has changed and the loaded window
    // still covers the near future. Updates freshness state and returns true
    // when it did so; a failed fetch falls back to the normal reload.
    private func tryMarkFreshByVersion(now: Date = Date()) async -> Bool {
        guard client.info?.features.guideVersion == true, !guide.isEmpty else { return false }
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

    // Programme-title search across every loaded channel, upcoming only.
    func searchProgrammes(_ text: String, limit: Int = 200) -> [(channel: GuideChannel, programme: GuideProgramme)] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let now = Date()
        var results: [(channel: GuideChannel, programme: GuideProgramme)] = []
        for channel in guide {
            for programme in channel.programmes where programme.end > now && programme.title.localizedStandardContains(query) {
                results.append((channel, programme))
            }
        }
        return Array(results.sorted { $0.programme.start < $1.programme.start }.prefix(limit))
    }

    var scheduledKeys: Set<String> { Set(schedules.filter(\.isActive).map(\.guideKey)) }
    var recordingChannels: Set<String> { Set(schedules.filter { $0.status == "recording" }.compactMap(\.channel_name)) }

    func loadArtworkIndex() async {
        guard client.info?.features.epgLogoFallback != true, !artworkBusy, !artworkLoaded else { return }
        // Build 31: after a failure, try again at most every 10 minutes
        // (the Guide asked on every appearance).
        guard !isFresh("artwork", maxAge: 600) else { return }
        lastLoads["artwork"] = Date()
        artworkBusy = true
        if artworkError != nil { artworkError = nil }
        defer { artworkBusy = false }
        do {
            let sources: [EPGSourceSummary] = try await client.request("sources")
            var index = EPGArtworkIndex()
            var failed = false
            for source in sources where source.enabled && ["epg", "xtream"].contains(source.type) {
                do { index.append(try await client.epgArtwork(sourceID: source.id).channels) }
                catch { failed = true }
            }
            artworkIndex = index
            artworkLoaded = !failed
            if failed { artworkError = "Some EPG channel artwork could not be loaded." }
        } catch { artworkError = "Channel artwork is temporarily unavailable." }
    }
    func guideChannel(id: String) -> GuideChannel? {
        if guideIndex == nil {
            guideIndex = Dictionary(guide.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return guideIndex?[id].map { guide[$0] }
    }
    func programmes(for channel: Channel) -> [GuideProgramme] {
        guideChannel(id: channel.id)?.programmes ?? []
    }
    func asChannel(_ channel: GuideChannel) -> Channel {
        Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name,
            logo: logo(for: channel), category: channel.category, now: nil, next: nil, stableId: channel.stableId,
            number: number(for: channel))
    }
    // C-A: a channel number is shown only when the server advertises
    // `channelNumbers` (an older server, or a stale cache, shows none).
    var showsChannelNumbers: Bool { client.info?.features.channelNumbers == true }
    func number(for channel: GuideChannel) -> Int? {
        showsChannelNumbers ? channel.number : nil
    }
    // C-G: the guide marks a channel unreliable only with `channelHealth`.
    func isFlaky(_ channel: GuideChannel) -> Bool {
        client.info?.features.channelHealth == true && channel.health == "flaky"
    }
    // Prefer the playlist logo; fall back to the EPG icon like the web guide.
    func logo(for channel: GuideChannel) -> String? {
        logo(current: channel.logo, tvgID: channel.tvgId, name: channel.name)
    }
    func logo(for channel: Channel) -> String? {
        logo(current: channel.logo, tvgID: nil, name: channel.name)
    }
    private func logo(current: String?, tvgID: String?, name: String) -> String? {
        if let current = current?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty { return current }
        return artworkIndex.logo(tvgID: tvgID, name: name)
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

    private func isFresh(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        lastLoads[key].map { now.timeIntervalSince($0) < maxAge } ?? false
    }

    func loadRecordingsIfStale(maxAge: TimeInterval = appearMaxAge) async {
        guard !isFresh("recordings", maxAge: maxAge) else { return }
        await loadRecordings()
    }

    func loadFavouritesIfStale(maxAge: TimeInterval = appearMaxAge) async {
        guard !isFresh("favourites", maxAge: maxAge) else { return }
        await loadFavourites()
    }

    func loadRecentIfStale(maxAge: TimeInterval = appearMaxAge) async {
        guard !isFresh("recent", maxAge: maxAge) else { return }
        await loadRecent()
    }

    func loadRecordings() async {
        guard !recordingsBusy else { return }
        lastLoads["recordings"] = Date()
        recordingsBusy = true
        if recordingsError != nil { recordingsError = nil }
        defer { recordingsBusy = false }
        do {
            let files: [Recording] = try await client.decodedOffMain("recordings")
            if files != recordings { recordings = files }
            let query = client.info?.features.scheduleHistory == true
                ? [URLQueryItem(name: "include", value: "recent")]
                : []
            let planned: [ScheduledRecording] = try await client.decodedOffMain("recordings/scheduled", query: query)
            if planned != schedules { schedules = planned }
        } catch { recordingsError = error.localizedDescription }
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
        catch { favouritesError = error.localizedDescription }
    }

    /// Home: what this user watched last (server `library/recent`). An
    /// older server without the route (404) simply has no history.
    func loadRecent() async {
        lastLoads["recent"] = Date()
        do {
            let rows: [Channel] = try await client.request("library/recent",
                query: [URLQueryItem(name: "limit", value: "20")])
            let available = rows.filter { $0.unavailable != true }
            if available != recent { recent = available }
        } catch {
            if error as? PigTVError == .http(404), !recent.isEmpty { recent = [] }
        }
    }

    // MARK: Home channels

    /// A guide row as Home draws it.
    func homeChannel(_ row: GuideChannel) -> HomeChannel {
        HomeChannel(sourceId: row.sourceId, rawID: row.rawID, name: row.name, number: number(for: row),
                    logo: logo(for: row), category: row.category, stableId: row.stableId, programmes: row.programmes)
    }

    /// A server channel (favourite, recent) as Home draws it: its guide row
    /// when the guide has it (by id, else by stable identity), else its own
    /// now/next.
    func homeChannel(_ channel: Channel) -> HomeChannel {
        if let row = guideRow(id: channel.id, identityKey: channel.identityKey) { return homeChannel(row) }
        let programmes = [channel.now, channel.next].compactMap { $0 }.map {
            GuideProgramme(title: $0.title, description: nil, startTime: $0.startTime, endTime: $0.endTime)
        }
        return HomeChannel(sourceId: channel.sourceId, rawID: channel.rawID, name: channel.name,
                           number: showsChannelNumbers ? channel.number : nil, logo: logo(for: channel),
                           category: channel.category, stableId: channel.stableId, programmes: programmes)
    }

    /// The guide's row for a channel: by id, else by stable identity (a
    /// playlist reorder changes the id but not the identity).
    func guideRow(id: String, identityKey: String) -> GuideChannel? {
        if let row = guideChannel(id: id) { return row }
        guard identityKey != id else { return nil }
        return guide.first { $0.identityKey == identityKey }
    }

    /// The Channel the player needs for a Home card.
    func playable(_ channel: HomeChannel) -> Channel {
        Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name, logo: channel.logo,
                category: channel.category, now: nil, next: nil, stableId: channel.stableId, number: channel.number)
    }

    // MARK: Sport (C-I)

    /// Sport events, only used with the server's `sportsEvents` flag.
    private(set) lazy var sport = SportModel(client: client)
    /// Moves when a Sport card's logo may have changed (see `SportLogoRevision`).
    private(set) lazy var sportLogos = SportLogoRevision(following: self)
    var sportEnabled: Bool { client.info?.features.sportsEvents == true }

    /// The Channel the player needs for one of an event's channels: its
    /// guide row when loaded (logo fallback, stable identity), else the
    /// event's own fields.
    func playable(_ channel: SportEventChannel) -> Channel {
        let row = guideRow(id: channel.id, identityKey: channel.identityKey)
        return Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name, logo: logo(for: channel),
                       category: row?.category, now: nil, next: nil, stableId: channel.stableId ?? row?.stableId,
                       number: showsChannelNumbers ? (channel.number ?? row?.number) : nil)
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
                     category: nil, programmes: [event.programme], stableId: channel.stableId, number: channel.number)
    }

    /// True when a recording of this event on this channel is scheduled.
    func isScheduled(_ event: SportEvent, on channel: SportEventChannel) -> Bool {
        scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: event.startTime))
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

    func schedule(channel: GuideChannel, programme: GuideProgramme, before: Int, after: Int) async -> Bool {
        guard !mutationBusy else { return false }
        guard programme.end > Date(), programme.end > programme.start else {
            actionError = "This programme has ended. Refresh the guide to choose another programme."
            return false
        }
        mutationBusy = true
        actionError = nil
        actionMessage = nil
        defer { mutationBusy = false }
        do {
            let _: ScheduledRecording = try await client.request("recordings/schedule", method: "POST",
                body: ScheduleBody(sourceId: channel.sourceId, channelItemId: channel.rawID,
                    channelName: channel.name, channelLogo: channel.logo, title: programme.title,
                    description: programme.description, programStart: programme.startTime,
                    programEnd: programme.endTime, preBufferMin: before, postBufferMin: after))
            actionMessage = "Recording scheduled. You can review it in Recordings."
            await loadRecordings()
            return true
        } catch {
            actionError = "Could not confirm the schedule. Check Recordings before retrying, in case the server accepted it. \(error.localizedDescription)"
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
                throw PigTVError.message("The server still reports this schedule as active. Refresh before retrying.")
            }
            actionMessage = "Schedule cancelled or recording stopped."
            await loadRecordings()
        } catch { actionError = error.localizedDescription }
    }

    func delete(_ item: Recording) async {
        await mutate("recordings/\(item.id)", method: "DELETE", success: "Recording deleted.")
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
        } catch { actionError = error.localizedDescription }
    }

    #if DEBUG
    /// Fixture/test seam (build 33): the offline guide fixture pre-generates
    /// its own programme data past a single loaded day, with no server to
    /// extend it from — this tells the grid how far that data actually
    /// reaches, exactly what `extendGuideForward()` would otherwise set.
    func setGuideLoadedUntilForFixture(_ date: Date) { guideLoadedUntil = date }
    #endif
}
