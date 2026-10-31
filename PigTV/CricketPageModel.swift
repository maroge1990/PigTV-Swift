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
            do {
                let answer: CricketPage = try await self.client.decodedOffMain("sports/pages/cricket")
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

    /// The page and the household's preferences (spoiler-free switched on elsewhere reaches an open page).
    func refresh(preferences: F1PageModel?) async {
        await load()
        await preferences?.refreshPreferences()
    }

    /// Refreshes now, then again on the interval until the calling task is cancelled (the page went away).
    func keepFresh(preferences: F1PageModel? = nil) async {
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
