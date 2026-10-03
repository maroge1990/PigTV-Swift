import Foundation
import Combine

/// C-I: the next 72 hours of sport events (`GET sports/events?hours=72`;
/// build 32, a whole weekend: an older server clamps it silently),
/// kept fresh every 60 s while a Sport surface (the Sport tab or Home's
/// "Sport now & next") is on screen. One per signed-in session, owned by
/// BrowseModel; used only when the server advertises `sportsEvents`.
@MainActor
final class SportModel: ObservableObject {
    static let hours = 72
    static let refreshInterval: Duration = .seconds(60)

    @Published private(set) var events: [SportEvent] = [] { didSet { eventsVersion &+= 1 } }
    /// Everything the screens draw, built together: the buckets, the league
    /// chips and each league's filtered rows, at a whole-minute clock. It is
    /// republished only when events change or the minute turns (see
    /// `advance(to:)`), so a screen appearing, or a 60 s tick inside the same
    /// minute, re-renders nothing (audit R04/R05).
    @Published private(set) var snapshot = SportSnapshot(clock: SportRows.minute(Date()))
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
    /// Bumped whenever `events` changes; `builtVersion` is the one the
    /// snapshot was built from.
    private var eventsVersion = 0
    private var builtVersion = -1

    init(client: APIClient) { self.client = client }

    /// The time the rows are drawn at: the start of the current minute.
    var clock: Date { snapshot.clock }
    var buckets: SportBuckets { snapshot.buckets }
    var live: [SportEvent] { buckets.live }
    var soon: [SportEvent] { buckets.soon }
    var later: [SportEvent] { buckets.later }
    var tomorrow: [SportEvent] { buckets.tomorrow }
    var days: [SportDay] { buckets.days }
    var replays: [SportEvent] { buckets.replays }
    var leagues: [String] { snapshot.leagues }
    var leagueCounts: [String: Int] { snapshot.leagueCounts }

    /// The rows for one league chip (nil: All), precomputed with the
    /// snapshot rather than filtered on every render.
    func rows(league: String?) -> SportBuckets { snapshot.rows(league: league) }

    /// Rebuilds the snapshot for `now`, but only when the events changed or
    /// the minute turned: bucket boundaries, "in 12 min" and the progress bars
    /// all move on whole minutes, so nothing finer needs a republish. The
    /// work is pure (`SportRows.snapshot`) and a few hundred events cost well
    /// under a millisecond, so it stays on the main actor rather than racing
    /// a generation check (measured in `SportTests`).
    func advance(to now: Date) {
        let minute = SportRows.minute(now)
        guard builtVersion != eventsVersion || minute != snapshot.clock else { return }
        let new = SportRows.snapshot(events, now: minute)
        builtVersion = eventsVersion
        if new != snapshot { snapshot = new }
    }

    /// Fetches the events. Concurrent callers share one request; an older
    /// server without the route (404) simply has none.
    func load() async {
        if let inFlight { await inFlight.value; return }
        let now = Date()
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response: SportEventsResponse = try await self.client.decodedOffMain("sports/events",
                    query: [URLQueryItem(name: "hours", value: String(Self.hours))])
                if response.events != self.events { self.events = response.events }
                self.error = nil
            } catch is CancellationError {
            } catch {
                if error as? PigTVError == .http(404) {
                    if !self.events.isEmpty { self.events = [] }
                } else { self.error = error.localizedDescription }
            }
            self.advance(to: now)
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
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 30 {
            advance(to: Date())
        } else {
            await load()
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            if let lastLoad, Date().timeIntervalSince(lastLoad) < 30 {
                advance(to: Date())
                continue
            }
            await load()
        }
    }

    #if DEBUG
    func setFixture(_ events: [SportEvent]) {
        isFixture = true
        self.events = events
        advance(to: Date())
        loaded = true
    }
    #endif
}

/// A counter that moves when the logos a Sport card could draw may have
/// changed (the guide gained channels, the artwork index arrived). Cards take
/// it as plain input instead of observing `BrowseModel`, which publishes
/// ~25 properties (guide pages, recordings, favourites, busy flags) that
/// have nothing to do with a card (audit R04). Debounced, since the guide
/// pages in many times while it loads.
@MainActor
final class SportLogoRevision: ObservableObject {
    @Published private(set) var value = 0
    private var cancellable: AnyCancellable?

    init(following browse: BrowseModel) {
        cancellable = Publishers.Merge(browse.$guide.dropFirst().map { _ in () },
                                       browse.$artworkIndex.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.value += 1 }
    }
}
