import XCTest
@testable import PigTV

// #347 (Apple part): a sport page's own items (C-P F1 sessions, C-Q and C-T games, C-S matches) carry `card`, the front
// page's card id for the same game, whether or not the front page still shows it. Recording from such an item sends it
// as `gameId`; a finished item's recording is found by it; a fixture with a `card` is its front card exactly or none;
// while an earlier recording of the same game (or this channel's overlapping airing) is being cancelled, Record waits
// (Mark, 19 Nov 2026). Before this change no page item read `card` (these tests fail to compile on 319: no `card`
// fields, SportCardID, CricketPageText.playsRecording or cancellingEarlier).
@MainActor
final class SportPageCardTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testEveryPageItemReadsItsCardAdditively() throws {
        func f1(_ extra: String) -> String { #"{"id":"race","name":"Race","start":1,"end":2,"status":"done"\#(extra)}"# }
        XCTAssertEqual(try decode(F1Session.self, f1(#","card":"espn:racing/f1:600052""#)).card, "espn:racing/f1:600052")
        XCTAssertNil(try decode(F1Session.self, f1("")).card, "an older server")
        XCTAssertNil(try decode(F1Session.self, f1(#","card":null"#)).card)
        XCTAssertNil(try decode(F1Session.self, f1(#","card":42"#)).card, "another type: absent, the item still decodes")
        XCTAssertNil(try decode(F1Session.self, f1(#","card":"  ""#)).card)
        let league = #"{"id":"5","start":1,"status":"done","home":{"abbr":"COLL"},"away":{"abbr":"RICH"},"card":"espn:australian-football/afl:5"}"#
        XCTAssertEqual(try decode(LeagueGame.self, league).card, "espn:australian-football/afl:5")
        let nfl = #"{"id":"401","start":1,"status":"done","home":{"abbr":"GB"},"away":{"abbr":"CHI"},"card":"espn:football/nfl:401"}"#
        XCTAssertEqual(try decode(NFLGame.self, nfl).card, "espn:football/nfl:401")
        let lead = #"{"id":"1","status":"done","teams":[],"card":"espn:cricket/123:1"}"#
        XCTAssertEqual(try decode(CricketLead.self, lead).card, "espn:cricket/123:1")
        XCTAssertEqual(try decode(CricketSeries.Match.self, #"{"id":"2","status":"done","card":"espn:cricket/123:2"}"#).card,
                       "espn:cricket/123:2")
        let other = #"{"id":"3","status":"done","teams":[],"scores":[],"channels":[],"card":"espn:cricket/9:3"}"#
        XCTAssertEqual(try decode(CricketOther.self, other).card, "espn:cricket/9:3")
        XCTAssertEqual(try decode(ScheduledRecording.self,
            #"{"id":7,"title":"T","program_start":1,"program_end":2,"status":"scheduled","gameId":"espn:cricket/123:1"}"#).game,
                       "espn:cricket/123:1")
    }

    func testAFixtureWithACardIsItsFrontCardOrNone() throws {
        let league = FixtureText.league(try SportPagesFixture.part(["leagues", "AFL"]), league: "AFL", following: [], spoilerFree: false)
        let front = try SportPagesFixture.front()
        var live = try XCTUnwrap(league.rounds[1].games.first { $0.status == "live" })
        XCTAssertEqual(FixtureText.card(for: live, league: "AFL", in: front)?.id, "espn:australian-football/afl:5",
                       "no card (an older server): matched by its teams and start")
        live.card = "espn:australian-football/afl:5"
        XCTAssertEqual(FixtureText.card(for: live, league: "AFL", in: front)?.id, "espn:australian-football/afl:5", "by its id")
        live.card = "espn:australian-football/afl:999"
        XCTAssertNil(FixtureText.card(for: live, league: "AFL", in: front),
                     "a card the front page does not have: none, never another game of the same teams and time")
    }

    /// Codex review of 320 (high): the fixture says the game is over while the front page's cached card still says live:
    /// the press plays the recording (by its card) from the beginning, never the card's channel (the result on air).
    func testAFinishedFixtureWithAStaleLiveCardPlaysItsRecording() throws {
        let front = try SportPagesFixture.front()
        let stale = try XCTUnwrap(front.game("espn:australian-football/afl:5"))
        XCTAssertFalse(stale.terminal, "the cached card still says it is on")
        XCTAssertEqual(SportCardActions.route(card: stale, event: nil, cardID: "espn:australian-football/afl:5", finished: true),
                       .recording("espn:australian-football/afl:5"))
        XCTAssertEqual(SportCardActions.route(card: stale, event: nil, cardID: nil, finished: true), .recording(stale.id),
                       "an older server's item (no card): its front card's id")
        XCTAssertEqual(SportCardActions.route(card: stale, event: nil, cardID: "espn:australian-football/afl:5", finished: false),
                       .card(stale), "not over: the card's rule, as before")
    }

    /// Codex review of 320 (medium): Watch another channel and a cricket lead's Other channels open the channel picker
    /// with the game the recording is for, so Record on any channel there sends its `gameId`.
    func testTheChannelPickerCarriesTheGameToRecordOn() {
        let presenter = SportPresenter(app: AppModel())
        let event = SportEvent(id: "cricket:1", title: "Australia v India", league: "Cricket", startTime: 1, endTime: 2, channels: [])
        presenter.open(event, .channels, gameID: "espn:cricket/123:1")
        XCTAssertEqual(presenter.presented?.gameID, "espn:cricket/123:1")
        presenter.open(event, .details)
        XCTAssertNil(presenter.presented?.gameID, "none given: none, as before")
    }

    func testAnF1SessionIsItsOwnCardFirst() {
        var session = F1Session(id: "race", name: "Race", startTime: 1, endTime: 2, status: .done)
        XCTAssertNil(SportMotorText.gameId(session, in: nil))
        session.card = "espn:racing/f1:600052"
        XCTAssertEqual(SportMotorText.gameId(session, in: nil), "espn:racing/f1:600052", "found with no front page at all")
    }

    func testRecordingAPageItemSendsItsCardAsTheGame() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let now = Date()
        let start = (now.timeIntervalSince1970 + 3600) * 1000, end = start + 7_200_000
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Cricket", startTime: start, endTime: end)
        let event = SportEvent(id: "cricket:1", title: "Australia v India", league: "Cricket", startTime: start, endTime: end,
                               channels: [channel])
        XCTAssertNil(try XCTUnwrap(browse.recordRequest(event: event, now: now)).gameId, "no card: no game, as before")
        XCTAssertEqual(try XCTUnwrap(browse.recordRequest(event: event, now: now, card: "espn:cricket/123:1")).gameId,
                       "espn:cricket/123:1")
    }

    func testAFinishedMatchPlaysItsRecordingOnlyWhenThereIsOne() throws {
        let recording = try decode(Recording.self,
            #"{"id":5,"title":"Australia v India","status":"completed","started_at":1794999150000,"duration_sec":3600,"is_partial":0,"gameId":"espn:cricket/123:1"}"#)
        XCTAssertTrue(CricketPageText.playsRecording(card: "espn:cricket/123:1", finished: true, recordings: [recording]))
        XCTAssertFalse(CricketPageText.playsRecording(card: "espn:cricket/123:2", finished: true, recordings: [recording]),
                       "another match's recording")
        XCTAssertFalse(CricketPageText.playsRecording(card: nil, finished: true, recordings: [recording]), "no card")
        XCTAssertFalse(CricketPageText.playsRecording(card: "espn:cricket/123:1", finished: false, recordings: [recording]),
                       "not over: its channels, never the recording")
    }

    // MARK: Record waits while an earlier recording of it is being cancelled (Mark, 19 Nov 2026)

    @MainActor private struct Rig {
        let browse: BrowseModel
        let presenter: AppPresenter
        let log: Locked<[String]>
        /// How the server answers the cancellation: "ok", "refuse" (HTTP 500) or "drop" (no answer).
        let deleteMode: Locked<String>
        /// The scheduled list answers (false: no answer).
        let listAnswers: Locked<Bool>
        /// The recordings files answer (false: no answer).
        let filesAnswer: Locked<Bool>
        /// The scheduled list's answer when set (a JSON array).
        let listed: Locked<String?>
        /// How long the scheduled list takes to answer (seconds); its answer is what was listed when it was asked for.
        let listDelay: Locked<TimeInterval>
        /// Day one's row with another status.
        func row(_ status: String) -> String {
            #"[{"id":9,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(Int64(day1.program_start)),"program_end":\#(Int64(day1.program_end)),"status":"\#(status)","gameId":"espn:cricket/123:1"}]"#
        }
        let http: LocalHTTPServer
        let day1: ScheduledRecording
        let event: SportEvent
        let day2: GuideProgramme
        let channel = GuideChannel(rawID: "fox", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil, programmes: [])
        var key: String { PendingRemoval.key(.cancelSchedule, day1.id) }
        var day1Programme: GuideProgramme {
            GuideProgramme(title: day1.title, description: nil, startTime: day1.program_start, endTime: day1.program_end)
        }
        /// The game's record request, as a sport page builds it (its card as the game).
        func request() -> RecordRequest? { browse.recordRequest(event: event, card: "espn:cricket/123:1") }
        /// A gameless request for the same channel and time (Search, the Guide).
        func guideRequest() -> RecordRequest { browse.recordRequest(channel: channel, programme: day1Programme) }
        /// Waits until the cancellation's answer (or its absence) has been taken in.
        func settled() async {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, browse.recordingStore.pendingRemovals.contains(key),
                  browse.recordingStore.tombstones[key] == nil {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// Day one of a Test is scheduled (id 9) with the game's card, on Fox Cricket; day two airs a day later.
    private func rig() throws -> Rig {
        let log = Locked<[String]>([]), deleteMode = Locked("ok"), listAnswers = Locked(true), deleted = Locked(false)
        let filesAnswer = Locked(true), listed = Locked<String?>(nil), listDelay = Locked<TimeInterval>(0)
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), end = start + 7_200_000
        let day = Int64(86_400_000)
        let existing = #"{"id":9,"title":"Australia v India","channel_name":"Fox Cricket","source_id":1,"channel_item_id":"fox","program_start":\#(start),"program_end":\#(end),"status":"scheduled","gameId":"espn:cricket/123:1"}"#
        let http = try LocalHTTPServer { request in
            log.value.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("DELETE", "/api/recordings/scheduled/9"):
                switch deleteMode.value {
                case "refuse": return .json(#"{"error":"Internal error"}"#, status: 500)
                case "drop": var dropped = LocalHTTPServer.Response.json(""); dropped.drop = true; return dropped
                default:
                    deleted.value = true
                    return .json(existing.replacingOccurrences(of: "\"scheduled\"", with: "\"cancelled\""))
                }
            case ("GET", "/api/recordings/scheduled"):
                guard listAnswers.value else { var dropped = LocalHTTPServer.Response.json(""); dropped.drop = true; return dropped }
                var answer = LocalHTTPServer.Response.json(listed.value ?? (deleted.value ? "[]" : "[\(existing)]"))
                answer.delay = listDelay.value
                return answer
            case ("GET", "/api/recordings"):
                guard filesAnswer.value else { var dropped = LocalHTTPServer.Response.json(""); dropped.drop = true; return dropped }
                return .json("[]")
            default:
                return .notFound
            }
        }
        let browse = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        browse.reconcileRetry = .milliseconds(100)
        let presenter = AppPresenter()
        browse.presenter = presenter
        browse.schedules = [try decode(ScheduledRecording.self, existing)]
        let channel = SportEventChannel(sourceId: 1, rawID: "fox", name: "Fox Cricket", startTime: Double(start), endTime: Double(end))
        return Rig(browse: browse, presenter: presenter, log: log, deleteMode: deleteMode, listAnswers: listAnswers,
                   filesAnswer: filesAnswer, listed: listed, listDelay: listDelay, http: http,
                   day1: browse.schedules[0],
                   event: SportEvent(id: "cricket:1", title: "Australia v India", league: "Cricket", startTime: Double(start),
                                     endTime: Double(end), channels: [channel]),
                   day2: GuideProgramme(title: "Australia v India", description: nil, startTime: Double(start + day), endTime: Double(end + day)))
    }

    /// The Undo is open: Record waits ("Cancelling…") for that game and for a gameless request of the same channel and
    /// time (the Search and Guide path); the Guide's menu offers only the disabled Cancelling…; the hold menu has no
    /// Record; a path that still asks to schedule is refused with nothing sent. Another day of the Test stays recordable.
    func testWhileTheUndoIsOpenRecordWaits() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "nothing being cancelled yet")
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        XCTAssertTrue(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "the same game")
        XCTAssertTrue(rig.browse.cancellingEarlier(rig.guideRequest()), "the same channel and time, with no game (Search)")
        let subject = ProgrammeMenuSubject(channelName: "Fox Cricket", programme: rig.day1Programme, cancelling: true)
        XCTAssertEqual(ProgrammeMenu.items(subject, now: Date()).filter(\.isRecordSection), [.cancelling])
        XCTAssertFalse(rig.browse.cancellingEarlier(gameId: "espn:cricket/123:1", channel: rig.channel,
                                                    start: rig.day2.startTime, end: rig.day2.endTime),
                       "another day of the Test does not overlap: recordable")
        let made = await rig.browse.schedule(channel: rig.channel, programme: rig.day1Programme, before: nil, after: nil,
                                             gameId: "espn:cricket/123:1")
        XCTAssertFalse(made)
        XCTAssertEqual(rig.browse.actionError, PageWords.cancellingEarlierText)
        XCTAssertFalse(rig.log.value.contains("POST /api/recordings/schedule"), "nothing raced: \(rig.log.value)")
        XCTAssertNotNil(rig.presenter.pendingUndo, "Undo stays available")
    }

    /// The cancellation is confirmed: Record is back, as a new recording.
    func testOnceTheCancellationIsConfirmedRecordReturns() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        XCTAssertTrue(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "sent, not yet answered")
        await rig.settled()
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())))
        XCTAssertNil(rig.request()?.schedule, "a new recording")
    }

    /// The server refuses the cancellation: Record is back as Change recording of the schedule that stands.
    func testARefusedCancellationGivesBackChangeRecording() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.deleteMode.value = "refuse"
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        await rig.settled()
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())))
        XCTAssertEqual(rig.request()?.schedule?.id, 9, "Change recording of the standing schedule")
    }

    /// No answer to the cancellation: it stays in progress ("Cancelling…") until a scheduled list asked for after it has
    /// answered; then the list decides (here the row is still there: Change recording of it). Codex check of 320: that
    /// read is its own, begun after the failure, tried again until it answers, and independent of the recordings files
    /// (which do not answer here at all).
    func testALostCancellationWaitsForItsOwnReadOfTheList() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.deleteMode.value = "drop"
        rig.listAnswers.value = false
        rig.filesAnswer.value = false
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        await rig.settled()
        try await Task.sleep(for: .milliseconds(400))
        let requests = rig.log.value
        let delete = try XCTUnwrap(requests.firstIndex(of: "DELETE /api/recordings/scheduled/9"), "\(requests)")
        let read = try XCTUnwrap(requests.firstIndex(of: "GET /api/recordings/scheduled"), "\(requests)")
        XCTAssertLessThan(delete, read, "the read begins after the failure: \(requests)")
        XCTAssertTrue(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "no answer to the read either: still Cancelling…")
        rig.listAnswers.value = true // the files still do not answer
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, rig.browse.recordingStore.uncertainRemovals[rig.key] != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "the list has answered")
        XCTAssertEqual(rig.request()?.schedule?.id, 9, "the row is there: it stands")
    }

    /// Codex check of 320: a pending cancellation is matched on the server's channel identity (source and item), so a
    /// renamed channel still waits, and another channel with the old name does not.
    func testTheCancellationMatchesTheChannelByIdentityNotName() throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        let renamed = GuideChannel(rawID: "fox", sourceId: 1, name: "Fox Cricket HD", logo: nil, category: nil, programmes: [])
        XCTAssertTrue(rig.browse.cancellingEarlier(rig.browse.recordRequest(channel: renamed, programme: rig.day1Programme)))
        let other = GuideChannel(rawID: "kayo", sourceId: 1, name: "Fox Cricket", logo: nil, category: nil, programmes: [])
        XCTAssertFalse(rig.browse.cancellingEarlier(rig.browse.recordRequest(channel: other, programme: rig.day1Programme)),
                       "the same name on another item is another channel")
    }

    /// Codex check of 320: the programme page's request never binds the schedule being cancelled (no Change recording or
    /// second Cancel), and a second cancellation of it is not made (it would commit the first one's Undo early).
    func testTheProgrammePageWaitsAndASecondCancelIsRefused() throws {
        let rig = try rig()
        defer { rig.http.stop() }
        XCTAssertEqual(rig.guideRequest().schedule?.id, 9, "before: Change recording")
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        let first = try XCTUnwrap(rig.presenter.pendingUndo)
        XCTAssertNil(rig.guideRequest().schedule, "not Change recording of the schedule being cancelled")
        XCTAssertTrue(rig.browse.cancellingEarlier(rig.guideRequest()), "Cancelling…")
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        XCTAssertEqual(rig.presenter.pendingUndo?.id, first.id, "the first Undo stays")
        XCTAssertFalse(rig.log.value.contains("DELETE /api/recordings/scheduled/9"), "nothing committed: \(rig.log.value)")
    }

    /// Codex check of 320: Cancelling… is unavailable in every menu that draws the items (the iPhone's On Now menu too).
    func testCancellingIsUnavailableInEveryMenu() {
        XCTAssertFalse(ProgrammeMenuItem.cancelling.isAvailable)
        XCTAssertEqual(ProgrammeMenuItem.cancelling.accessibilityTitle, "Cancelling the earlier recording")
        XCTAssertTrue(ProgrammeMenuItem.recordThis().isAvailable)
    }

    /// #347 (C-M "Cancelling"): after a cancellation with no answer, the server listing the row "cancelling" keeps it in
    /// progress (the reads go on); once the row has gone it is resolved, and Record is a new recording.
    func testALostCancellationStaysInProgressWhileTheServerListsItCancelling() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.deleteMode.value = "drop"
        rig.listed.value = rig.row("cancelling")
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        await rig.settled()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThanOrEqual(rig.log.value.filter { $0 == "GET /api/recordings/scheduled" }.count, 2, "still reading: \(rig.log.value)")
        XCTAssertTrue(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "listed cancelling: Cancelling…")
        rig.listed.value = "[]"
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, rig.browse.recordingStore.uncertainRemovals[rig.key] != nil || !rig.browse.schedules.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "gone: cancelled")
        XCTAssertNil(rig.request()?.schedule, "a new recording")
    }

    /// #347: a schedule the server lists "cancelling" (cancelled from another device) is not active, never bound, its
    /// Record waits, and its row says "Cancelling…"; once its cancel failed (another status back) it stands again.
    func testAScheduleListedCancellingWaitsWhoeverCancelledIt() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.listed.value = rig.row("cancelling")
        await rig.browse.loadRecordings()
        let row = try XCTUnwrap(rig.browse.schedules.first)
        XCTAssertFalse(row.isActive)
        XCTAssertEqual(row.statusLabel, "Cancelling…")
        XCTAssertTrue(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())))
        XCTAssertTrue(rig.browse.cancellingEarlier(rig.guideRequest()))
        XCTAssertNil(rig.request()?.schedule, "never Change recording of it")
        rig.listed.value = rig.row("scheduled")
        await rig.browse.loadRecordings()
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())))
        XCTAssertEqual(rig.request()?.schedule?.id, 9, "its cancel failed: it stands")
    }

    /// Codex check of 320 (high): a lost cancellation's read answers late, after a newer list (asked for after it) has
    /// been published: it is older than what is shown and puts nothing back. Before, it published the row it listed
    /// ("cancelling") over the newer list that no longer had it, and Record waited until the next refresh.
    func testALateReconciliationReadNeverOverwritesANewerList() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.deleteMode.value = "drop"
        rig.listed.value = rig.row("cancelling")
        rig.listDelay.value = 1.2
        rig.browse.reconcileRetry = .seconds(5)
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        await rig.settled()
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !rig.log.value.contains("GET /api/recordings/scheduled") {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(rig.log.value.contains("GET /api/recordings/scheduled"), "the reconciliation read is asked: \(rig.log.value)")
        // The cancellation completes; a refresh asked for after that read answers first.
        rig.listDelay.value = 0
        rig.listed.value = "[]"
        await rig.browse.loadRecordings()
        XCTAssertTrue(rig.browse.schedules.isEmpty, "the newer list: cancelled")
        XCTAssertNil(rig.browse.recordingStore.uncertainRemovals[rig.key], "the newer list answered the cancellation")
        // The late answer (listing the row "cancelling") arrives.
        deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(rig.browse.schedules.isEmpty, "the late answer put the old row back: \(rig.browse.schedules.map(\.status))")
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "Record is back")
        XCTAssertNil(rig.request()?.schedule, "a new recording")
    }

    /// Codex check of 320 (high): two channels with the same name show a programme at the same start; each binds its own
    /// schedule (by source and item), never the other's. Before, both bound the first row with that name and start, so
    /// Change recording or Cancel from one changed the other's recording. Rows with no identity (an older server) stay
    /// unbound when they could mean either channel.
    func testTwoChannelsWithTheSameNameBindTheirOwnSchedules() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let start = Int64((Date().timeIntervalSince1970 + 3600) * 1000), end = start + 7_200_000
        func row(_ id: Int, _ name: String, _ identity: String) throws -> ScheduledRecording {
            try decode(ScheduledRecording.self,
                #"{"id":\#(id),"title":"Australia v India","channel_name":"\#(name)",\#(identity)"program_start":\#(start),"program_end":\#(end),"status":"scheduled"}"#)
        }
        let programme = GuideProgramme(title: "Australia v India", description: nil, startTime: Double(start), endTime: Double(end))
        func channel(_ item: String, _ name: String) -> GuideChannel {
            GuideChannel(rawID: item, sourceId: 1, name: name, logo: nil, category: nil, programmes: [])
        }
        let fox = channel("fox", "Fox Cricket"), kayo = channel("kayo", "Fox Cricket")
        browse.schedules = [try row(10, "Fox Cricket", #""source_id":1,"channel_item_id":"kayo","#),
                            try row(9, "Fox Cricket", #""source_id":1,"channel_item_id":"fox","#)]
        XCTAssertEqual(browse.recordRequest(channel: fox, programme: programme).schedule?.id, 9, "its own schedule, not the first by name")
        XCTAssertEqual(browse.recordRequest(channel: kayo, programme: programme).schedule?.id, 10)
        XCTAssertNil(browse.activeSchedule(channel: channel("other", "Fox Cricket"), programme: programme),
                     "a third channel of that name has none")

        // An older server's rows (no identity): two of the same name and start could be either channel's.
        browse.schedules = [try row(11, "Fox Cricket", ""), try row(12, "Fox Cricket", "")]
        XCTAssertNil(browse.recordRequest(channel: fox, programme: programme).schedule, "ambiguous: unbound")
        // One such row binds, as before, unless the guide has another channel of that name.
        browse.schedules = [try row(11, "Fox Cricket", "")]
        XCTAssertEqual(browse.recordRequest(channel: fox, programme: programme).schedule?.id, 11)
        browse.guide = [fox, kayo]
        XCTAssertNil(browse.recordRequest(channel: fox, programme: programme).schedule, "either channel's: unbound")
    }

    /// Codex check of 320 (medium): a routine refresh between a lost cancellation's reads still lists the row
    /// "cancelling": the cancellation stays in progress and its own reads go on, so when the server has finished they
    /// answer it even with the recordings files not answering. Before, the refresh ended the reads and the row stayed
    /// "cancelling" (Record waiting) until a whole refresh succeeded.
    func testARefreshWhileTheServerListsItCancellingKeepsTheReadsGoing() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        rig.deleteMode.value = "drop"
        rig.listed.value = rig.row("cancelling")
        rig.browse.reconcileRetry = .milliseconds(300)
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        rig.presenter.commitPendingUndo()
        await rig.settled()
        await rig.browse.loadRecordings()
        XCTAssertNotNil(rig.browse.recordingStore.uncertainRemovals[rig.key], "still listed cancelling: still in progress")
        rig.filesAnswer.value = false
        rig.listed.value = "[]"
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, rig.browse.recordingStore.uncertainRemovals[rig.key] != nil || !rig.browse.schedules.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(rig.browse.schedules.isEmpty, "its own reads saw it gone: \(rig.browse.schedules.map(\.status))")
        XCTAssertFalse(rig.browse.cancellingEarlier(try XCTUnwrap(rig.request())), "Record is back")
    }

    /// Codex check of 320 (medium): programme details offers neither Change recording nor Record while an earlier
    /// recording of the programme is being cancelled, here (the Undo open) or on the server (listed "cancelling"), but the
    /// disabled Cancelling…, by the record page's own check. Before, the page chose by `activeSchedule` alone: Change
    /// recording during the Undo (the cached row still active), Record once the server listed it cancelling (inactive).
    func testProgrammeDetailsShowsCancellingWhileItIsCancelled() async throws {
        let rig = try rig()
        defer { rig.http.stop() }
        let now = Date()
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day1Programme, now: now), .change)
        rig.browse.cancelWithUndo(rig.day1, presenter: rig.presenter)
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day1Programme, now: now), .cancelling,
                       "the Undo is open")
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day2, now: now), .record,
                       "another day does not overlap")
        rig.presenter.undoPending() // Undo: nothing sent
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day1Programme, now: now), .change)
        rig.listed.value = rig.row("cancelling")
        await rig.browse.loadRecordings()
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day1Programme, now: now), .cancelling,
                       "listed cancelling by the server (cancelled from another device)")
        rig.listed.value = "[]"
        await rig.browse.loadRecordings()
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: rig.day1Programme, now: now), .record)
        let ended = GuideProgramme(title: "Earlier", description: nil, startTime: (now.timeIntervalSince1970 - 7200) * 1000,
                                   endTime: (now.timeIntervalSince1970 - 3600) * 1000)
        XCTAssertEqual(rig.browse.programmeRecordAction(channel: rig.channel, programme: ended, now: now), .nothing)
    }
}
