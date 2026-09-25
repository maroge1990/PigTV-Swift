import Foundation
import Combine

/// C-I: the next 12 hours of sport events (`GET sports/events?hours=12`),
/// kept fresh every 60 s while a Sport surface (the Sport tab or Home's
/// "Sport now & next") is on screen. One per signed-in session, owned by
/// BrowseModel; used only when the server advertises `sportsEvents`.
@MainActor
final class SportModel: ObservableObject {
    static let hours = 12
    static let refreshInterval: Duration = .seconds(60)

    @Published private(set) var events: [SportEvent] = []
    /// The time the buckets are drawn at (advanced on every refresh).
    @Published private(set) var clock = Date()
    /// True once one load has finished (the empty state waits for it).
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// Set by the offline fixtures: no requests.
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?
    /// Surfaces currently keeping the data fresh (Home and Sport can both be
    /// alive in a TabView); one refresh per interval is enough.
    private var lastLoad: Date?

    init(client: APIClient) { self.client = client }

    var buckets: SportBuckets { SportRows.buckets(events, now: clock) }
    var live: [SportEvent] { buckets.live }
    var soon: [SportEvent] { buckets.soon }
    var later: [SportEvent] { buckets.later }
    var leagues: [String] { SportRows.leagues(buckets.all) }

    /// Fetches the events. Concurrent callers share one request; an older
    /// server without the route (404) simply has none.
    func load() async {
        if let inFlight { await inFlight.value; return }
        clock = Date()
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response: SportEventsResponse = try await self.client.request("sports/events",
                    query: [URLQueryItem(name: "hours", value: String(Self.hours))])
                self.events = response.events
                self.error = nil
            } catch is CancellationError {
            } catch {
                if error as? PigTVError == .http(404) { self.events = [] }
                else { self.error = error.localizedDescription }
            }
            self.clock = Date()
            self.loaded = true
            self.lastLoad = Date()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Loads now (unless another surface just did), then every 60 s until
    /// the calling task is cancelled (the surface went away).
    func keepFresh() async {
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 30 { clock = Date() } else { await load() }
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            if let lastLoad, Date().timeIntervalSince(lastLoad) < 30 { clock = Date(); continue }
            await load()
        }
    }

    #if DEBUG
    func setFixture(_ events: [SportEvent]) {
        isFixture = true
        self.events = events
        clock = Date()
        loaded = true
    }
    #endif
}
