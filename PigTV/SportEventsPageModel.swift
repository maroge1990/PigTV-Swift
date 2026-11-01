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
            if answer.available || pages[league] == nil, answer != pages[league] { pages[league] = answer }
            errors[league] = nil
        case .failure(let failure):
            if !(failure is CancellationError), pages[league] == nil { errors[league] = UserMessage.text(for: failure) }
        case nil:
            break
        }
        loaded.insert(league)
    }

    func load(_ league: String) async {
        if let running = inFlight[league] { await running.value; return }
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
        guard let preferences else { await load(league); return }
        async let answer = fetch(league)
        await preferences.revalidatePreferences()
        publish(await answer, league: league)
    }

    /// Refreshes now, then on the interval until the calling task is cancelled (the league went off screen).
    func keepFresh(_ league: String, preferences: F1PageModel? = nil) async {
        await refresh(league, preferences: preferences)
        while !Task.isCancelled {
            do { try await Task.sleep(for: hasLiveGame(league) ? Self.liveRefreshInterval : Self.refreshInterval) } catch { return }
            await refresh(league, preferences: preferences)
        }
    }

    #if DEBUG
    func setFixture(_ page: SportEventsPage, league: String) {
        isFixture = true
        pages[league] = page
        loaded.insert(league)
    }
    #endif
}
