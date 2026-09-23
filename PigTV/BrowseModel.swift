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
            let page = try await client.guidePage(query: query)
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
        } catch {
            guard generation == guideGeneration, !(error is CancellationError) else { return }
            guideError = error.localizedDescription
        }
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
        artworkBusy = true
        artworkError = nil
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

    func loadRecordings() async {
        guard !recordingsBusy else { return }
        recordingsBusy = true
        recordingsError = nil
        defer { recordingsBusy = false }
        do {
            let files: [Recording] = try await client.request("recordings")
            recordings = files
            let planned: [ScheduledRecording] = try await client.request("recordings/scheduled")
            schedules = planned
        } catch { recordingsError = error.localizedDescription }
    }

    func loadFavourites() async {
        guard !favouritesBusy else { return }
        favouritesBusy = true
        favouritesError = nil
        defer { favouritesBusy = false }
        do { favourites = try await client.request("library/favourites") }
        catch { favouritesError = error.localizedDescription }
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
}
