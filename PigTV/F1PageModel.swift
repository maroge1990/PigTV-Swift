import Foundation
import Combine

/// C-P (#21): the Formula 1 page's data and the account's sport page preferences, read only (#278: Hide scores is
/// written only by Settings › Sport's model). One per signed-in session, owned by BrowseModel; used only when the server advertises `sportPages`. Loaded when the page opens and every
/// 60 s while it is on screen (the server keeps ESPN's answer 10 min on a race weekend, so a reload is cheap and
/// moves a session's status and its channels as the guide gains them).
@MainActor
final class F1PageModel: ObservableObject {
    static let refreshInterval: Duration = .seconds(60)

    @Published private(set) var page: F1Page?
    @Published private(set) var preferences = SportPagePreferences()
    /// #162: false until the account's choice is known (a read answered).
    @Published private(set) var preferencesKnown = false
    /// What the page hides: spoiler-free, or not knowing yet whether it is on.
    var hidesSpoilers: Bool { !preferencesKnown || preferences.spoilerFree }
    /// True once one load has finished.
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
    /// Apple 90 (Codex round 2, high): moves on every preferences read and every invalidation; only the latest read applies.
    private var readGeneration = 0
    /// #278 (audit D5): Hide scores changes on their way: until each has answered and been read again,
    /// no read makes the choice known.
    private var changing = 0
    /// #278 (F5): the preferences read in flight. A sport page's two pollers (the front page and its league) ask at once;
    /// the later asker awaits this read instead of sending its own, while it is still fresh for it: no invalidation or
    /// newer read since it began (`read`). Otherwise a new read is sent, and this one's answer is superseded. `waiters`
    /// counts askers not cancelled: when the last one is, so is the read.
    private struct SharedRead {
        let read: Int
        let task: Task<PreferencesRead, Never>
        var waiters = 0
    }
    private var sharedRead: SharedRead?

    init(client: APIClient) {
        self.client = client
    }

