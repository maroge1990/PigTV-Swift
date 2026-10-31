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
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?

    init(client: APIClient) { self.client = client }

    var hasLiveMatch: Bool { page?.lead?.status == .live || page?.others.contains { $0.status == .live } == true }

    func load() async {
        if let inFlight { await inFlight.value; return }
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
            // "Not ready yet" keeps what is on screen; a later load has it.
            if answer.available || page == nil, answer != page { page = answer }
            error = nil
        case .failure(let failure):
            if !(failure is CancellationError), page == nil { error = UserMessage.text(for: failure) }
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
            do { try await Task.sleep(for: hasLiveMatch ? Self.liveRefreshInterval : Self.refreshInterval) } catch { return }
            await refresh(preferences: preferences)
        }
    }

    #if DEBUG
    func setFixture(_ page: CricketPage) {
        isFixture = true
        self.page = page
        loaded = true
    }
    #endif
}
