import UIKit
import XCTest
@testable import PigTV

// #280 (brand 1.8 §14): every Sport page model says which of its four states the page is in (`PageState`), and the
// words of those states are plain sentences. Before this, each view worked its state out inline: a first load that failed
// left the sport pages spinning for ever (no error branch), and a league page whose server answered `available: false`
// spun for ever too. The models are loaded against a stub server (`StateRoutes`): the server's own answers from the
// fixtures, `{}` / `{"available":true}` for an empty one, `{"available":false}`, or a 500.
@MainActor
final class PageStateTests: XCTestCase {
    private static let base = "/api/sports"

    override func setUp() {
        super.setUp()
        StateRoutes.reset()
    }

    override func tearDown() {
        StateRoutes.reset()
        super.tearDown()
    }

    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateRoutes.self]
        return APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                         session: URLSession(configuration: configuration))
    }

    private func fixture(_ name: String) throws -> Data { try SportFrontLayoutTests.fixture(name) }

    private func pagesPart(_ path: [String]) throws -> Data {
        var value: Any = try SportPagesFixture.json()
        for key in path { value = try XCTUnwrap((value as? [String: Any])?[key], "no \(key)") }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private static let empty = Data("{}".utf8)
    private static let emptyPage = Data(#"{"available":true}"#.utf8)
    private static let notAvailable = Data(#"{"available":false}"#.utf8)

    // MARK: The shared type

    func testTheStateOfAOneAnswerPage() {
        let failure = PageWords.sportFailed
        XCTAssertEqual(PageState.of(loaded: false, hasAnswer: false, isEmpty: false, failed: false, stale: false, since: nil,
                                    failure: failure), .loading)
        XCTAssertEqual(PageState.of(loaded: true, hasAnswer: false, isEmpty: false, failed: true, stale: false, since: nil,
                                    failure: failure), .failed(failure))
        XCTAssertEqual(PageState.of(loaded: true, hasAnswer: true, isEmpty: true, failed: false, stale: false, since: nil,
                                    failure: failure), .empty)
        XCTAssertEqual(PageState.of(loaded: true, hasAnswer: true, isEmpty: false, failed: false, stale: false, since: nil,
                                    failure: failure), .content)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = PageState.of(loaded: true, hasAnswer: true, isEmpty: false, failed: true, stale: true, since: when,
                                 failure: failure)
        XCTAssertEqual(stale, .stale(since: when), "a failed refresh with an answer held keeps it")
        XCTAssertTrue(stale.showsContent)
        XCTAssertTrue(PageState.content.showsContent)
        XCTAssertFalse(PageState.loading.showsContent)
        XCTAssertFalse(PageState.empty.showsContent)
        XCTAssertEqual(PageState.failed(failure).failure, failure)
        XCTAssertNil(stale.failure)
        // Codex round 1 (medium): an empty answer whose refresh failed is empty and stale at once.
        let emptyStale = PageState.of(loaded: true, hasAnswer: true, isEmpty: true, failed: true, stale: true, since: when,
                                      failure: failure)
        XCTAssertEqual(emptyStale, .emptyStale(since: when))
        XCTAssertTrue(emptyStale.showsEmpty)
        XCTAssertTrue(emptyStale.isStale)
        XCTAssertFalse(emptyStale.showsContent)
        XCTAssertEqual(emptyStale.staleSince, when)
        XCTAssertNil(emptyStale.failure)
        XCTAssertTrue(PageState.empty.showsEmpty)
        XCTAssertFalse(PageState.empty.isStale)
        XCTAssertTrue(stale.isStale)
        XCTAssertFalse(stale.showsEmpty)
        XCTAssertEqual(stale.staleSince, when)
    }

    // MARK: The Sport front page (and the sport pages, which share its answer)

    func testFrontLoadsToContent() async throws {
        StateRoutes.set("\(Self.base)/front", body: try fixture("sport-front-0381.json"))
        let m = SportFrontModel(client: try client())
        XCTAssertEqual(m.state, .loading)
        await m.load()
        XCTAssertEqual(m.state, .content)
    }

    func testFrontLoadsToEmpty() async throws {
        StateRoutes.set("\(Self.base)/front", body: Self.empty)
        let m = SportFrontModel(client: try client())
        await m.load()
        XCTAssertEqual(m.state, .empty, "nothing followed")
    }

    func testFrontFirstLoadThatFailsEndsInTheErrorNotASpinner() async throws {
        StateRoutes.set("\(Self.base)/front", status: 500)
        let m = SportFrontModel(client: try client())
        await m.load()
        XCTAssertEqual(m.state, .failed(PageWords.sportFailed))
        StateRoutes.set("\(Self.base)/front", body: try fixture("sport-front-0381.json"))
        await m.load()
        XCTAssertEqual(m.state, .content, "Try again recovers")
    }

    func testFrontRefreshThatFailsKeepsTheContentAndSaysItIsStale() async throws {
        StateRoutes.set("\(Self.base)/front", body: try fixture("sport-front-0381.json"))
        let m = SportFrontModel(client: try client())
        await m.load()
        let shown = m.front
        StateRoutes.set("\(Self.base)/front", status: 500)
        await m.load()
        guard case .stale(let since) = m.state else { return XCTFail("expected stale, got \(m.state)") }
        XCTAssertNotNil(since)
        XCTAssertEqual(m.front, shown, "the content stays")
    }

    // MARK: The league pages

    /// One league page model, driven the same way for each: its route, a full answer, and how to load and read it.
    private struct League {
        let route: String
        let full: Data
        let load: @MainActor () async -> Void
        let state: @MainActor () -> PageState
        let label: String
        /// Its polling while on screen, and the request that polling schedules next.
        var keepFresh: @MainActor () async -> Void = {}
        var schedule: @MainActor () -> RefreshSchedule? = { nil }
        /// The healthy interval when nothing is live, in seconds.
        var healthy: TimeInterval = 60
    }

    private func nfl() throws -> League {
        let m = NFLPageModel(client: try client())
        return League(route: "\(Self.base)/pages/nfl", full: try fixture("nfl-page-0379.json"), load: { await m.load() },
                      state: { m.state(label: "NFL") }, label: "NFL", keepFresh: { await m.keepFresh() }, schedule: { m.schedule },
                      healthy: Self.seconds(NFLPageModel.refreshInterval))
    }

    private func afl() throws -> League {
        let m = LeaguePageModel(client: try client())
        return League(route: "\(Self.base)/pages/league/AFL", full: try pagesPart(["leagues", "AFL"]), load: { await m.load("AFL") },
                      state: { m.state("AFL", label: "AFL") }, label: "AFL", keepFresh: { await m.keepFresh("AFL") },
                      schedule: { m.schedules["AFL"] }, healthy: Self.seconds(LeaguePageModel.refreshInterval))
    }

    private func ufc() throws -> League {
        let m = SportEventsPageModel(client: try client())
        return League(route: "\(Self.base)/pages/events", full: try pagesPart(["events", "UFC"]), load: { await m.load("UFC") },
                      state: { m.state("UFC", label: "UFC") }, label: "UFC", keepFresh: { await m.keepFresh("UFC") },
                      schedule: { m.schedules["UFC"] }, healthy: Self.seconds(SportEventsPageModel.refreshInterval))
    }

    private func f1() throws -> League {
        let m = F1PageModel(client: try client(), defaults: UserDefaults(suiteName: "PageStateTests.f1")!)
        return League(route: "\(Self.base)/pages/f1", full: try fixture("f1-page-0346.json"), load: { await m.load() },
                      state: { m.state(label: "Formula 1") }, label: "Formula 1", keepFresh: { await m.keepFresh() },
                      schedule: { m.schedule }, healthy: Self.seconds(F1PageModel.refreshInterval))
    }

    private func cricket() throws -> League {
        let m = CricketPageModel(client: try client())
        return League(route: "\(Self.base)/pages/cricket", full: try fixture("cricket-page-0387-live.json"), load: { await m.load() },
                      state: { m.state(label: "Cricket") }, label: "Cricket", keepFresh: { await m.keepFresh() },
                      schedule: { m.schedule }, healthy: Self.seconds(CricketPageModel.refreshInterval))
    }

    private func leagues() throws -> [League] { [try nfl(), try afl(), try ufc(), try f1(), try cricket()] }

    func testEachLeaguePageLoadsToContent() async throws {
        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, body: league.full)
            XCTAssertEqual(league.state(), .loading, league.label)
            await league.load()
            XCTAssertEqual(league.state(), .content, league.label)
        }
    }

    func testEachLeaguePageLoadsToEmpty() async throws {
        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, body: Self.emptyPage)
            await league.load()
            XCTAssertEqual(league.state(), .empty, league.label)
        }
    }

    func testEachLeaguePageFirstLoadThatFailsEndsInTheError() async throws {
        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, status: 500)
            await league.load()
            XCTAssertEqual(league.state(), .failed(PageWords.leagueFailed(league.label)), league.label)
        }
    }

    /// The four league pages that spun for ever: `available: false` is an honest state, "not available right now", with
    /// Try again; never loading.
    func testEachLeaguePageNotAvailableEndsInTheNotAvailableStateNeverLoading() async throws {
        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, body: Self.notAvailable)
            await league.load()
            let state = league.state()
            XCTAssertNotEqual(state, .loading, league.label)
            XCTAssertEqual(state, .failed(PageWords.leagueNotAvailable(league.label)), league.label)
            XCTAssertEqual(state.failure?.reason, .notAvailable, league.label)
        }
    }

    func testEachLeaguePageRefreshThatFailsKeepsTheContentAndSaysItIsStale() async throws {
        for league in try leagues() {
            for second in [(500, Self.empty), (200, Self.notAvailable)] {
                StateRoutes.reset()
                StateRoutes.set(league.route, body: league.full)
                await league.load()
                StateRoutes.set(league.route, status: second.0, body: second.1)
                await league.load()
                guard case .stale(let since) = league.state() else {
                    XCTFail("\(league.label) after a \(second.0) refresh: \(league.state())")
                    continue
                }
                XCTAssertNotNil(since, league.label)
                StateRoutes.set(league.route, body: league.full)
                await league.load()
                XCTAssertEqual(league.state(), .content, "\(league.label): the next good answer is current again")
            }
        }
    }

    // MARK: One retry clock

    private static func seconds(_ duration: Duration) -> TimeInterval { Double(duration.components.seconds) }

    /// Waits (up to 3 s) until `route` has been asked `count` times.
    private func waitForRequests(_ route: String, _ count: Int) async {
        for _ in 0..<60 where StateRoutes.count(route) < count { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A failed page asks no more often than a healthy one: its polling schedules the next request at the healthy interval,
    /// nothing else asks in between, and the error view keeps no timer of its own when the model polls.
    func testAFailedPageAsksOnTheModelsOwnScheduleOnly() async throws {
        XCTAssertFalse(PigErrorState.ownsRetryClock(schedule: RefreshSchedule(after: .seconds(60))), "the model's schedule is the retry")
        XCTAssertTrue(PigErrorState.ownsRetryClock(schedule: nil), "a model that does not poll: the view's 20 s retry")
        let schedule = RefreshSchedule(after: .seconds(60), from: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(schedule.remaining(now: Date(timeIntervalSince1970: 1_015)), 45)
        XCTAssertEqual(schedule.fraction(now: Date(timeIntervalSince1970: 1_030)), 0.5, accuracy: 0.001)

        StateRoutes.set("\(Self.base)/front", status: 500)
        let front = SportFrontModel(client: try client())
        let task = Task { await front.keepFresh() }
        await waitForRequests("\(Self.base)/front", 1)
        for _ in 0..<60 where front.schedule == nil { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(front.state, .failed(PageWords.sportFailed))
        XCTAssertEqual(front.schedule?.interval, Self.seconds(SportFrontModel.refreshInterval), "the healthy interval")
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(StateRoutes.count("\(Self.base)/front"), 1, "nothing asks again before the schedule")
        task.cancel()

        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, status: 500)
            let task = Task { await league.keepFresh() }
            await waitForRequests(league.route, 1)
            for _ in 0..<60 where league.schedule() == nil { try? await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(league.state(), .failed(PageWords.leagueFailed(league.label)), league.label)
            XCTAssertEqual(league.schedule()?.interval, league.healthy, "\(league.label): the healthy interval")
            try? await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(StateRoutes.count(league.route), 1, "\(league.label): nothing asks again before the schedule")
            task.cancel()
        }
    }

    // MARK: A retry changes nothing on screen until it has its answer (review of 204–205, H2)

    /// What `state` reads before each poll, while its request is in flight, and after it.
    private func states(_ state: @escaping @MainActor () -> PageState, polls: Int,
                        _ poll: @MainActor () async -> Void) async -> [PageState] {
        var seen: [PageState] = []
        StateRoutes.during = { MainActor.assumeIsolated { seen.append(state()) } }
        defer { StateRoutes.during = nil }
        for _ in 0..<polls {
            seen.append(state())
            await poll()
            seen.append(state())
        }
        return seen
    }

    /// The Sport pages never cleared their failure before asking (unlike the Guide and Recordings before the fix): held
    /// here so they keep to it. Failed → failed, stale → stale, then content on success.
    func testTheSportPagesStayAsTheyAreThroughEachPoll() async throws {
        let frontRoute = "\(Self.base)/front"
        StateRoutes.set(frontRoute, status: 500)
        let front = SportFrontModel(client: try client())
        await front.load()
        var polls = await states({ front.state }, polls: 2) { await front.load() }
        XCTAssertEqual(polls, Array(repeating: .failed(PageWords.sportFailed), count: polls.count), "front: failed → failed")
        StateRoutes.set(frontRoute, body: try fixture("sport-front-0381.json"))
        await front.load()
        XCTAssertEqual(front.state, .content)
        StateRoutes.set(frontRoute, status: 500)
        await front.load()
        let stale = front.state
        XCTAssertTrue(stale.isStale)
        polls = await states({ front.state }, polls: 2) { await front.load() }
        XCTAssertEqual(polls, Array(repeating: stale, count: polls.count), "front: stale → stale")

        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, status: 500)
            await league.load()
            let failed = PageState.failed(PageWords.leagueFailed(league.label))
            polls = await states(league.state, polls: 2) { await league.load() }
            XCTAssertEqual(polls, Array(repeating: failed, count: polls.count), "\(league.label): failed → failed")
            StateRoutes.set(league.route, body: league.full)
            await league.load()
            XCTAssertEqual(league.state(), .content, league.label)
            StateRoutes.set(league.route, status: 500)
            await league.load()
            let stale = league.state()
            XCTAssertTrue(stale.isStale, league.label)
            polls = await states(league.state, polls: 2) { await league.load() }
            XCTAssertEqual(polls, Array(repeating: stale, count: polls.count), "\(league.label): stale → stale")
        }
    }

    // MARK: An empty answer that may be out of date (Codex round 1, medium)

    /// Before: the Sport front's (and each league's) empty state stayed up through a failed refresh with no notice and
    /// no Try again, as if current.
    func testAnEmptyAnswerWhoseRefreshFailsKeepsItsEmptyLayoutWithTheStaleNotice() async throws {
        let frontRoute = "\(Self.base)/front"
        StateRoutes.set(frontRoute, body: Self.empty)
        let front = SportFrontModel(client: try client())
        await front.load()
        XCTAssertEqual(front.state, .empty)
        StateRoutes.set(frontRoute, status: 500)
        await front.load()
        guard case .emptyStale(let since) = front.state else { return XCTFail("front: \(front.state)") }
        XCTAssertNotNil(since)
        XCTAssertTrue(front.state.showsEmpty && front.state.isStale)
        StateRoutes.set(frontRoute, body: Self.empty)
        await front.load()
        XCTAssertEqual(front.state, .empty, "front: a successful refresh clears the notice")

        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, body: Self.emptyPage)
            await league.load()
            XCTAssertEqual(league.state(), .empty, league.label)
            StateRoutes.set(league.route, status: 500)
            await league.load()
            XCTAssertTrue(league.state().showsEmpty && league.state().isStale, "\(league.label): \(league.state())")
            StateRoutes.set(league.route, body: Self.emptyPage)
            await league.load()
            XCTAssertEqual(league.state(), .empty, "\(league.label): a successful refresh clears the notice")
        }
    }

    // MARK: Leaving a page mid-refresh (review of 204, M4)

    /// Before: only Swift's CancellationError counted as a cancellation; URLSession's own "cancelled" (what a page's
    /// request throws when the page goes away) marked a page with content stale, and one without content failed.
    func testACancelledRequestIsNotAFailure() async throws {
        let frontRoute = "\(Self.base)/front"
        StateRoutes.set(frontRoute, body: try fixture("sport-front-0381.json"))
        let front = SportFrontModel(client: try client())
        await front.load()
        StateRoutes.cancelled = [frontRoute]
        await front.load()
        XCTAssertEqual(front.state, .content, "front: no false “Couldn’t update”")
        let fresh = SportFrontModel(client: try client())
        await fresh.load()
        XCTAssertEqual(fresh.state, .loading, "front: still loading, not “didn’t load”")

        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.set(league.route, body: league.full)
            await league.load()
            StateRoutes.cancelled = [league.route]
            await league.load()
            XCTAssertEqual(league.state(), .content, "\(league.label): no false “Couldn’t update”")
        }
        for league in try leagues() {
            StateRoutes.reset()
            StateRoutes.cancelled = [league.route]
            await league.load()
            XCTAssertEqual(league.state(), .loading, "\(league.label): still loading, not “didn’t load”")
        }
    }

    // MARK: Apple TV focus (review of 204–205, M5)

    /// Before: a state's button took focus whenever focus was not in the tab bar, so a league's error or empty state that
    /// appeared under the sport page's banner list pulled focus out of it. Now it takes focus only when focus is nowhere.
    func testAStateTakesFocusOnlyWhenFocusIsNowhere() {
        XCTAssertTrue(PigStateFocus.mayTake(focused: nil), "nothing focused: the state's button takes it")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let row = UIButton(type: .system)
        window.addSubview(row)
        XCTAssertFalse(PigStateFocus.mayTake(focused: row), "a control on screen (a banner row) keeps focus")
        let tabBar = UITabBar()
        window.addSubview(tabBar)
        XCTAssertFalse(PigStateFocus.mayTake(focused: tabBar), "the tab bar keeps focus (205's rule)")
        let gone = UIButton(type: .system)
        XCTAssertTrue(PigStateFocus.mayTake(focused: gone), "a control that left the screen with the content it belonged to")
    }

    // MARK: The words

    /// No state on these pages shows a code, a status or the system's own description of the error.
    func testNoStateWordsCarryACodeOrTheErrorsOwnText() async throws {
        StateRoutes.set("\(Self.base)/front", status: 503)
        let front = SportFrontModel(client: try client())
        await front.load()
        let systemText = try XCTUnwrap(front.error, "the model still keeps the error for itself")
        var texts: [String] = []
        for failure in [front.state.failure].compactMap({ $0 }) + ["Formula 1", "Premier League", "NFL", "Cricket", "UFC"]
            .flatMap({ [PageWords.leagueFailed($0), PageWords.leagueNotAvailable($0)] }) {
            texts += [failure.title, failure.message, failure.stillWorks]
        }
        texts += [PageWords.stale(since: Date(timeIntervalSince1970: 1_800_000_000)), PageWords.stale(since: nil),
                  PageWords.followTitle, PageWords.followText(settings: true), PageWords.followText(settings: false),
                  PageWords.followAction, PageWords.openGuide, PageWords.nothingSoonTitle, PageWords.nothingSoonText("AFL"),
                  PageWords.noRoundsTitle("AFL"), PageWords.noRoundsText("AFL"), PageWords.emptyWeekTitle("UFC"),
                  PageWords.emptyWeekText, PageWords.noRaceTitle, PageWords.noRaceText, PageWords.noCricketTitle,
                  PageWords.noCricketText, PageWords.notSaved, PageWords.tryAgain, PageWords.tryingAgain]
        for text in texts {
            XCTAssertFalse(text.contains(systemText), "the error's own text: \(text)")
            XCTAssertNil(text.range(of: #"\b[1-9][0-9]{2}\b"#, options: .regularExpression), "a status code: \(text)")
            XCTAssertNil(text.range(of: #"(?i)http|error|domain|code|status|unavailable"#, options: .regularExpression),
                         "a technical word: \(text)")
            XCTAssertFalse(text.contains("!"), "no exclamation marks: \(text)")
            XCTAssertEqual(text.first.map { String($0) }, text.first.map { String($0).uppercased() }, "sentence case: \(text)")
        }
        XCTAssertEqual(PageWords.tryAgain, "Try again", "one name for the retry action")
    }
}

/// The stub server: a status and a body per path (anything else is a 404).
private final class StateRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    /// Paths whose request fails as URLSession's own "cancelled" (the page that asked went away).
    nonisolated(unsafe) static var cancelled: Set<String> = []
    /// Runs on the main thread while each request is in flight (before its answer): what the page shows meanwhile.
    nonisolated(unsafe) static var during: (() -> Void)?

    static func reset() { routes = [:]; asked = []; cancelled = []; during = nil }
    static func count(_ path: String) -> Int { asked.filter { $0 == path }.count }
    static func set(_ path: String, status: Int = 200, body: Data = Data(#"{"error":"down"}"#.utf8)) {
        routes[path] = (status, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.asked.append(request.url?.path ?? "")
        if let during = Self.during {
            if Thread.isMainThread { during() } else { DispatchQueue.main.sync(execute: during) }
        }
        if Self.cancelled.contains(request.url?.path ?? "") {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let route = Self.routes[request.url?.path ?? ""] ?? (404, Data(#"{"error":"not found"}"#.utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
