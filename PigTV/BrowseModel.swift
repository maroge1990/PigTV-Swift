import Foundation
import Combine

@MainActor
final class BrowseModel: ObservableObject {
    @Published var guide: [GuideChannel] = []
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
            replacePending = keepVisible && !guide.isEmpty
            if !replacePending { guide = [] }
            guideTotal = 0
            guideHasMore = false
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
        let offset = guideOffset
        let start = window.timeIntervalSince1970 * 1000
        let query = [
            URLQueryItem(name: "start", value: String(Int64(start))),
            URLQueryItem(name: "end", value: String(Int64(start + GuideNavigation.loadedDuration * 1000))),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        do {
            let page = try await client.guidePage(query: query)
            guard generation == guideGeneration else { return }
            if replacePending {
                replacePending = false
                guide = page.channels
            } else {
                var seen = Set(guide.map(\.id))
                guide.append(contentsOf: page.channels.filter { seen.insert($0.id).inserted })
            }
            guideTotal = page.total
            guideOffset = offset + page.channels.count
            guideHasMore = !page.channels.isEmpty && guideOffset < page.total
            fromCache = false
            if offset == 0 { guideLoadedAt = Date() }
            if !guideHasMore { saveCache() }
        } catch {
            guard generation == guideGeneration, !(error is CancellationError) else { return }
            guideError = error.localizedDescription
        }
    }

    // Cached guide: used only while nothing is loaded, and only if it still
    // covers the present. The network load that follows replaces it.
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
    }

    private func saveCache() {
        let snapshot = GuideCache(savedAt: Date(), window: window, channels: guide)
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // Refresh in place when the loaded day is getting stale.
    func refreshGuideIfStale(maxAge: TimeInterval = 4 * 3600) async {
        let loaded = guideLoadedAt ?? .distantPast
        guard fromCache || Date().timeIntervalSince(loaded) > maxAge, !guideBusy else { return }
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
    func programmes(for channel: Channel) -> [GuideProgramme] {
        guide.first { $0.id == channel.id }?.programmes ?? []
    }
    func asChannel(_ channel: GuideChannel) -> Channel {
        Channel(rawID: channel.rawID, sourceId: channel.sourceId, name: channel.name,
            logo: logo(for: channel), category: channel.category, now: nil, next: nil)
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
