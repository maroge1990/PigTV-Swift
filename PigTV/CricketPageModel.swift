import Foundation
import Combine

/// C-S (#21): the Cricket page's data. One per signed-in session, owned by BrowseModel; used only when the server
/// advertises `sportPageCricket`. The household's preferences (spoiler-free, the followed teams) are the F1 page model's,
/// shared by every sport page. Loaded when the page opens and every 60 s while it is on screen (30 s while a match is in
/// play: the server keeps ESPN's answer 2 min then, so a reload moves the score).
@MainActor
final class CricketPageModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)
    static let liveRefreshInterval: Duration = .seconds(30)

    @Published private(set) var page: CricketPage?
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// #280: the last refresh failed (or answered "not ready yet") while a page was on screen; when the page shown came.
    @Published private(set) var stale = false
    @Published private(set) var updatedAt: Date?
    /// #280: the polling's next request, for a failed page's countdown (one retry clock).
    @Published private(set) var schedule: RefreshSchedule?
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?

    init(client: APIClient) { self.client = client }

    var hasLiveMatch: Bool { page?.lead?.status == .live || page?.others.contains { $0.status == .live } == true }

    /// #280: what the page shows (`label`: its name on screen). `available: false` with nothing on screen is the honest
    /// "not available right now", never a spinner; empty is no lead match and no others.
    func state(label: String) -> PageState {
        if let page {
            if !page.available { return .failed(PageWords.leagueNotAvailable(label)) }
            if page.lead == nil && page.others.isEmpty { return stale ? .emptyStale(since: updatedAt) : .empty }
            return stale ? .stale(since: updatedAt) : .content
        }
        return PageState.of(loaded: loaded, hasAnswer: false, isEmpty: false, failed: error != nil, stale: false, since: nil,
                            failure: PageWords.leagueFailed(label))
    }

    func load() async {
        if let inFlight { await inFlight.value; return }
        #if DEBUG
        if holdsLoading { return }
        #endif
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.publish(await self.fetch())
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func fetch() async -> Result<CricketPage, Error>? {
        guard !isFixture else { return nil }
        do { return .success(try await client.decodedOffMain("sports/pages/cricket")) } catch { return .failure(error) }
    }

    private func publish(_ result: Result<CricketPage, Error>?) {
        switch result {
        case .success(let answer):
            // "Not ready yet" keeps what is on screen; a later load has it. #280: what is kept is then out of date.
            let kept = !answer.available && page?.available == true
            if answer.available || page == nil, answer != page { page = answer }
            stale = kept
            if !kept { updatedAt = Date() }
            error = nil
        case .failure(let failure):
            // #280 (review of 204, M4): a cancelled request (the page went away; URLError's "cancelled" too) is not a
            // failure: what was on screen is as it was, and a page with nothing yet is still loading.
            if UserMessage.isCancellation(failure) { return }
            if page == nil { error = UserMessage.text(for: failure) ?? UserMessage.somethingFailed } else { stale = true }
        case nil:
            break
        }
        loaded = true
    }

    /// The page and the household's preferences (spoiler-free switched on elsewhere reaches an open page). Apple 90
    /// (Codex round 1, high): the answer is fetched alongside the preferences but published only once they have
    /// answered, so new scores never show under a spoiler choice that has since changed; a failed preferences request
    /// leaves the choice unknown, and the scores hidden.
    func refresh(preferences: F1PageModel?) async {
        #if DEBUG
        if holdsLoading { return }
        #endif
        guard let preferences else { await load(); return }
        async let answer = fetch()
        await preferences.revalidatePreferences()
        publish(await answer)
    }

    /// Refreshes now, then again on the interval until the calling task is cancelled (the page went away). The page
    /// (re)appearing forgets the household's spoiler choice until it is answered again: the scores already on hand stay
    /// hidden meanwhile.
    func keepFresh(preferences: F1PageModel? = nil) async {
        preferences?.invalidatePreferences()
        await refresh(preferences: preferences)
        while !Task.isCancelled {
            let wait = hasLiveMatch ? Self.liveRefreshInterval : Self.refreshInterval
            schedule = RefreshSchedule(after: wait)
            do { try await Task.sleep(for: wait) } catch { return }
            await refresh(preferences: preferences)
        }
    }

    #if DEBUG
    /// #280: a fixture that stays loading.
    var holdsLoading = false

    /// #280 (`PIGTV_UI_TEST_LEAGUE_STATE`): the page in one of its states for the simulator and UI tests: `loading`,
    /// `failed`, `unavailable` (the server's `available: false`), `empty`, `stale` (the fixture's page, its refresh failed).
    func setFixtureState(_ state: String) {
        isFixture = true
        switch state {
        case "loading": holdsLoading = true; page = nil; loaded = false
        case "failed": page = nil; error = "fixture"; loaded = true
        case "unavailable": page = CricketPage(available: false); loaded = true
        case "empty": page = CricketPage(available: true); loaded = true
        case "stale": stale = true; updatedAt = Date().addingTimeInterval(-25 * 60)
        default: break
        }
    }

    func setFixture(_ page: CricketPage) {
        isFixture = true
        self.page = page
        loaded = true
    }
    #endif
}
