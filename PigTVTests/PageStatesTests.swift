import XCTest
@testable import PigTV

// #280 (brand 1.8 §14), the pages after Sport: the TV Guide (and Search, which looks through it), Recordings, Scheduled,
// Settings › Sport and Sign in. Each page model says which of its four states the page is in (`PageState`) and the page
// draws it with the shared parts; before this the views worked it out inline: a guide or recordings list that had not
// answered yet showed its empty words ("No matching channels", Scheduled's "Nothing scheduled"), a failed load showed the
// system's text in a banner, and Sign in's errors were an alert. The models are loaded against a stub server
// (`PageRoutes`): an answer, an empty one, or a 500.
@MainActor
final class PageStatesTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        PageRoutes.reset()
        BrowseModel.guidePageRetryDelaysOverride = [] // a failed guide page fails at once (no backoff to wait through)
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PageStatesTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        PageRoutes.reset()
        BrowseModel.guidePageRetryDelaysOverride = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PageRoutes.self]
        return APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                         session: URLSession(configuration: configuration))
    }

    private func browse() throws -> BrowseModel {
        BrowseModel(client: try client(), guideCacheDirectory: cacheDirectory)
    }

    private static let guide = "/api/library/guide"
    private static let recordings = "/api/recordings"
    private static let scheduled = "/api/recordings/scheduled"
    private static let rules = "/api/recordings/rules"
    private static let follows = "/api/sports/follows"
    private static let oneChannel = Data(#"{"total":1,"channels":[{"id":"a","sourceId":1,"name":"A","programmes":[]}]}"#.utf8)
    private static let noChannels = Data(#"{"total":0,"channels":[]}"#.utf8)
    private static let oneRecording = Data(#"[{"id":7,"title":"The Headlines","channel_name":"News","status":"completed"}]"#.utf8)
    private static let oneSchedule = Data(#"[{"id":9,"title":"Later","channel_name":"News","program_start":4102444800000,"program_end":4102448400000,"status":"scheduled"}]"#.utf8)
    private static let none = Data("[]".utf8)

    // MARK: TV Guide

    func testTheGuideLoadsToContent() async throws {
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        let m = try browse()
        XCTAssertEqual(m.guideState, .loading, "before the first answer: the grid's shape, never an empty guide")
        await m.loadGuide()
        XCTAssertEqual(m.guideState, .content)
    }

    func testTheGuideLoadsToEmpty() async throws {
        PageRoutes.set(Self.guide, body: Self.noChannels)
        let m = try browse()
        await m.loadGuide()
        XCTAssertEqual(m.guideState, .empty, "an answer with no channels")
        XCTAssertEqual(PageWords.guideEmpty(filter: "all", channels: 0).title, PageWords.noChannelsTitle)
    }

    func testTheGuidesFirstLoadThatFailsEndsInTheErrorNotASpinner() async throws {
        PageRoutes.set(Self.guide, status: 500)
        let m = try browse()
        await m.loadGuide()
        XCTAssertEqual(m.guideState, .failed(PageWords.guideFailed))
    }

    func testAGuideRefreshThatFailsKeepsTheChannelsAndSaysTheyAreStale() async throws {
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        let m = try browse()
        await m.loadGuide()
        let loadedAt = try XCTUnwrap(m.guideLoadedAt)
        PageRoutes.set(Self.guide, status: 500)
        await m.loadGuide(reset: true, keepVisible: true)
        XCTAssertEqual(m.guide.count, 1, "the channels on screen stay")
        XCTAssertEqual(m.guideState, .stale(since: loadedAt))
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        await m.retryGuide()
        XCTAssertEqual(m.guideState, .content, "current again once it answers")
    }

    func testAChipThatLeavesNoChannelsIsTheGuidesEmptyState() {
        XCTAssertEqual(PageState.guideRows(.content, rowsEmpty: true, paging: false), .empty)
        XCTAssertEqual(PageState.guideRows(.content, rowsEmpty: true, paging: true), .content, "more channels are coming")
        XCTAssertEqual(PageState.guideRows(.loading, rowsEmpty: true, paging: false), .loading, "not before the answer")
        XCTAssertEqual(PageState.guideRows(.content, rowsEmpty: false, paging: false), .content)
        XCTAssertEqual(PageWords.guideEmpty(filter: "favourites", channels: 3).title, PageWords.noFavouritesTitle)
        XCTAssertTrue(PageWords.guideEmpty(filter: "favourites", channels: 3).showsAll, "its one action: Show all channels")
        XCTAssertEqual(PageWords.guideEmpty(filter: "cat:News", channels: 3).title, PageWords.noMatchingTitle)
    }

    // MARK: Search and Jump to

    func testSearchHasALoadingAnErrorAndAnEmptyState() {
        XCTAssertEqual(PageState.search(query: "c", searched: nil, found: false, guide: .loading), .content, "the prompt")
        XCTAssertEqual(PageState.search(query: "curling", searched: nil, found: false, guide: .loading), .loading,
                       "the guide is still loading")
        XCTAssertEqual(PageState.search(query: "curling", searched: nil, found: false, guide: .content), .loading,
                       "before the first search has run")
        XCTAssertEqual(PageState.search(query: "curling", searched: "curling", found: false, guide: .failed(PageWords.guideFailed)),
                       .failed(PageWords.guideFailed), "the guide it looks through did not load")
        XCTAssertEqual(PageState.search(query: "curling", searched: "curling", found: false, guide: .content), .empty)
        XCTAssertEqual(PageState.search(query: "curling", searched: "curl", found: true, guide: .stale(since: nil)), .content,
                       "while the next search waits, the last results stay")
        XCTAssertEqual(PageWords.searchNothingTitle("curling"), "Nothing matches “curling”")
        XCTAssertEqual(PageWords.clearSearch, "Clear search")
    }

    // MARK: Recordings and Scheduled

    func testRecordingsLoadToContent() async throws {
        PageRoutes.set(Self.recordings, body: Self.oneRecording)
        PageRoutes.set(Self.scheduled, body: Self.none)
        let m = try browse()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .loading)
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .content)
    }

    func testRecordingsLoadToEmpty() async throws {
        PageRoutes.set(Self.recordings, body: Self.none)
        PageRoutes.set(Self.scheduled, body: Self.none)
        let m = try browse()
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .empty)
    }

    func testRecordingsFirstLoadThatFailsEndsInTheError() async throws {
        PageRoutes.set(Self.recordings, status: 500)
        let m = try browse()
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .failed(PageWords.recordingsFailed))
    }

    func testARecordingsRefreshThatFailsKeepsTheListAndSaysItIsStale() async throws {
        PageRoutes.set(Self.recordings, body: Self.oneRecording)
        PageRoutes.set(Self.scheduled, body: Self.none)
        let m = try browse()
        await m.loadRecordings()
        let since = try XCTUnwrap(m.recordingStore.updatedAt)
        PageRoutes.set(Self.recordings, status: 503)
        await m.loadRecordings()
        XCTAssertEqual(m.recordings.count, 1, "the list on screen stays")
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .stale(since: since))
    }

    /// Before: Scheduled had no loading state, so "Nothing scheduled" (and "No rules yet", "Nothing needs attention")
    /// showed until the answer came.
    func testScheduledNeverShowsItsEmptyLinesWhileLoading() async throws {
        PageRoutes.set(Self.recordings, body: Self.none)
        PageRoutes.set(Self.scheduled, body: Self.none)
        PageRoutes.set(Self.rules, body: Self.none)
        let m = try browse()
        XCTAssertEqual(m.recordingsState(isEmpty: true, failure: PageWords.scheduledFailed), .loading,
                       "no answer yet: its shape, not Nothing scheduled")
        XCTAssertFalse(m.recordingStore.rulesLoaded, "nor No rules yet")
        await m.loadRecordings()
        await m.reloadRules()
        XCTAssertEqual(m.recordingsState(isEmpty: true, failure: PageWords.scheduledFailed), .empty)
        XCTAssertTrue(m.recordingStore.rulesLoaded)
        PageRoutes.set(Self.scheduled, body: Self.oneSchedule)
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: ScheduledRows.upcoming(m.schedules).isEmpty, failure: PageWords.scheduledFailed),
                       .content)
    }

    func testRulesThatFailToLoadSayItInPlainWords() async throws {
        PageRoutes.set(Self.rules, status: 500)
        let m = try browse()
        await m.reloadRules()
        XCTAssertEqual(m.recordingStore.rulesError, PageWords.rulesFailed)
    }

    // MARK: Settings › Sport

    private func followsModel(_ defaults: UserDefaults) throws -> SportFollowSettingsModel {
        SportFollowSettingsModel(client: try client(), defaults: defaults)
    }

    func testSettingsSportHasItsFourStates() async throws {
        let store = UserDefaults(suiteName: "PageStatesTests.\(UUID().uuidString)")!
        PageRoutes.set(Self.follows, body: Data(#"{"spoilerFree":false,"sports":[{"sport":"Football","leagues":["Premier League"],"teams":[]}]}"#.utf8))
        let m = try followsModel(store)
        XCTAssertEqual(m.state, .loading)
        await m.load()
        XCTAssertEqual(m.state, .content)

        PageRoutes.set(Self.follows, status: 503)
        let offline = try followsModel(store)
        await offline.load()
        XCTAssertEqual(offline.state, .stale(since: nil), "this device's last copy, with the notice")

        let fresh = try followsModel(UserDefaults(suiteName: "PageStatesTests.\(UUID().uuidString)")!)
        await fresh.load()
        XCTAssertEqual(fresh.state, .failed(PageWords.sportSettingsFailed), "no answer and no copy")

        PageRoutes.set(Self.follows, body: Data(#"{"spoilerFree":false,"sports":[]}"#.utf8))
        let empty = try followsModel(UserDefaults(suiteName: "PageStatesTests.\(UUID().uuidString)")!)
        await empty.load()
        XCTAssertEqual(empty.state, .empty, "nothing followed: E1 with Add a sport")
    }

    // MARK: One retry clock

    /// A failed guide or recordings page is retried by the app's minute pass (AppFreshness), its healthy cadence: the
    /// error page counts down to it and runs no clock of its own, and nothing asks in between.
    func testAFailedGuideOrRecordingsPageAsksOnlyAtTheHealthyCadence() async throws {
        PageRoutes.set(Self.guide, status: 500)
        PageRoutes.set(Self.recordings, status: 500)
        let m = try browse()
        await AppFreshness.refresh(m, export: { _ in })
        XCTAssertEqual(m.guideState, .failed(PageWords.guideFailed))
        XCTAssertEqual(m.recordingsState(isEmpty: true), .failed(PageWords.recordingsFailed))
        XCTAssertEqual(m.guideStore.schedule?.interval, Self.seconds(AppFreshness.interval), "the guide's next pass")
        XCTAssertEqual(m.recordingStore.schedule?.interval, Self.seconds(AppFreshness.interval), "the recordings' next pass")
        XCTAssertFalse(PigErrorState.ownsRetryClock(schedule: m.guideStore.schedule), "the error view adds no clock")
        XCTAssertFalse(PigErrorState.ownsRetryClock(schedule: m.recordingStore.schedule))
        let asked = (PageRoutes.count(Self.guide), PageRoutes.count(Self.recordings))
        XCTAssertEqual(asked.0, 1, "one guide request per pass, failed or not (no backoff here)")
        XCTAssertEqual(asked.1, 1, "one recordings request per pass")
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(PageRoutes.count(Self.guide), asked.0, "nothing asks again before the next pass")
        XCTAssertEqual(PageRoutes.count(Self.recordings), asked.1)

        // The Recordings page's own loop (15 s while something records, else 60 s) is that page's healthy cadence.
        m.notePolls(recordingsAfter: .seconds(15), guideAfter: nil)
        XCTAssertEqual(m.recordingStore.schedule?.interval, 15)

        // A healthy page is not redrawn by the clock: nothing is published while it has not failed.
        let healthy = try browse()
        healthy.notePolls(recordingsAfter: .seconds(60), guideAfter: .seconds(60))
        XCTAssertNil(healthy.recordingStore.schedule)
        XCTAssertNil(healthy.guideStore.schedule)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: A retry changes nothing on screen until it has its answer (review of 205, H2)

    /// What `state` reads before each poll, while each of its requests is in flight, and after it.
    private func states(_ state: @escaping @MainActor () -> PageState, polls: Int,
                        _ poll: @MainActor () async -> Void) async -> [PageState] {
        var seen: [PageState] = []
        PageRoutes.during = { MainActor.assumeIsolated { seen.append(state()) } }
        defer { PageRoutes.during = nil }
        for _ in 0..<polls {
            seen.append(state())
            await poll()
            seen.append(state())
        }
        return seen
    }

    /// Before: each pass cleared the guide's error before asking, so a failed TV Guide showed its loading placeholders
    /// for the length of every attempt (about 20 s a minute with the page retries), and "Try again" did the same.
    func testAFailedGuideStaysFailedThroughEachPollAndTryAgain() async throws {
        PageRoutes.set(Self.guide, status: 500)
        let m = try browse()
        await m.loadInitialGuide()
        let failed = PageState.failed(PageWords.guideFailed)
        XCTAssertEqual(m.guideState, failed)
        let polls = await states({ m.guideState }, polls: 2) { await m.loadInitialGuide() }
        XCTAssertGreaterThanOrEqual(polls.count, 6, "each poll was watched mid-request")
        XCTAssertEqual(polls, Array(repeating: failed, count: polls.count), "failed → failed, never failed → loading → failed")
        let tried = await states({ m.guideState }, polls: 1) { await m.retryGuide() }
        XCTAssertEqual(tried, Array(repeating: failed, count: tried.count), "Try again: the error stays (its ring shows the attempt)")
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        await m.retryGuide()
        XCTAssertEqual(m.guideState, .content, "a successful attempt clears it")
    }

    /// Before: with channels on screen a refresh cleared the error first, so the stale notice went and came back with
    /// every pass, moving the page; and its "Try again" cleared the notice without asking anything.
    func testAStaleGuideStaysStaleThroughEachPollAndTryAgain() async throws {
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        let m = try browse()
        await m.loadGuide()
        let stale = PageState.stale(since: try XCTUnwrap(m.guideLoadedAt))
        PageRoutes.set(Self.guide, status: 500)
        await m.loadGuide(reset: true, keepVisible: true) // the refresh that fails
        XCTAssertEqual(m.guideState, stale)
        let polls = await states({ m.guideState }, polls: 2) { await m.loadGuide(reset: true, keepVisible: true) }
        XCTAssertEqual(polls, Array(repeating: stale, count: polls.count), "stale → stale, the notice never blinks off")
        let asked = PageRoutes.count(Self.guide)
        let tried = await states({ m.guideState }, polls: 1) { await m.retryGuide() }
        XCTAssertEqual(tried, Array(repeating: stale, count: tried.count))
        XCTAssertEqual(PageRoutes.count(Self.guide), asked + 1, "Try again asks")
        PageRoutes.set(Self.guide, body: Self.oneChannel)
        await m.retryGuide()
        XCTAssertEqual(m.guideState, .content)
    }

    /// Before: each poll (and "Try again") cleared the recordings' error first: the error page turned into the loading
    /// placeholders for the request, and the stale notice over a list blinked off and on.
    func testFailedAndStaleRecordingsStayAsTheyAreThroughEachPoll() async throws {
        PageRoutes.set(Self.recordings, status: 500)
        let m = try browse()
        await m.loadRecordings(quietly: true)
        for failure in [PageWords.recordingsFailed, PageWords.scheduledFailed] {
            let polls = await states({ m.recordingsState(isEmpty: true, failure: failure) }, polls: 2) {
                await m.loadRecordings(quietly: true)
            }
            XCTAssertEqual(polls, Array(repeating: .failed(failure), count: polls.count), "failed → failed")
        }
        let tried = await states({ m.recordingsState(isEmpty: true) }, polls: 1) { await m.loadRecordings() }
        XCTAssertEqual(tried, Array(repeating: .failed(PageWords.recordingsFailed), count: tried.count), "Try again")

        PageRoutes.set(Self.recordings, body: Self.oneRecording)
        PageRoutes.set(Self.scheduled, body: Self.none)
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .content, "a successful attempt clears it")
        let stale = PageState.stale(since: try XCTUnwrap(m.recordingStore.updatedAt))
        PageRoutes.set(Self.recordings, status: 503)
        await m.loadRecordings(quietly: true) // the refresh that fails
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), stale)
        let polls = await states({ m.recordingsState(isEmpty: m.recordings.isEmpty) }, polls: 2) { await m.loadRecordings(quietly: true) }
        XCTAssertEqual(polls, Array(repeating: stale, count: polls.count), "stale → stale, the notice never blinks off")
        PageRoutes.set(Self.recordings, body: Self.oneRecording)
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: m.recordings.isEmpty), .content)
    }

    /// A request cancelled because what asked went away (URLSession's own "cancelled") neither fails the list nor clears
    /// its failure.
    func testACancelledRecordingsRequestChangesNothing() async throws {
        PageRoutes.set(Self.recordings, status: 500)
        let m = try browse()
        await m.loadRecordings()
        PageRoutes.cancelled = [Self.recordings]
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: true), .failed(PageWords.recordingsFailed))
        let fresh = try browse()
        await fresh.loadRecordings()
        XCTAssertEqual(fresh.recordingsState(isEmpty: true), .loading, "still loading, not failed")
    }

    // MARK: An empty answer that may be out of date (Codex round 1, medium)

    /// Before: `PageState.of` said `.empty` before it looked at whether the last refresh failed, so "No recordings yet",
    /// "Nothing scheduled" and "No channels yet" looked current through an outage (a recording scheduled on another
    /// device stayed hidden), with no notice and no Try again.
    func testAnEmptyAnswerWhoseRefreshFailsKeepsItsEmptyLayoutWithTheStaleNotice() async throws {
        PageRoutes.set(Self.recordings, body: Self.none)
        PageRoutes.set(Self.scheduled, body: Self.none)
        let m = try browse()
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: true), .empty)
        let since = m.recordingStore.updatedAt
        PageRoutes.set(Self.recordings, status: 503)
        await m.loadRecordings()
        for failure in [PageWords.recordingsFailed, PageWords.scheduledFailed] {
            let state = m.recordingsState(isEmpty: true, failure: failure)
            XCTAssertEqual(state, .emptyStale(since: since), "\(failure.title)")
            XCTAssertTrue(state.showsEmpty, "the empty layout stays")
            XCTAssertTrue(state.isStale, "with the notice and its Try again above it")
            XCTAssertEqual(state.staleSince, since)
        }
        PageRoutes.set(Self.recordings, body: Self.none)
        await m.loadRecordings()
        XCTAssertEqual(m.recordingsState(isEmpty: true), .empty, "a successful refresh clears the notice")

        PageRoutes.set(Self.guide, body: Self.noChannels)
        await m.loadGuide()
        XCTAssertEqual(m.guideState, .empty)
        let loadedAt = try XCTUnwrap(m.guideLoadedAt)
        PageRoutes.set(Self.guide, status: 500)
        await m.loadInitialGuide()
        XCTAssertEqual(m.guideState, .emptyStale(since: loadedAt), "No channels yet stays, marked out of date")
        XCTAssertEqual(PageState.guideRows(m.guideState, rowsEmpty: true, paging: false), .emptyStale(since: loadedAt))
        PageRoutes.set(Self.guide, body: Self.noChannels)
        await m.retryGuide()
        XCTAssertEqual(m.guideState, .empty, "a successful refresh clears the notice")

        // A chip that leaves no channels on a stale guide keeps the notice too.
        XCTAssertEqual(PageState.guideRows(.stale(since: loadedAt), rowsEmpty: true, paging: false), .emptyStale(since: loadedAt))
    }

    // MARK: Sign in

    /// Before: every sign-in error was an alert titled "PigTV" with OK, carrying the system's text (or "The server
    /// returned HTTP 401"); now it is said on the form in plain words, and the form keeps what was typed.
    func testASignInThatFailsSaysSoOnTheFormInPlainWords() async throws {
        let server = try LocalHTTPServer { request in
            switch request.path {
            case "/api/info": .json(#"{"name":"PigTV","version":"3.9.0","apiVersion":1,"features":{"library":true,"playbackResolve":true}}"#)
            case "/api/auth/login": .json(#"{"error":"Invalid username or password"}"#, status: 401)
            default: .json("[]")
            }
        }
        defer { server.stop() }
        let model = AppModel()
        model.serverText = server.baseURL
        model.username = "mark"
        model.password = "wrong"
        await model.login()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(model.error, "no alert")
        let failure = try XCTUnwrap(model.signInError)
        XCTAssertEqual(failure.title, "That username or password wasn’t accepted")
        XCTAssertEqual(model.username, "mark", "the form stays filled in")
        XCTAssertEqual(model.password, "wrong")
        assertPlain(failure)
    }

    func testEverySignInFailureIsPlainWordsWithNoCode() {
        let errors: [(Error, SignInFailure.Step)] = [
            (URLError(.timedOut), .server), (URLError(.cannotConnectToHost), .server), (URLError(.cannotFindHost), .server),
            (URLError(.notConnectedToInternet), .pairing), (URLError(.secureConnectionFailed), .server),
            (URLError(.badServerResponse), .password),
            (PigTVError.invalidServerURL, .server), (PigTVError.unauthorised, .password), (PigTVError.unauthorised, .saved),
            (PigTVError.forbidden, .password), (PigTVError.http(503), .server), (PigTVError.http(401), .password),
            (PigTVError.decoding, .server), (PigTVError.rateLimited(retryAfterSec: 90), .password),
            (NSError(domain: "NSOSStatusErrorDomain", code: -25300), .password)
        ]
        for (error, step) in errors {
            let failure = SignInFailure.of(error, step: step)
            XCTAssertNotNil(failure, "\(error)")
            if let failure {
                assertPlain(failure)
                // #280 (206): a PigTVError's own description is the app's plain words now, so only the system's errors count.
                if !(error is PigTVError) {
                    XCTAssertFalse("\(failure.title) \(failure.check)".contains(error.localizedDescription),
                                   "never the system's text: \(error)")
                }
            }
        }
        XCTAssertNil(SignInFailure.of(CancellationError(), step: .server), "a cancelled request is not a failure")
        XCTAssertEqual(SignInFailure.of(PigTVError.rateLimited(retryAfterSec: 90), step: .password)?.check,
                       "Wait 2 minutes, then try again.")
    }

    private func assertPlain(_ failure: SignInFailure, file: StaticString = #filePath, line: UInt = #line) {
        for text in [failure.title, failure.check] {
            XCTAssertNil(text.range(of: #"\b[1-9][0-9]{2}\b"#, options: .regularExpression), "a status code: \(text)", file: file, line: line)
            XCTAssertNil(text.range(of: #"-?[0-9]{5}"#, options: .regularExpression), "an OSStatus: \(text)", file: file, line: line)
            XCTAssertNil(text.range(of: #"(?i)\bhttp \d|error|domain|code|status|OSStatus"#, options: .regularExpression),
                         "a technical word: \(text)", file: file, line: line)
            XCTAssertFalse(text.contains("!"), "no exclamation marks: \(text)", file: file, line: line)
        }
    }

    // MARK: Actions that did not work

    /// Before: the detail pages' line, the record page, Scheduled and the iPhone's On now menu alert showed "Could not add
    /// the rule. <the system's text>" (or "The server returned HTTP 500"); now what could not be done, in plain words.
    func testAnActionThatFailsSaysWhatCouldNotBeDoneInPlainWords() async throws {
        PageRoutes.set(Self.rules, status: 500)
        let m = try browse()
        let ok = await m.addRule(RuleBody(kind: "series", match: "News", sourceId: 1, channelId: "a", channelName: "A", newOnly: true))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.actionError, PageWords.ruleAddFailed)
        for error: Error in [URLError(.timedOut), URLError(.cannotConnectToHost), PigTVError.http(500), PigTVError.decoding,
                             NSError(domain: "NSOSStatusErrorDomain", code: -25300)] {
            let text = try XCTUnwrap(BrowseModel.actionText(PageWords.actionFailed, error))
            XCTAssertEqual(text, PageWords.actionFailed, "never the system's text: \(error)")
        }
        XCTAssertEqual(BrowseModel.actionText(PageWords.changeFailed, PigTVError.serverMessage("Too late to change the padding.", status: 409)),
                       "Too late to change the padding.", "a sentence the server wrote to be shown is kept")
        XCTAssertNil(BrowseModel.actionText(PageWords.actionFailed, CancellationError()), "a cancelled request is not a failure")
        // Review of 206 (low 8): an account the server refuses is not told to try again.
        XCTAssertEqual(BrowseModel.actionText(PageWords.deleteFailed, PigTVError.forbidden), PigTVError.forbidden.errorDescription)
    }

    // MARK: The words

    func testTheNewStateWordsArePlainSentences() {
        var texts: [String] = []
        for failure in [PageWords.guideFailed, PageWords.recordingsFailed, PageWords.scheduledFailed, PageWords.sportSettingsFailed] {
            texts += [failure.title, failure.message, failure.stillWorks]
        }
        texts += [PageWords.noChannelsTitle, PageWords.noChannelsText, PageWords.noFavouritesTitle, PageWords.noFavouritesText,
                  PageWords.noMatchingTitle, PageWords.noMatchingText, PageWords.showAllChannels,
                  PageWords.searchNothingTitle("curling"), PageWords.searchNothingText, PageWords.clearSearch,
                  PageWords.noRecordingsTitle, PageWords.noRecordingsText, PageWords.nothingScheduledTitle,
                  PageWords.nothingScheduledText, PageWords.rulesFailed, PageWords.noSportsTitle, PageWords.noSportsText,
                  PageWords.addSport, PageWords.openGuide] + PageWords.actionTexts
        for text in texts {
            XCTAssertNil(text.range(of: #"\b[1-9][0-9]{2}\b"#, options: .regularExpression), "a status code: \(text)")
            XCTAssertNil(text.range(of: #"(?i)http|error|domain|code|status|unavailable|retry"#, options: .regularExpression),
                         "a technical word: \(text)")
            XCTAssertFalse(text.contains("!"), "no exclamation marks: \(text)")
            XCTAssertEqual(text.first.map { String($0) }, text.first.map { String($0).uppercased() }, "sentence case: \(text)")
        }
    }
}

/// The stub server: a status and a body per path (anything else is a 404), counting what is asked.
private final class PageRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    /// Paths whose request fails as URLSession's own "cancelled" (the task that asked went away).
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
