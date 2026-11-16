import XCTest
@testable import PigTV

// #57 (Apple half, D-66): Search asks the server's index. The answer decodes with or without each list and field, groups
// in D-66's order with only non-empty groups, shows four rows a group then "Show all"; typing is debounced and a newer
// query cancels the one before (an older answer is never shown); a 404 (an older server) falls back to the guide's
// search; recent searches are this device's last eight.
@MainActor
final class LibrarySearchTests: XCTestCase {
    private func decode(_ json: String) throws -> LibrarySearchResponse {
        try JSONDecoder().decode(LibrarySearchResponse.self, from: Data(json.utf8))
    }

    private let fullAnswer = #"""
    {"q":"swans",
     "channels":[{"id":"501","sourceId":1,"name":"Fox Footy","logo":"/api/logo/f","number":74,"stableId":"fox"},
                 {"id":"pos_9","sourceId":1,"name":"Fox Footy","stableId":"fox"}],
     "programmes":[{"channel":{"id":"7","sourceId":1,"name":"Seven"},"title":"AFL: Swans v Giants","subtitle":"Round 3",
                    "episode":"S2 E5","start":1800000000000,"end":1800007200000,"live":true,"new":false,"image":"/api/logo/p"},
                   {"channel":{"id":"7","sourceId":1,"name":"Seven"},"title":"Swans Weekly","start":1800010000000,"end":1800011800000}],
     "events":[{"id":42,"title":"Sydney Swans v GWS Giants","league":"AFL","start":1800000000000,"end":1800007200000,
                "channels":[{"id":"7","sourceId":1,"name":"Seven"}]}],
     "teams":[{"id":"afl:syd","name":"Sydney Swans","league":"AFL","logo":"/api/logo/syd","followed":true}],
     "recordings":[{"id":3,"title":"Swans v Blues","status":"completed","channel_name":"Seven"}]}
    """#

    // MARK: Decoding

    func testTheFullAnswerDecodes() throws {
        let answer = try decode(fullAnswer)
        XCTAssertEqual(answer.q, "swans")
        XCTAssertEqual(answer.channels.map(\.name), ["Fox Footy", "Fox Footy"])
        XCTAssertEqual(answer.channels.first?.number, 74)
        XCTAssertEqual(answer.channels.first?.programmes.count, 0, "a channel row without programmes decodes")
        let first = try XCTUnwrap(answer.programmes.first)
        XCTAssertEqual(first.channel.id, "1:7")
        XCTAssertEqual(first.programme.title, "AFL: Swans v Giants")
        XCTAssertEqual(first.programme.startTime, 1_800_000_000_000)
        XCTAssertEqual(first.programme.liveBroadcast, true)
        XCTAssertEqual(first.programme.isNew, false)
        XCTAssertEqual(first.programme.episode, "S2 E5")
        XCTAssertEqual(first.programme.subtitle, "Round 3")
        XCTAssertEqual(first.programme.image, "/api/logo/p")
        XCTAssertNil(answer.programmes[1].programme.episode, "the optional fields may be left out")
        XCTAssertEqual(answer.events.map(\.id), ["42"])
        XCTAssertEqual(answer.teams, [LibrarySearchTeam(id: "afl:syd", name: "Sydney Swans", league: "AFL",
                                                        logo: "/api/logo/syd", followed: true)])
        XCTAssertEqual(answer.recordings.map(\.id), [3])
    }

    func testMissingListsAreEmptyAndABadRowIsSkipped() throws {
        let answer = try decode(#"""
        {"programmes":[{"channel":{"id":"7","sourceId":1,"name":"Seven"},"title":"No end","start":1},
                       {"channel":{"id":"7","sourceId":1,"name":"Seven"},"title":"Backwards","start":5,"end":2},
                       {"channel":{"id":"7","sourceId":1,"name":"Seven"},"title":"Fine","start":1,"end":2}],
         "teams":[{"id":5,"name":"Giants"},{"league":"AFL"}],
         "recordings":"nope"}
        """#)
        XCTAssertEqual(answer.q, "")
        XCTAssertTrue(answer.channels.isEmpty)
        XCTAssertTrue(answer.events.isEmpty)
        XCTAssertTrue(answer.recordings.isEmpty, "an odd list is empty, not a failed answer")
        XCTAssertEqual(answer.programmes.map(\.programme.title), ["Fine"], "rows that do not decode are skipped")
        XCTAssertEqual(answer.teams.map(\.id), ["5"], "a numeric id is read as its digits")
        XCTAssertEqual(answer.teams.first?.followed, false)
        XCTAssertNil(answer.teams.first?.cachedLogo)
        XCTAssertTrue(try decode("{}").channels.isEmpty)
    }

    func testOnlySameServerTeamLogosAreUsed() {
        XCTAssertEqual(LibrarySearchTeam(id: "a", name: "A", league: "AFL", logo: "/api/logo/x").cachedLogo, "/api/logo/x")
        XCTAssertNil(LibrarySearchTeam(id: "a", name: "A", league: "AFL", logo: "https://elsewhere/x.png").cachedLogo)
        XCTAssertNil(LibrarySearchTeam(id: "a", name: "A", league: "AFL", logo: "/api/logo/x?token=1").cachedLogo)
    }

    // MARK: Groups

    func testGroupsAreInD66OrderAndOnlyWhenNotEmpty() throws {
        let results = LibrarySearchResults(try decode(fullAnswer), query: "swans")
        XCTAssertEqual(results.sections, [.teams, .games, .programmes, .channels, .recordings])
        XCTAssertEqual(results.channels.count, 1, "a cross-listed channel is listed once")
        XCTAssertEqual(results.source, .server)
        XCTAssertFalse(results.isEmpty)

        let some = LibrarySearchResults(try decode(#"{"q":"x","recordings":[{"id":1,"title":"X","status":"completed"}]}"#), query: "x")
        XCTAssertEqual(some.sections, [.recordings])
        XCTAssertTrue(LibrarySearchResults(try decode("{}"), query: "x").isEmpty)
        XCTAssertEqual(LibrarySearchSection.teams.title(count: 1), "Team")
        XCTAssertEqual(LibrarySearchSection.games.title(count: 3), "Games")
        XCTAssertEqual(LibrarySearchSection.programmes.title(count: 2, source: .guide), "Programmes · next 24 hours",
                       "the guide's search keeps its heading")
    }

    func testFourRowsThenShowAll() {
        XCTAssertEqual(LibrarySearchLayout.visible(3, expanded: false), 3)
        XCTAssertFalse(LibrarySearchLayout.offersShowAll(4, expanded: false), "four rows fit: no Show all")
        XCTAssertEqual(LibrarySearchLayout.visible(9, expanded: false), 4)
        XCTAssertTrue(LibrarySearchLayout.offersShowAll(5, expanded: false))
        XCTAssertEqual(LibrarySearchLayout.visible(9, expanded: true), 9, "Show all shows every row in place")
        XCTAssertFalse(LibrarySearchLayout.offersShowAll(9, expanded: true))
    }

    func testFollowIsOfferedInAFollowedLeagueOnly() {
        let follows = SportFollows(sports: [.init(sport: "Australian rules", leagues: ["AFL", "AFLW"]),
                                            .init(sport: "Cricket", leagues: ["BBL"])])
        XCTAssertEqual(LibrarySearchFollow.sport(forLeague: "afl", in: follows), "Australian rules")
        XCTAssertEqual(LibrarySearchFollow.sport(forLeague: "BBL", in: follows), "Cricket")
        XCTAssertNil(LibrarySearchFollow.sport(forLeague: "NRL", in: follows), "a league not followed: no Follow")
        XCTAssertNil(LibrarySearchFollow.sport(forLeague: "", in: follows))
        XCTAssertNil(LibrarySearchFollow.sport(forLeague: "AFL", in: nil))
    }

    // MARK: Running a search

    private final class Calls { var fetched: [String] = []; var fallbacks: [String] = [] }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func guideResults(_ text: String, failed: Bool) -> LibrarySearchResults {
        LibrarySearchResults(guide: GuideSearch.Results(), query: text, serverFailed: failed)
    }

    func testTypingIsDebouncedToOneRequest() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in
            calls.fetched.append(text)
            return LibrarySearchResponse(q: text, teams: [LibrarySearchTeam(id: text, name: text, league: "AFL")])
        }, fallback: { text, failed in self.guideResults(text, failed: failed) }, debounce: .milliseconds(80))
        runner.update("sw")
        runner.update("swa")
        runner.update("swans ")
        XCTAssertTrue(runner.busy)
        await waitFor { runner.searched != nil }
        XCTAssertEqual(calls.fetched, ["swans"], "one request, for the last (trimmed) query")
        XCTAssertEqual(runner.searched, "swans")
        XCTAssertEqual(runner.results?.teams.map(\.id), ["swans"])
        XCTAssertFalse(runner.busy)
    }

    func testAnOlderQuerysAnswerIsNeverShown() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in
            calls.fetched.append(text)
            if text == "sw" {
                // Slow, and deaf to cancellation: the runner must drop it itself.
                await withCheckedContinuation { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.resume() }
                }
            }
            return LibrarySearchResponse(q: text, teams: [LibrarySearchTeam(id: text, name: text, league: "AFL")])
        }, fallback: { text, failed in self.guideResults(text, failed: failed) }, debounce: .zero)
        runner.update("sw")
        await waitFor { calls.fetched == ["sw"] }
        runner.update("swans")
        await waitFor { runner.searched == "swans" }
        XCTAssertEqual(runner.results?.teams.map(\.id), ["swans"])
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(runner.searched, "swans", "the slow answer for “sw” arrived later and was dropped")
        XCTAssertEqual(runner.results?.teams.map(\.id), ["swans"])
    }

    /// Codex: A's rows stayed (and could be acted on) under B's text, and leaving for a result cancelled B for good.
    func testAnInterruptedSearchResumesAndAnEarlierAnswerIsNotShown() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in
            calls.fetched.append(text)
            if text == "giants" && calls.fetched.filter({ $0 == "giants" }).count == 1 {
                // B's first request is still out when the viewer opens a result.
                await withCheckedContinuation { done in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.resume() }
                }
            }
            return LibrarySearchResponse(q: text, teams: [LibrarySearchTeam(id: text, name: text, league: "AFL")])
        }, fallback: { text, failed in self.guideResults(text, failed: failed) }, debounce: .zero)
        runner.update("swans")
        await waitFor { runner.searched == "swans" }
        XCTAssertEqual(runner.results(for: "swans")?.teams.map(\.id), ["swans"])
        runner.update("giants")
        await waitFor { calls.fetched == ["swans", "giants"] }
        XCTAssertNil(runner.results(for: "giants"), "A's rows are not shown under B's text")
        XCTAssertNil(runner.results(for: "giants "), "nor under B with a trailing space")
        runner.cancel() // a result's page opened: the page left the screen
        XCTAssertFalse(runner.busy)
        runner.resume("giants") // back before B's first answer came
        await waitFor { runner.searched == "giants" }
        XCTAssertEqual(calls.fetched, ["swans", "giants", "giants"], "B was searched again")
        XCTAssertEqual(runner.results(for: "giants")?.teams.map(\.id), ["giants"])
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(runner.results(for: "giants")?.teams.map(\.id), ["giants"], "the interrupted answer is dropped")
        runner.resume("giants")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.fetched.count, 3, "a query with its own results is not searched again")
    }

    func testClearingTheQueryClearsTheResultsAndCancels() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in calls.fetched.append(text); return LibrarySearchResponse(q: text) },
                                         fallback: { text, failed in self.guideResults(text, failed: failed) },
                                         debounce: .milliseconds(80))
        runner.update("swans")
        runner.update("s")
        XCTAssertNil(runner.results)
        XCTAssertNil(runner.searched)
        XCTAssertFalse(runner.busy)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.fetched, [], "the pending search was cancelled; one letter is never sent")
    }

    func testA404FallsBackToTheGuideForTheRestOfThePage() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in
            calls.fetched.append(text)
            throw PigTVError.http(404)
        }, fallback: { text, failed in
            calls.fallbacks.append(text)
            return self.guideResults(text, failed: failed)
        }, debounce: .zero)
        XCTAssertFalse(runner.usesGuide)
        runner.update("news")
        await waitFor { runner.searched == "news" }
        XCTAssertEqual(runner.results?.source, .guide)
        XCTAssertEqual(runner.results?.serverFailed, false, "an older server is not a failure")
        XCTAssertTrue(runner.usesGuide)
        runner.update("sport")
        await waitFor { runner.searched == "sport" }
        XCTAssertEqual(calls.fetched, ["news"], "the server is not asked again after a 404")
        XCTAssertEqual(calls.fallbacks, ["news", "sport"])
    }

    func testAnotherFailureShowsTheGuidesResultsMarked() async {
        let calls = Calls()
        let runner = LibrarySearchRunner(fetch: { text in
            calls.fetched.append(text)
            throw PigTVError.http(500)
        }, fallback: { text, failed in self.guideResults(text, failed: failed) }, debounce: .zero)
        runner.update("news")
        await waitFor { runner.searched == "news" }
        XCTAssertEqual(runner.results?.source, .guide)
        XCTAssertEqual(runner.results?.serverFailed, true)
        XCTAssertFalse(runner.usesGuide, "the server is asked again next time")
        runner.update("sport")
        await waitFor { runner.searched == "sport" }
        XCTAssertEqual(calls.fetched, ["news", "sport"])
    }

    func testNoServerSearchUsesTheGuide() async {
        let runner = LibrarySearchRunner(fetch: nil, fallback: { text, failed in self.guideResults(text, failed: failed) },
                                         debounce: .zero)
        XCTAssertTrue(runner.usesGuide)
        runner.update("news")
        await waitFor { runner.searched == "news" }
        XCTAssertEqual(runner.results?.source, .guide)
    }

    func testOnlyA404IsAnOlderServer() {
        XCTAssertTrue(LibrarySearchRunner.isOlderServer(PigTVError.http(404)))
        XCTAssertFalse(LibrarySearchRunner.isOlderServer(PigTVError.http(400)))
        XCTAssertFalse(LibrarySearchRunner.isOlderServer(PigTVError.decoding))
        XCTAssertFalse(LibrarySearchRunner.isOlderServer(URLError(.notConnectedToInternet)))
    }

    // MARK: Recent searches

    func testRecentSearchesKeepTheLastEightNewestFirst() throws {
        let name = "LibrarySearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let recent = RecentSearches(defaults: defaults)
        XCTAssertEqual(recent.all, [])
        recent.add("s")
        XCTAssertEqual(recent.all, [], "one letter is not a search")
        for word in ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"] { recent.add(word) }
        XCTAssertEqual(recent.all, ["nine", "eight", "seven", "six", "five", "four", "three", "two"], "eight, newest first")
        XCTAssertEqual(recent.add("  FIVE "), ["FIVE", "nine", "eight", "seven", "six", "four", "three", "two"],
                       "a repeat moves to the front once (case aside), trimmed")
        XCTAssertEqual(recent.remove("nine"), ["FIVE", "eight", "seven", "six", "four", "three", "two"])
        XCTAssertEqual(RecentSearches(defaults: defaults).all.first, "FIVE", "kept on the device")
        recent.clear()
        XCTAssertEqual(recent.all, [])
    }

    // MARK: Opening Search from any tab (D-66)

    func testSearchOpensAsAPageAboveEveryTab() throws {
        let presenter = AppPresenter()
        presenter.present(.search(from: LibraryView.title(of: "sport")))
        guard case .search(let from)? = presenter.presented else { return XCTFail("Search is not open") }
        XCTAssertEqual(from, "Sport", "the page names the tab it came from")
        XCTAssertEqual(presenter.presented?.id, "search")
        XCTAssertEqual(presenter.presented?.isPlayer, false, "a page, not a player")
        XCTAssertEqual(LibraryView.title(of: "guide"), "TV Guide")
        XCTAssertEqual(LibraryView.title(of: "recordings"), "Recordings")
        XCTAssertEqual(LibraryView.title(of: "settings"), "Settings")
    }

    func testPlayingARecordingFromSearchClosesTheSearchFirst() throws {
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":9,"title":"Swans","status":"completed"}"#.utf8))
        let presenter = AppPresenter()
        presenter.present(.search(from: "Sport"))
        presenter.present(.playRecording(recording))
        XCTAssertNil(presenter.presented, "the search page closes first")
        presenter.didDismiss()
        XCTAssertEqual(presenter.presented?.id, "play:9")
        XCTAssertEqual(presenter.presented?.isPlayer, true, "the recording player is full screen")
    }

    func testShowGuideLeavesTheTimeForTheGuide() {
        let presenter = AppPresenter()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        presenter.present(.search(from: "Sport"))
        presenter.dismiss { presenter.guideJump = time }
        XCTAssertNil(presenter.guideJump, "not until the page has gone")
        presenter.didDismiss()
        XCTAssertEqual(presenter.guideJump, time)
    }

    // MARK: The endpoint

    func testTheRequestAsksForTwentyRows() throws {
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"))
        let url = try client.requestURL("library/search", query: [URLQueryItem(name: "q", value: "swans v giants"),
                                                                  URLQueryItem(name: "limit", value: String(LibrarySearchRunner.serverLimit))])
        XCTAssertEqual(url.path, "/api/library/search")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.value),
                       ["swans v giants", "20"])
    }

    // #57: the server's search says what it finds before typing; only the 404 fallback keeps the guide's words.
    func testTheHintBeforeTypingNamesWhatTheSearchFinds() {
        XCTAssertEqual(LibrarySearchSection.hint(guideOnly: false), "Search programmes, channels, teams, games and recordings")
        XCTAssertTrue(LibrarySearchSection.hint(guideOnly: true).contains("next 24 hours"))
    }

    // #57: a followed team says so: in its line on touch (where Following is an icon), beside the row on the TV.
    func testAFollowedTeamSaysFollowing() {
        XCTAssertEqual(SearchRowWords.teamDetail(league: "AFL", followed: true, touch: true), "AFL · Following")
        XCTAssertEqual(SearchRowWords.teamDetail(league: "AFL", followed: true, touch: false), "AFL")
        XCTAssertEqual(SearchRowWords.teamDetail(league: "AFL", followed: false, touch: true), "AFL")
    }

    // #57: every Jump to time chip fits whole ("12 pm" was "12…" six a row on the TV).
    func testJumpToHasFourHoursARow() {
        XCTAssertEqual(GuideJump.hourColumns, 4)
    }
}
