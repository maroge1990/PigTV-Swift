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
        return .json(
          #"[{"id":1,"title":"Chiefs v Bills","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording"}]"#
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
    let deadline = Date().addingTimeInterval(5)
    while !browse.marks.recordingChannels.contains("Sports HD") && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(
      browse.marks.recordingChannels.contains("Sports HD"),
      "A visible dashboard refreshes the shared recording marks")
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
