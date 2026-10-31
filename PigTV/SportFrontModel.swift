import Foundation
import Combine

/// C-R (#21, D-39): the Sport front page's data and its hero. One per signed-in session, owned by BrowseModel; used only
/// when the server advertises `sportFront`. Loaded when the page opens, then every 20 s while a game is under way and
/// every 60 s otherwise, while the page is on screen.
@MainActor
final class SportFrontModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)
    static let liveRefreshInterval: Duration = .seconds(20)

    @Published private(set) var front: SportFront?
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// The last refresh failed: what is shown is an older answer (`updatedAt`).
    @Published private(set) var stale = false
    /// When the answer shown was received.
    @Published private(set) var updatedAt: Date?
    /// The game the hero band shows (`SportFrontHero`).
    @Published private(set) var heroID: String?
    /// The follow the viewer flipped the hero to, by key (league and name), so a list reordered on another device keeps
    /// it (nil: the server's hero, kept while it is on).
    @Published private(set) var selectedFollowKey: String?
    /// Its index in the current answer.
    var selectedFollow: Int? {
        guard let selectedFollowKey else { return nil }
        return front?.follows.firstIndex { $0.key == selectedFollowKey }
    }
    /// A card the viewer made the hero with a long press; it wins while it is on the page.
    @Published private(set) var pinned: SportsGame.ID?
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?

    init(client: APIClient) { self.client = client }

    var heroGame: SportsGame? { front?.game(heroID) }
    /// The follow the hero belongs to, for the list's highlight.
    var heroFollowIndex: Int? {
        guard let front, let heroID else { return nil }
        if let selectedFollow, front.follows.indices.contains(selectedFollow), front.follows[selectedFollow].gameId == heroID {
            return selectedFollow
        }
        if let index = front.hero.followIndex, front.follows.indices.contains(index), front.follows[index].gameId == heroID {
            return index
        }
        return front.follows.firstIndex { $0.gameId == heroID }
    }

    var interval: Duration { front?.hasLiveGame == true ? Self.liveRefreshInterval : Self.refreshInterval }

    /// Takes a new answer: a follow that has gone live replaces a flip; a pinned card that left the page or finished is
    /// let go, and so is a flip whose game is no longer under way (a finished game does not stay the hero all day).
    func apply(_ answer: SportFront) {
        let wentLive = SportFrontHero.followsGoneLive(previous: front, front: answer)
        if !wentLive.isEmpty { selectedFollowKey = nil }
        if let pinned, answer.game(pinned).map({ $0.terminal }) ?? true { self.pinned = nil }
        if let key = selectedFollowKey {
            let index = answer.follows.firstIndex { $0.key == key }
            let wasOn = front?.game(heroID).map { SportFrontHero.ongoing.contains($0.status) } ?? false
            let isOn = answer.game(heroID).map { SportFrontHero.ongoing.contains($0.status) } ?? false
            let finished = index.flatMap { answer.game(answer.follows[$0].gameId) }?.terminal ?? false
            if index == nil || (wasOn && !isOn) || finished { selectedFollowKey = nil }
        }
        let selected = selectedFollowKey.flatMap { key in answer.follows.firstIndex { $0.key == key } }
        let hero = SportFrontHero.resolve(current: heroID, front: answer, wentLive: wentLive,
                                          selectedFollow: selected, pinned: pinned)
        if answer != front { front = answer }
        if hero != heroID { heroID = hero }
    }

    /// The viewer flipped the hero to a follow (its live or next game).
    func select(follow index: Int) {
        guard let front, front.follows.indices.contains(index) else { return }
        pinned = nil
        selectedFollowKey = front.follows[index].key
        heroID = SportFrontHero.resolve(current: heroID, front: front, wentLive: [], selectedFollow: index, pinned: nil)
    }

    /// Long press "Make this the hero".
    func pin(_ id: SportsGame.ID) {
        guard let front, front.game(id) != nil else { return }
        selectedFollowKey = nil
        pinned = id
        heroID = id
    }

    func load() async {
        if let inFlight { await inFlight.value; return }
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer: SportFront = try await self.client.decodedOffMain("sports/front")
                self.apply(answer)
                self.error = nil
                self.stale = false
                self.updatedAt = Date()
            } catch is CancellationError {
            } catch {
                if self.front == nil { self.error = UserMessage.text(for: error) } else { self.stale = true }
            }
            self.loaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Loads now, then on the interval until the calling task is cancelled (the page went away).
    /// The household's spoiler-free switch as the sport pages hold it (`preferences`) is refreshed with each load, so a
    /// change made elsewhere hides scores before the next answer arrives.
    func keepFresh(preferences: F1PageModel? = nil) async {
        await refresh(preferences: preferences)
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            await refresh(preferences: preferences)
        }
    }

    func refresh(preferences: F1PageModel?) async {
        await preferences?.refreshPreferences()
        await load()
    }

    #if DEBUG
    func setFixture(_ front: SportFront) {
        isFixture = true
        apply(front)
        loaded = true
    }
    #endif
}
