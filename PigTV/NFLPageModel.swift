import Foundation
import Combine

/// C-Q (#21): the NFL page's data. One per signed-in session, owned by BrowseModel; used only when the server
/// advertises `sportPageNfl`. The household's preferences (spoiler-free, the followed team) are the F1 page model's,
/// shared by every sport page. Loaded when the page opens and every 60 s while it is on screen (30 s while a game is
/// on: the server keeps ESPN's answer 2 min then, so a reload moves the score and clock).
@MainActor
final class NFLPageModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)
    static let liveRefreshInterval: Duration = .seconds(30)

    @Published private(set) var page: NFLPage?
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?

    init(client: APIClient) { self.client = client }

    var hasLiveGame: Bool { page?.weeks.contains { $0.games.contains { $0.status == .live } } == true }

    func load() async {
        if let inFlight { await inFlight.value; return }
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: NFLPage = try await self.client.decodedOffMain("sports/pages/nfl")
                // "Not ready yet" keeps what is on screen; a later load has it.
                if answer.available || self.page == nil, answer != self.page { self.page = answer }
                self.error = nil
            } catch is CancellationError {
            } catch {
                if self.page == nil { self.error = UserMessage.text(for: error) }
            }
            self.loaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Loads now, then again on the interval until the calling task is cancelled (the page went away).
    func keepFresh() async {
        await load()
        while !Task.isCancelled {
            do { try await Task.sleep(for: hasLiveGame ? Self.liveRefreshInterval : Self.refreshInterval) } catch { return }
            await load()
        }
    }

    #if DEBUG
    func setFixture(_ page: NFLPage) {
        isFixture = true
        self.page = page
        loaded = true
    }
    #endif
}
