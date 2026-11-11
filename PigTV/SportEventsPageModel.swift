import Foundation
import Combine

/// C-V (#197, D-43): the events pages (tennis, golf, UFC, IndyCar, NASCAR), one answer per league, kept for the
/// session. Owned by BrowseModel; asked for only with the server's `sportPageEvents`, when a sport page shows the league
/// (golf also its other followed leagues, for Also this week), then every 60 s (30 s while an event is on). The account's preferences (spoiler-free) are the F1 page model's, revalidated
/// before each answer is published (Apple 90's rule: scores stay hidden until the choice is known).
@MainActor
final class SportEventsPageModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)
    static let liveRefreshInterval: Duration = .seconds(30)

    @Published private(set) var pages: [String: SportEventsPage] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loaded: Set<String> = []
    /// #280: leagues whose last refresh failed (or answered "not ready yet") while a page was on screen, and when each
    /// page shown was received.
    @Published private(set) var stale: Set<String> = []
    @Published private(set) var updatedAt: [String: Date] = [:]
    /// #280: the polling's next request, for a failed page's countdown (one retry clock).
    @Published private(set) var schedules: [String: RefreshSchedule] = [:]
    var isFixture = false
    let client: APIClient
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(client: APIClient) { self.client = client }

    func hasLiveGame(_ league: String) -> Bool {
        pages[league]?.events.contains { SportEventsText.ongoing.contains($0.status) } == true
    }

    private func fetch(_ league: String) async -> Result<SportEventsPage, Error>? {
        guard !isFixture else { return nil }
        guard SportEventLeagues.all.contains(league) else { return nil }
        do {
            return .success(try await client.decodedOffMain("sports/pages/events", query: [URLQueryItem(name: "league", value: league)]))
        } catch { return .failure(error) }
    }

    private func publish(_ result: Result<SportEventsPage, Error>?, league: String) {
        switch result {
        case .success(let answer):
            // #280: "not ready yet" keeps a page already on screen, which is then out of date (the notice says so).
            let kept = !answer.available && pages[league]?.available == true
            if answer.available || pages[league] == nil, answer != pages[league] { pages[league] = answer }
            if kept { stale.insert(league) } else { stale.remove(league); updatedAt[league] = Date() }
            errors[league] = nil
        case .failure(let failure):
            if !(failure is CancellationError) {
                if pages[league] == nil { errors[league] = UserMessage.text(for: failure) } else { stale.insert(league) }
            }
        case nil:
            break
        }
        loaded.insert(league)
    }

    /// #280: what the league's page shows (`label`: its name on screen). `available: false` with nothing on screen is
    /// the honest "not available right now", never a spinner; empty is no events, last winner or next race.
    func state(_ league: String, label: String) -> PageState {
        if let page = pages[league] {
            if !page.available { return .failed(PageWords.leagueNotAvailable(label)) }
            if page.events.isEmpty && page.lastWinner == nil && page.next == nil { return .empty }
            return stale.contains(league) ? .stale(since: updatedAt[league]) : .content
        }
        return PageState.of(loaded: loaded.contains(league), hasAnswer: false, isEmpty: false, failed: errors[league] != nil,
                            stale: false, since: nil, failure: PageWords.leagueFailed(label))
    }

    func load(_ league: String) async {
        if let running = inFlight[league] { await running.value; return }
        #if DEBUG
        if holdsLoading { return }
        #endif
        guard !isFixture else { loaded.insert(league); return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.publish(await self.fetch(league), league: league)
        }
        inFlight[league] = task
        await task.value
        inFlight[league] = nil
    }

    func refresh(_ league: String, preferences: F1PageModel?) async {
        #if DEBUG
        if holdsLoading { return }
        #endif
        guard let preferences else { await load(league); return }
        async let answer = fetch(league)
        await preferences.revalidatePreferences()
        publish(await answer, league: league)
    }

    /// Refreshes now, then on the interval until the calling task is cancelled (the league went off screen).
    func keepFresh(_ league: String, preferences: F1PageModel? = nil) async {
        await refresh(league, preferences: preferences)
        while !Task.isCancelled {
            let wait = hasLiveGame(league) ? Self.liveRefreshInterval : Self.refreshInterval
            schedules[league] = RefreshSchedule(after: wait)
            do { try await Task.sleep(for: wait) } catch { return }
            await refresh(league, preferences: preferences)
        }
    }

    #if DEBUG
    /// #280: a fixture that stays loading.
    var holdsLoading = false

    /// #280 (`PIGTV_UI_TEST_LEAGUE_STATE`): `league` in one of its states for the simulator and UI tests: `loading`,
    /// `failed`, `unavailable` (the server's `available: false`), `stale` (the fixture's page, its refresh failed).
    func setFixtureState(_ state: String, league: String) {
        isFixture = true
        switch state {
        case "loading": holdsLoading = true; pages[league] = nil; loaded.remove(league)
        case "failed": pages[league] = nil; errors[league] = "fixture"; loaded.insert(league)
        case "unavailable": pages[league] = .init(available: false); loaded.insert(league)
        case "empty": pages[league] = .init(available: true); loaded.insert(league)
        case "stale": stale.insert(league); updatedAt[league] = Date().addingTimeInterval(-25 * 60)
        default: break
        }
    }

    func setFixture(_ page: SportEventsPage, league: String) {
        isFixture = true
        pages[league] = page
        loaded.insert(league)
    }
    #endif
}
