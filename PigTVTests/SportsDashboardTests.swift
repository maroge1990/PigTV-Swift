import XCTest

@testable import PigTV

final class SportsDashboardTests: XCTestCase {
  nonisolated static func payload(
    hidden: Bool = false, revision: Int = 0, delay: Int = 90, status: String = "live",
    watch: Bool = true, start: Double = 1000, end: Double = 9000, league: String = "NFL",
    freshness: String = "fresh"
  ) -> String {
    #"{"now":5000,"timezone":"Australia/Melbourne","scope":"today","leagues":["\#(league)"],"preferences":{"avoidSpoilers":\#(hidden),"scoreDelaySeconds":\#(delay),"revision":\#(revision)},"games":[{"id":"game","league":"\#(league)","title":"Chiefs v Bills","start":\#(start),"end":null,"session":null,"circuit":null,"format":null,"competitors":[{"id":"a","name":"Chiefs","logo":"/api/logo/a"},{"id":"b","name":"Bills","logo":null}],"status":"\#(status)","freshness":"\#(freshness)","progress":{"period":5,"clock":"1:23","half":"top","day":"Day 2","overs":"90"},"scores":["17","14"],"situation":{"down":3,"distance":10,"balls":2,"strikes":1,"outs":1,"onFirst":true},"availability":"matched","broadcastStatus":"on-tv","channels":[{"sourceId":1,"id":"pos_7","stableId":"stable7","name":"Sports HD"}],"events":[{"id":"airing","start":\#(start),"end":\#(end)}],"canWatch":\#(watch)}]}"#
  }
  /// C-I for `payload()`: its one airing on its one channel (Watch associates the channel with its own airing).
  nonisolated static func payloadGuide(start: Double = 1000, end: Double = 9000) -> String {
    #"{"events":[{"id":"airing","title":"Raw prose","league":"NFL","start":\#(start),"end":\#(end),"channels":[{"sourceId":1,"id":"pos_7","stableId":"stable7","name":"Sports HD"}]}]}"#
  }
  private func decode(_ json: String) throws -> SportsDashboard {
    try JSONDecoder().decode(SportsDashboard.self, from: Data(json.utf8))
  }
  @MainActor private func client(
    _ server: LocalHTTPServer, enabled: Bool = true, account: Int? = 1, token: String = "a"
  ) throws -> APIClient {
    APIClient(
      address: try ServerAddress(server.baseURL), token: token,
      info: try FakePigTVServer.info(extraFeatures: #""sportsDashboard":\#(enabled)"#),
      accountID: account)
  }
  @MainActor func testRecordingBadgeUsesSourceAndStableIdentityInsteadOfChannelName() throws {
    let store = RecordingsStore()
    let marks = ScheduleMarks(following: store)
    let row = #"[{"id":1,"title":"Game","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording","source_id":1,"channel_item_id":"pos_7","channel_stable_id":"stable7"}]"#
    store.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(row.utf8))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 2, rawID: "pos_7", stableId: "stable7", name: "Sports HD")))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_7", stableId: "other", name: "Sports HD")))
    XCTAssertTrue(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_99", stableId: "stable7", name: "Renamed Sports")))
    store.schedules = []
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_99", stableId: "stable7", name: "Renamed Sports")))
  }
  @MainActor func testRecordingBadgeNeverGuessesAnIdentityForOldSchedules() throws {
    let store = RecordingsStore()
    let marks = ScheduleMarks(following: store)
    let row = #"[{"id":1,"title":"Game","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording"}]"#
    store.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(row.utf8))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_7", stableId: "stable7", name: "Sports HD")))
    XCTAssertTrue(marks.recordingChannels.contains("Sports HD"), "Ordinary Guide's existing marks remain separate")
  }
  @MainActor func testVisibleSettingsRevisionCannotWriteOverANewerPolledPreference() async throws {
    let writes = Locked(0)
    let server = try LocalHTTPServer { request in
      if request.method == "PUT" { writes.value += 1; return .json(#"{"avoidSpoilers":true,"scoreDelaySeconds":120,"revision":3}"#) }
      return .json(Self.payload(hidden: true, revision: 2, delay: 120))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    _ = await model.load()
    await model.save(avoidSpoilers: false, delay: 90, revision: 1)
    XCTAssertEqual(writes.value, 0, "The visible choice must not silently borrow a newer revision")
    XCTAssertTrue(model.message?.contains("changed") == true)
  }
  @MainActor func testSavingStaysTrueUntilAuthoritativePreferenceRereadCompletes() async throws {
    let written = Locked(false)
    let rereading = Locked(false)
    let release = DispatchSemaphore(value: 0)
    let server = try LocalHTTPServer { request in
      if request.method == "PUT" {
        written.value = true
        return .json(#"{"avoidSpoilers":true,"scoreDelaySeconds":120,"revision":1}"#)
      }
      if written.value {
        rereading.value = true
        _ = release.wait(timeout: .now() + 10)
      }
      return .json(Self.payload(hidden: written.value, revision: written.value ? 1 : 0, delay: written.value ? 120 : 90))
    }
    defer { release.signal(); server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    _ = await model.load()
    let save = Task { await model.save(avoidSpoilers: true, delay: 120, revision: 0) }
    let deadline = Date().addingTimeInterval(5)
    while !rereading.value && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(rereading.value)
    XCTAssertTrue(model.saving, "Controls must remain mounted through the real GET after PUT, not just the write")
    XCTAssertNil(model.dashboard, "Pending preference revalidation cannot reveal scores")
    release.signal()
    await save.value
    XCTAssertFalse(model.saving)
    XCTAssertEqual(model.dashboard?.preferences.revision, 1)
  }
  func testSevenFamiliesAndNeutralProgressWithoutFabricatedSituations() throws {
    let leagues: [String: SportsGame.Family] = [
      "AFL": .australianFootball, "NBA": .basketball, "EPL": .football, "FA Cup": .football,
      "UEFA": .football, "Championship": .football, "NFL": .americanFootball, "MLB": .baseball,
      "Cricket": .cricket, "F1": .motorsport,
    ]
    for (league, family) in leagues {
      let game = try XCTUnwrap(decode(Self.payload(league: league)).games.first)
      XCTAssertEqual(game.family, family)
      XCTAssertEqual(game.statusLabel, "LIVE")
      XCTAssertNil(game.visibleScores(hidden: true))
      XCTAssertNil(game.situationLabel(hidden: true))
      if league == "F1" {
        XCTAssertNil(game.visibleScores(hidden: false))
        XCTAssertEqual(game.progressLabel(), "")
      }
      if league == "MLB" {
        XCTAssertTrue(game.progressLabel().contains("Top 5"))
        XCTAssertTrue(game.situationLabel(hidden: false)?.contains("First") == true)
      }
      if league == "NBA" || league == "NFL" {
        XCTAssertTrue(game.progressLabel().contains("Overtime 1"))
      }
      if league == "EPL" { XCTAssertTrue(game.progressLabel().contains("Penalties")) }
      if league == "Cricket" { XCTAssertTrue(game.progressLabel().contains("Day 2")) }
    }
    let stale = try XCTUnwrap(decode(Self.payload(freshness: "stale")).games.first)
    XCTAssertNil(stale.visibleScores(hidden: false))
    XCTAssertNil(stale.situationLabel(hidden: false))
    XCTAssertEqual(stale.progressLabel(), "")
    XCTAssertEqual(stale.statusLabel, "ON TV NOW")
  }
  func testFinalExpiredFutureAndReorderedChannelsCannotTuneUnrelatedTV() throws {
    for (status, start, end, watch) in [
      ("finished", 1000.0, 9000.0, true), ("cancelled", 1000, 9000, true),
      ("postponed", 1000, 9000, true), ("live", 1000, 5000, true), ("scheduled", 6000, 9000, true),
      ("unknown", 1000, 9000, false),
    ] {
      let game = try XCTUnwrap(
        decode(Self.payload(status: status, watch: watch, start: start, end: end)).games.first)
      XCTAssertNil(game.actionableEvent(at: 5000, watch: true))
    }
    let game = try XCTUnwrap(decode(Self.payload()).games.first)
    XCTAssertNil(game.actionableEvent(at: 5000, channelKey: "1:s:gone", watch: true))
    XCTAssertEqual(
      game.actionableEvent(at: 5000, channelKey: "1:s:stable7", watch: true)?.best?.stableId,
      "stable7")
    XCTAssertEqual(game.actionableEvent(at: 5000, watch: true)?.endTime, 9000)
  }
  func testARecordingSheetCannotRenderUnvalidatedOrChangedPreferences() {
    let original = SportsPreferences(avoidSpoilers: false, scoreDelaySeconds: 90, revision: 0)
    let hidden = SportsPreferences(avoidSpoilers: true, scoreDelaySeconds: 300, revision: 1)
    XCTAssertTrue(SportsPresentationPolicy.canRender(storedRevision: 0, current: original))
    XCTAssertFalse(SportsPresentationPolicy.canRender(storedRevision: 0, current: nil))
    XCTAssertFalse(SportsPresentationPolicy.canRender(storedRevision: 0, current: hidden))
  }

  @MainActor func testRecordingUsesTheSelectedChannelsOwnAiringAndKeepsProjectedTitle() async throws
  {
    var object = try JSONSerialization.jsonObject(with: Data(Self.payload().utf8)) as! [String: Any]
    var games = object["games"] as! [[String: Any]]
    let second: [String: Any] = [
      "sourceId": 1, "id": "pos_8", "stableId": "stable8", "name": "Sports B",
    ]
    var channels = games[0]["channels"] as! [[String: Any]]
    channels.append(second)
    games[0]["channels"] = channels
    games[0]["events"] = [
      ["id": "airing1", "start": 1000, "end": 9000],
      ["id": "airing2", "start": 6000, "end": 12000],
    ]
    object["games"] = games
    let dashboard = String(
      decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let guide =
      #"{"events":[{"id":"airing2","title":"Untrusted result prose 99-0","league":"NFL","start":6000,"end":12000,"channels":[{"sourceId":1,"id":"pos_8","stableId":"stable8","name":"Sports B"}]}]}"#
    let server = try LocalHTTPServer { request in
      request.path == "/api/sports/events" ? .json(guide) : .json(dashboard)
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let event = await model.event(gameID: "game", channelKey: "1:s:stable8", watch: false)
    XCTAssertEqual(event?.id, "airing2")
    XCTAssertEqual(event?.startTime, 6000)
    XCTAssertEqual(event?.endTime, 12000)
    XCTAssertEqual(
      event?.title, "Chiefs v Bills", "Raw guide prose never enters the recording sheet")
    XCTAssertEqual(event?.best?.stableId, "stable8")
  }

  @MainActor func testVisibleDashboardRefreshesRecordingBadgesWithoutVisitingAnotherTab()
    async throws
  {
    let server = try LocalHTTPServer { request in
      switch request.path {
      case "/api/sports/dashboard": return .json(Self.payload())
      case "/api/recordings": return .json("[]")
      case "/api/recordings/scheduled":
        // The card's badge matches source + stable identity, so the schedule carries them (not just a name).
        return .json(
          #"[{"id":1,"title":"Chiefs v Bills","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording","source_id":1,"channel_item_id":"pos_7","channel_stable_id":"stable7"}]"#
        )
      default: return .notFound
      }
    }
    defer { server.stop() }
    let client = try client(server)
    let browse = BrowseModel(client: client)
    let model = SportsDashboardModel(
      client: client, refreshActivity: { await browse.loadRecordingsIfStale(maxAge: 15) })
    let loop = Task { await model.keepFresh(league: nil) }
    defer { loop.cancel() }
    // The badge the card draws: any of the game's own channels recording, by identity.
    func badged() -> Bool {
      model.dashboard?.games.first?.channels.contains { browse.marks.isRecording($0) } == true
    }
    let deadline = Date().addingTimeInterval(5)
    while !badged() && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(badged(), "A visible dashboard refreshes the shared recording marks for its card's identity")
    XCTAssertTrue(
      server.requests.allSatisfy {
        ["/api/sports/dashboard", "/api/recordings", "/api/recordings/scheduled"].contains($0.path)
      }, "Badges never resolve or warm a provider")
  }

  @MainActor func testCapabilityAndUnknownAccountMakeNoRequests() async throws {
    let server = try LocalHTTPServer { _ in .json(Self.payload()) }
    defer { server.stop() }
    let off = SportsDashboardModel(client: try client(server, enabled: false))
    let unknown = SportsDashboardModel(client: try client(server, account: nil))
    let a = await off.load()
    let b = await unknown.load()
    XCTAssertFalse(a)
    XCTAssertFalse(b)
    XCTAssertTrue(server.requests.isEmpty)
    XCTAssertNil(off.dashboard)
    XCTAssertNil(unknown.dashboard)
  }
  @MainActor func testHideRejectsLateRevealAndBackgroundNeverFetches() async throws {
    let server = try LocalHTTPServer { _ in
      var r = LocalHTTPServer.Response.json(Self.payload())
      r.delay = 0.3
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let task = Task { await model.load() }
    let deadline = Date().addingTimeInterval(5)
    while server.requests.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(server.requests.isEmpty)
    model.sceneActive(false)
    _ = await task.value
    XCTAssertNil(model.dashboard)
    let count = server.requests.count
    _ = await model.load()
    XCTAssertEqual(server.requests.count, count)
    model.sceneActive(true)
    XCTAssertNil(model.dashboard)
    _ = await model.load()
    XCTAssertNotNil(model.dashboard)
  }
  @MainActor func test404FallsBackAndOfflineClearsPreviouslyRevealedScores() async throws {
    let failing = Locked(false)
    let server = try LocalHTTPServer { _ in failing.value ? .notFound : .json(Self.payload()) }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    _ = await model.load()
    XCTAssertNotNil(model.dashboard)
    failing.value = true
    _ = await model.load()
    XCTAssertNil(model.dashboard)
    XCTAssertTrue(model.legacy)
    let offline = try LocalHTTPServer { _ in .json(Self.payload(), status: 503) }
    defer { offline.stop() }
    let unavailable = SportsDashboardModel(client: try client(offline))
    _ = await unavailable.load()
    XCTAssertNil(unavailable.dashboard)
    XCTAssertNotNil(unavailable.message)
  }
  @MainActor func testTwoDevicesSyncRevisionConflictsAndSeparateUsers() async throws {
    let preferences = Locked([
      "a": SportsPreferences(avoidSpoilers: false, scoreDelaySeconds: 90, revision: 0),
      "b": SportsPreferences(avoidSpoilers: false, scoreDelaySeconds: 90, revision: 0),
    ])
    let server = try LocalHTTPServer { request in
      let account = request.headers["authorization"] == "Bearer b" ? "b" : "a"
      let current = preferences.value[account]!
      if request.method == "PUT" {
        guard let patch = try? JSONDecoder().decode(SportsPreferences.self, from: request.body)
        else { return .json("{}", status: 400) }
        guard patch.revision == current.revision else { return .json("{}", status: 409) }
        let next = SportsPreferences(
          avoidSpoilers: patch.avoidSpoilers, scoreDelaySeconds: patch.scoreDelaySeconds,
          revision: current.revision + 1)
        preferences.value[account] = next
        return .json(String(decoding: try! JSONEncoder().encode(next), as: UTF8.self))
      }
      return .json(
        Self.payload(
          hidden: current.avoidSpoilers, revision: current.revision,
          delay: current.scoreDelaySeconds))
    }
    defer { server.stop() }
    let one = SportsDashboardModel(client: try client(server))
    let tv = SportsDashboardModel(client: try client(server))
    let other = SportsDashboardModel(client: try client(server, account: 2, token: "b"))
    _ = await one.load()
    _ = await tv.load()
    _ = await other.load()
    await one.save(avoidSpoilers: true, delay: 300)
    XCTAssertTrue(one.dashboard?.preferences.avoidSpoilers == true)
    await tv.save(avoidSpoilers: false, delay: 0)  // revision zero loses, never silently overwrites
    XCTAssertTrue(tv.dashboard?.preferences.avoidSpoilers == true)
    XCTAssertEqual(tv.dashboard?.preferences.scoreDelaySeconds, 300)
    XCTAssertTrue(tv.message?.contains("another device") == true)
    _ = await other.load()
    XCTAssertFalse(other.dashboard!.preferences.avoidSpoilers)
    XCTAssertEqual(other.dashboard?.preferences.scoreDelaySeconds, 90)
    XCTAssertTrue(
      server.requests.allSatisfy {
        ["/api/sports/dashboard", "/api/sports/preferences"].contains($0.path)
      })
  }
  @MainActor func testAiringThatExpiresInTransitCannotTune() async throws {
    let server = try LocalHTTPServer { _ in
      var r = LocalHTTPServer.Response.json(Self.payload(end: 5010))
      r.delay = 0.1
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let event = await model.event(gameID: "game", watch: true)
    XCTAssertNil(event, "response.now predates transit; the airing ended before select completed")
  }
  /// Review finding 2: a 20 s poll or a reappearance load overlapping an action's revalidation
  /// superseded it, so Watch said "That airing is no longer available" and nothing played.
  @MainActor func testRevalidationSurvivesAnOverlappingLoad() async throws {
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/events" { return .json(Self.payloadGuide()) }
      var r = LocalHTTPServer.Response.json(Self.payload())
      r.delay = 0.3
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let action = Task { await model.event(gameID: "game", watch: true) }
    let deadline = Date().addingTimeInterval(5)
    while server.requests.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = await model.load()
    let event = await action.value
    XCTAssertEqual(event?.best?.stableId, "stable7", "An overlapping poll must not cancel the action")
    XCTAssertNil(model.message)
    XCTAssertNotNil(model.dashboard)
  }
  @MainActor func testRevalidationIsStillRefusedAfterHide() async throws {
    let server = try LocalHTTPServer { _ in
      var r = LocalHTTPServer.Response.json(Self.payload())
      r.delay = 0.3
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let action = Task { await model.event(gameID: "game", watch: true) }
    let deadline = Date().addingTimeInterval(5)
    while server.requests.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    model.sceneActive(false)
    let event = await action.value
    XCTAssertNil(event, "Background/scope change/save still invalidates an in-flight action")
    XCTAssertNil(model.dashboard)
  }
  /// Review finding 3: a cancelled request (leaving the page) is not an outage.
  @MainActor func testCancelledLoadIsNotReportedAsAnOutage() async throws {
    let server = try LocalHTTPServer { _ in
      var r = LocalHTTPServer.Response.json(Self.payload())
      r.delay = 2
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let load = Task { await model.load() }
    let deadline = Date().addingTimeInterval(5)
    while server.requests.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    load.cancel()
    _ = await load.value
    XCTAssertNil(model.message, "URLError(.cancelled) is a cancellation, not 'Sports data unavailable'")
  }
  @MainActor func testOutageMessageClearsAfterASuccessfulLoad() async throws {
    let failing = Locked(true)
    let server = try LocalHTTPServer { _ in
      failing.value ? .json(#"{"error":"down"}"#, status: 503) : .json(Self.payload())
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    _ = await model.load()
    XCTAssertNotNil(model.message)
    failing.value = false
    _ = await model.load()
    XCTAssertNotNil(model.dashboard)
    XCTAssertNil(model.message, "A recovered load must not keep saying the data is unavailable")
  }
  /// A game on two channels, A (`stable7`, airing `airingA`) and B (`stable8`, airing `airingB`), with C-O's own
  /// `now`. Both airings are C-I references; only C-I says which channel carries which.
  nonisolated static func twoChannels(
    now: Double = 5000, revision: Int = 0, hidden: Bool = false, title: String = "Chiefs v Bills",
    gameStart: Double = 1000, a: (Double, Double) = (1000, 9000), b: (Double, Double) = (1000, 9000),
    watch: Bool = true
  ) -> String {
    #"{"now":\#(now),"timezone":"Australia/Melbourne","scope":"today","leagues":["NFL"],"preferences":{"avoidSpoilers":\#(hidden),"scoreDelaySeconds":90,"revision":\#(revision)},"games":[{"id":"game","league":"NFL","title":"\#(title)","start":\#(gameStart),"end":null,"session":null,"circuit":null,"format":null,"competitors":[],"status":"unknown","freshness":"unavailable","progress":{},"availability":"matched","broadcastStatus":"on-tv","channels":[{"sourceId":1,"id":"pos_7","stableId":"stable7","name":"Sports A"},{"sourceId":1,"id":"pos_8","stableId":"stable8","name":"Sports B"}],"events":[{"id":"airingA","start":\#(a.0),"end":\#(a.1)},{"id":"airingB","start":\#(b.0),"end":\#(b.1)}],"canWatch":\#(watch),"dataSource":"guide"}]}"#
  }
  /// C-I for `twoChannels`: each airing on its own channel, with raw guide prose that must never be shown.
  nonisolated static func twoChannelGuide(
    a: (Double, Double) = (1000, 9000), b: (Double, Double) = (1000, 9000)
  ) -> String {
    #"{"events":[{"id":"airingA","title":"Raw prose 21-14","league":"NFL","start":\#(a.0),"end":\#(a.1),"channels":[{"sourceId":1,"id":"pos_7","stableId":"stable7","name":"Sports A"}]},{"id":"airingB","title":"Raw prose 21-14","league":"NFL","start":\#(b.0),"end":\#(b.1),"channels":[{"sourceId":1,"id":"pos_8","stableId":"stable8","name":"Sports B"}]}]}"#
  }
  @MainActor private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition())
  }

  /// Codex r1 finding 1 (high): Record captured the game title from its revalidation snapshot, then awaited C-I;
  /// a poll that published newer preferences (spoilers hidden) meanwhile was not noticed, and the view tagged the
  /// old title with the current revision, so the record sheet rendered the old (result-bearing) guide title.
  @MainActor func testRecordingRefusesATitleWhosePreferencesChangedDuringTheGuideRead() async throws {
    let revision = Locked(0)
    let guideRequested = Locked(false)
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/events" {
        guideRequested.value = true
        var r = LocalHTTPServer.Response.json(Self.twoChannelGuide())
        r.delay = 0.5
        return r
      }
      let hidden = revision.value > 0
      return .json(
        Self.twoChannels(
          revision: revision.value, hidden: hidden,
          title: hidden ? "NFL · Guide event" : "Guide final 21-14"))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let action = Task { await model.event(gameID: "game", channelKey: "1:s:stable8", watch: false) }
    try await waitUntil { guideRequested.value }
    revision.value = 1
    _ = await model.load()  // the 20 s poll publishes "spoilers hidden" while C-I is in flight
    XCTAssertEqual(model.dashboard?.preferences.revision, 1)
    let event = await action.value
    XCTAssertNil(event, "A title projected under revision 0 must not reach a sheet shown under revision 1")
    XCTAssertNotNil(model.message)
  }

  /// Codex r1 finding 2 (high): both channels were current at `response.now`, A's airing expired in transit and B's
  /// did not; Watch validated "any current airing" (B's) but kept A selected, so A tuned after its programme ended.
  @MainActor func testWatchRequiresTheSelectedChannelsOwnAiringWhenAnotherExpiresInTransit() async throws {
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/events" {
        return .json(Self.twoChannelGuide(a: (1000, 5100), b: (1000, 9000)))
      }
      var r = LocalHTTPServer.Response.json(Self.twoChannels(a: (1000, 5100), b: (1000, 9000)))
      r.delay = 0.3
      return r
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let a = await model.event(gameID: "game", channelKey: "1:s:stable7", watch: true)
    XCTAssertNil(a, "A's own airing ended in transit; B's current airing must not let A tune")
    let card = await model.event(gameID: "game", watch: true)
    XCTAssertEqual(card?.best?.stableId, "stable8", "A card select tunes a channel whose own airing is current")
    XCTAssertEqual(card?.id, "airingB")
    let b = await model.event(gameID: "game", channelKey: "1:s:stable8", watch: true)
    XCTAssertEqual(b?.best?.stableId, "stable8")
    XCTAssertEqual(b?.endTime, 9000)
  }
  /// Finding 2: the selected airing's bounds age through every request the action makes, C-I included.
  @MainActor func testWatchAgesTheSelectedAiringThroughTheGuideRead() async throws {
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/events" {
        var r = LocalHTTPServer.Response.json(Self.twoChannelGuide(a: (1000, 5300)))
        r.delay = 1.0
        return r
      }
      return .json(Self.twoChannels(a: (1000, 5300)))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let a = await model.event(gameID: "game", channelKey: "1:s:stable7", watch: true)
    XCTAssertNil(a, "A's airing ended while its channel association was being read")
  }
  nonisolated private static func wallMS() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }
  /// Codex r1 finding 3 (medium): "Watch B when it starts" slept until the game's start (A's airing, 20:00), not B's
  /// (20:15); its single wake-up revalidation refused, and the scheduled watch was cleared for good.
  @MainActor func testWatchWhenItStartsWaitsForTheSelectedBroadcastNotTheGame() async throws {
    let t0 = Self.wallMS()
    let a = (t0 + 300, t0 + 600_000)
    let b = (t0 + 2000, t0 + 600_000)
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/events" { return .json(Self.twoChannelGuide(a: a, b: b)) }
      let now = Self.wallMS()
      return .json(Self.twoChannels(now: now, gameStart: a.0, a: a, b: b, watch: now >= a.0))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let first = await model.airing(gameID: "game", channelKey: "1:s:stable8", watch: false)
    XCTAssertEqual(first?.event.startTime, b.0, "B's own airing, not the game's start")
    let event = await model.watchWhenItStarts(
      gameID: "game", channelKey: "1:s:stable8", from: try XCTUnwrap(first))
    let woke = Self.wallMS()
    XCTAssertEqual(event?.best?.stableId, "stable8")
    XCTAssertEqual(event?.id, "airingB")
    XCTAssertGreaterThanOrEqual(woke, b.0, "Plays no earlier than the selected broadcast's start")
  }
  /// Finding 3: on wake, an authoritative state that still places the airing in the future (here the guide moved
  /// it later) re-arms instead of consuming the scheduled watch.
  @MainActor func testWatchWhenItStartsReArmsWhileTheAiringIsStillInTheFuture() async throws {
    let t0 = Self.wallMS()
    let bStart = Locked(t0 + 600)
    let server = try LocalHTTPServer { request in
      let b = (bStart.value, t0 + 600_000)
      if request.path == "/api/sports/events" { return .json(Self.twoChannelGuide(b: b)) }
      return .json(Self.twoChannels(now: Self.wallMS(), gameStart: b.0, b: b, watch: false))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let revalidated = await model.airing(gameID: "game", channelKey: "1:s:stable8", watch: false)
    let first = try XCTUnwrap(revalidated)
    XCTAssertEqual(first.event.startTime, t0 + 600)
    bStart.value = t0 + 2000  // the guide moves B's airing 1.4 s later
    let event = await model.watchWhenItStarts(gameID: "game", channelKey: "1:s:stable8", from: first)
    XCTAssertGreaterThanOrEqual(Self.wallMS(), t0 + 2000)
    XCTAssertNil(event, "C-O still says canWatch false: it never plays on the client's clock alone")
    XCTAssertGreaterThanOrEqual(
      server.requests.filter { $0.path == "/api/sports/dashboard" }.count, 3,
      "It woke at the old start, saw the airing still in the future, and re-armed")
  }
  @MainActor func testWatchWhenItStartsPlaysAfterReArming() async throws {
    let t0 = Self.wallMS()
    let bStart = Locked(t0 + 600)
    let server = try LocalHTTPServer { request in
      let b = (bStart.value, t0 + 600_000)
      if request.path == "/api/sports/events" { return .json(Self.twoChannelGuide(b: b)) }
      let now = Self.wallMS()
      return .json(Self.twoChannels(now: now, gameStart: b.0, b: b, watch: now >= b.0))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let revalidated = await model.airing(gameID: "game", channelKey: "1:s:stable8", watch: false)
    let first = try XCTUnwrap(revalidated)
    bStart.value = t0 + 2000
    let event = await model.watchWhenItStarts(gameID: "game", channelKey: "1:s:stable8", from: first)
    XCTAssertGreaterThanOrEqual(Self.wallMS(), t0 + 2000)
    XCTAssertEqual(event?.best?.stableId, "stable8", "The re-armed watch plays once B's airing starts")
    XCTAssertEqual(event?.startTime, t0 + 2000)
  }
  /// Finding 3: re-arming is bounded; an airing that keeps moving later ends the scheduled watch with a message.
  @MainActor func testWatchWhenItStartsReArmsABoundedNumberOfTimes() async throws {
    let t0 = Self.wallMS()
    let bStart = Locked(t0 + 300)
    let server = try LocalHTTPServer { request in
      if request.path == "/api/sports/dashboard" { bStart.value = Self.wallMS() + 300 }
      let b = (bStart.value, t0 + 600_000)
      if request.path == "/api/sports/events" { return .json(Self.twoChannelGuide(b: b)) }
      return .json(Self.twoChannels(now: Self.wallMS(), gameStart: b.0, b: b, watch: false))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let revalidated = await model.airing(gameID: "game", channelKey: "1:s:stable8", watch: false)
    let first = try XCTUnwrap(revalidated)
    let event = await model.watchWhenItStarts(gameID: "game", channelKey: "1:s:stable8", from: first)
    XCTAssertNil(event)
    XCTAssertNotNil(model.message)
    XCTAssertEqual(
      server.requests.filter { $0.path == "/api/sports/dashboard" }.count,
      2 + SportsDashboardModel.maxRearms)
  }
  /// Finding 1: the revalidated airing carries its own snapshot's revision to the record sheet.
  @MainActor func testRevalidatedAiringCarriesItsSnapshotsRevision() async throws {
    let server = try LocalHTTPServer { request in
      request.path == "/api/sports/events"
        ? .json(Self.twoChannelGuide()) : .json(Self.twoChannels(revision: 4))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    let airing = await model.airing(gameID: "game", channelKey: "1:s:stable8", watch: false)
    XCTAssertEqual(airing?.revision, 4)
    XCTAssertFalse(
      SportsPresentationPolicy.canRender(
        storedRevision: try XCTUnwrap(airing).revision,
        current: SportsPreferences(avoidSpoilers: true, scoreDelaySeconds: 90, revision: 5)))
  }
  @MainActor func testSelectObtainsCurrentWholeStateAndRefusesNewFinal() async throws {
    let final = Locked(false)
    let server = try LocalHTTPServer { _ in
      .json(Self.payload(status: final.value ? "finished" : "live"))
    }
    defer { server.stop() }
    let model = SportsDashboardModel(client: try client(server))
    _ = await model.load()
    final.value = true
    let event = await model.event(gameID: "game", watch: true)
    XCTAssertNil(event)
    XCTAssertEqual(server.requests.count, 2)
    XCTAssertTrue(server.requests.allSatisfy { $0.path == "/api/sports/dashboard" })
  }
}