    /// #280: what the Formula 1 page shows. `available: false` with nothing on screen is the honest "not available right
    /// now", never a spinner; empty is an answer with no weekend.
    func state(label: String = "Formula 1") -> PageState {
        if let page {
            if !page.available { return .failed(PageWords.leagueNotAvailable(label)) }
            if page.weekend == nil { return stale ? .emptyStale(since: updatedAt) : .empty }
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
            async let pageAnswer: F1Page = self.client.decodedOffMain("sports/pages/f1")
            // Apple 90 (Codex round 1, high): the answer is published only after the preferences, and a failed request
            // leaves the spoiler choice unknown (the scores hidden) rather than keeping the last one.
            await self.revalidatePreferences()
            do {
                let answer = try await pageAnswer
                // "Not ready yet" keeps what is on screen; a later load has it. #280: what is kept is then out of date.
                let kept = !answer.available && self.page?.available == true
                if answer.available || self.page == nil, answer != self.page { self.page = answer }
                self.stale = kept
                if !kept { self.updatedAt = Date() }
                self.error = nil
            } catch {
                // #280 (review of 204, M4): a cancelled request (the page went away; URLError's "cancelled" too) is not
                // a failure: what was on screen is as it was, and a page with nothing yet is still loading.
                if UserMessage.isCancellation(error) { return }
                if self.page == nil { self.error = UserMessage.text(for: error) ?? UserMessage.somethingFailed } else { self.stale = true }
            }
            self.loaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Apple 90 (Codex round 1, high): the household's choice is forgotten (spoilers hidden) until a load answers it
    /// again: a sport page reappearing may have been switched to spoiler-free on another device meanwhile.
    func invalidatePreferences() {
        guard !isFixture else { return }
        readGeneration += 1
        preferencesKnown = false
    }

    /// Apple 90 (Codex round 1, high): the preferences again, for a page that publishes scores only after them; a request
    /// that fails leaves the choice unknown, so the scores stay hidden.
    func revalidatePreferences() async {
        guard !isFixture else { return }
        if await loadPreferences() == .failed { preferencesKnown = false }
    }

    enum PreferencesRead: Equatable { case answered, failed, superseded }

    /// Whether the server answered. Apple 90 (Codex round 2, high): only the latest read counts; one that began before a
    /// newer read or an `invalidatePreferences()` changes nothing when it answers (`superseded`), so a slow old answer
    /// (an F1 backdrop load that outlived the front page) cannot undo a newer one.
    @discardableResult
    private func loadPreferences() async -> PreferencesRead {
        let shared: SharedRead
        if let current = sharedRead, current.read == readGeneration {
            shared = current
        } else {
            readGeneration += 1
            let read = readGeneration
            let task = Task { [weak self] () -> PreferencesRead in
                guard let self else { return .superseded }
                let outcome = await self.readPreferences(read: read)
                // Before any asker resumes: a later tick sends its own request.
                if self.sharedRead?.read == read { self.sharedRead = nil }
                return outcome
            }
            shared = SharedRead(read: read, task: task)
            sharedRead = shared
        }
        let read = shared.read
        sharedRead?.waiters += 1
        return await withTaskCancellationHandler {
            await shared.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.leaveRead(read) }
        }
    }

    /// An asker of `read` was cancelled (its page went away); the last one cancels the request, as before it was shared.
    private func leaveRead(_ read: Int) {
        guard var current = sharedRead, current.read == read else { return }
        current.waiters -= 1
        if current.waiters > 0 { sharedRead = current; return }
        sharedRead = nil
        current.task.cancel()
    }

    private func readPreferences(read: Int) async -> PreferencesRead {
        do {
            let answer: SportPagePreferences = try await client.request("sports/pages/preferences")
            // #278 (D5): a read answering while a Hide scores change is on its way may predate it: it changes nothing.
            guard read == readGeneration, changing == 0 else { return .superseded }
            if answer != preferences { preferences = answer }
            preferencesKnown = true
            return .answered
        } catch {
            guard read == readGeneration else { return .superseded }
            // Anything else keeps what is on screen, and an unknown choice stays unknown (#162).
            return .failed
        }
    }

    /// #278 (audit D5): a Hide scores change is about to be sent (by Settings › Sport's model, the one writer). From now
    /// until `endChange()`, the choice is unknown and no read makes it known: every sport screen hides the scores.
    func beginChange() {
        changing += 1
        invalidatePreferences()
    }

    /// The change has answered (saved or not): the choice is read again, and the screens show what the server says.
    func endChange() async {
        changing = max(0, changing - 1)
        invalidatePreferences()
        await revalidatePreferences()
    }

    /// Loads now, then every 60 s until the calling task is cancelled (the page went away).
    /// Apple 90 (Codex round 1, high): the page (re)appearing forgets the spoiler choice until the first load answers it.
    func keepFresh() async {
        invalidatePreferences()
        await load()
        while !Task.isCancelled {
            schedule = RefreshSchedule(after: Self.refreshInterval)
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            await load()
        }
    }

    #if DEBUG
    /// #280: a fixture that stays loading.
    var holdsLoading = false

    /// #280 (`PIGTV_UI_TEST_LEAGUE_STATE`): the page in one of its states for the simulator and UI tests: `loading`,
    /// `failed`, `unavailable` (the server's `available: false`), `empty` (no weekend), `stale` (its refresh failed).
    /// The preferences stay as the fixture set them.
    func setFixtureState(_ state: String) {
        isFixture = true
        switch state {
        case "loading": holdsLoading = true; page = nil; loaded = false
        case "failed": page = nil; error = "fixture"; loaded = true
        case "unavailable": page = F1Page(available: false); loaded = true
        case "empty": page = F1Page(available: true); loaded = true
        case "stale": stale = true; updatedAt = Date().addingTimeInterval(-25 * 60)
        default: break
        }
    }

    func setFixture(_ page: F1Page, preferences: SportPagePreferences = SportPagePreferences()) {
        isFixture = true
        self.page = page
        self.preferences = preferences
        preferencesKnown = true
        loaded = true
    }
    #endif
}
