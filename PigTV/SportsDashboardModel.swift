import Combine
import Foundation

/// Ephemeral, per authenticated APIClient. Never persist a score or preference on this device.
@MainActor
final class SportsDashboardModel: ObservableObject {
  let client: APIClient
  private let refreshActivity: @MainActor () async -> Void
  /// 20 s in the app (C-O); tests shorten it.
  private let pollInterval: Duration
  @Published private(set) var dashboard: SportsDashboard?
  @Published private(set) var legacy = false
  @Published private(set) var message: String?
  @Published private(set) var busy = false
  /// The newest request: a later load supersedes an earlier one's result.
  private var generation = 0
  /// Moved only by `hide()` (background, scope change, save): it refuses every in-flight load and action.
  private var invalidation = 0
  private func elapsedMilliseconds(since instant: ContinuousClock.Instant) -> Double {
    let elapsed = instant.duration(to: ContinuousClock.now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }
  @Published private(set) var saving = false
  private var backgrounded = false
  private(set) var league: String?
  var enabled: Bool {
    #if DEBUG
      if fixture != nil { return true }
    #endif
    return client.info?.features.sportsDashboard == true
  }

  #if DEBUG
    private var fixture: SportsDashboard?
    /// `PIGTV_UI_TEST_DASHBOARD_PLAY=1`: the fixture is "served" with a short latency through the ordinary
    /// load/hide/revalidation path, so a UI test can reach `playSportEvent` (the player fixture stays tuning).
    private var fixtureServed = false
  #endif
  init(
    client: APIClient, refreshActivity: @escaping @MainActor () async -> Void = {},
    pollInterval: Duration = .seconds(20)
  ) {
    self.client = client
    self.refreshActivity = refreshActivity
    self.pollInterval = pollInterval
    #if DEBUG
      if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "sport-dashboard" {
        fixture = SportsDashboardFixtures.response(
          hidden: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SPOILERS"] == "hidden")
        dashboard = fixture
        fixtureServed = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_PLAY"] == "1"
      }
    #endif
  }

  /// Invalidate before backgrounding/resume, changing identity/scope or saving preferences.
  /// Late responses and already-open details cannot resurrect a previously revealed score.
  func hide() {
    invalidation += 1
    generation += 1
    dashboard = nil
    busy = false
  }

  /// Background and the return from it. Repeating the current state (.inactive → .active after Control Center)
  /// changes nothing, so it neither clears scores nor refuses an action.
  func sceneActive(_ active: Bool) {
    guard backgrounded == active else { return }
    backgrounded = !active
    hide()
  }

  @discardableResult
  func load(league: String? = nil, clear: Bool = false) async -> Bool {
    await loadSnapshot(league: league, clear: clear, completingSave: false)
  }

  private func loadSnapshot(league: String?, clear: Bool, completingSave: Bool) async -> Bool {
    guard enabled, client.accountID != nil, (!saving || completingSave), !backgrounded else { return false }
    #if DEBUG
      if let fixture, !fixtureServed {
        dashboard = fixture
        self.league = league
        return true
      }
    #endif
    if clear || self.league != league { hide() }
    self.league = league
    generation += 1
    let requestGeneration = generation
    busy = true
    defer { if generation == requestGeneration { busy = false } }
    let startedAt = ContinuousClock.now
    do {
      let response = try await fetchDashboard(league: league)
      guard generation == requestGeneration, !Task.isCancelled else { return false }
      publish(snapshot(response, startedAt: startedAt))
      return true
    } catch {
      // Leaving the page cancels its request (URLError.cancelled): not an outage, nothing to clear.
      guard generation == requestGeneration, !UserMessage.isCancellation(error) else { return false }
      failed(error)
      return false
    }
  }

  private static let unavailable = "Sports data unavailable. Reconnect and try again."

  private struct Snapshot {
    let dashboard: SportsDashboard
    let eligibilityTime: Double
    let receivedAt: ContinuousClock.Instant
  }

  /// Only airing eligibility ages locally. The displayed delayed game state never ticks.
  /// Use the full round-trip as a conservative bound on response transit, with a monotonic clock.
  private func snapshot(_ response: SportsDashboard, startedAt: ContinuousClock.Instant) -> Snapshot {
    Snapshot(
      dashboard: response, eligibilityTime: response.now + elapsedMilliseconds(since: startedAt),
      receivedAt: ContinuousClock.now)
  }

  private func publish(_ snapshot: Snapshot) {
    dashboard = snapshot.dashboard
    busy = false
    if message == Self.unavailable { message = nil }
  }

  private func failed(_ error: Error) {
    dashboard = nil
    if error as? PigTVError == .http(404) {
      legacy = true
    } else {
      message = Self.unavailable
    }
  }

  /// An action's own authoritative read (review finding 2). A poll or reappearance load overlapping it cannot
  /// supersede it; `hide()` (background, scope change, save) still refuses it. It publishes only when no newer load
  /// has started since, and then an older one still in flight cannot overwrite it.
  private func revalidate() async -> Snapshot? {
    guard enabled, client.accountID != nil, !saving, !backgrounded else { return nil }
    let invalidated = invalidation
    let startGeneration = generation
    let startedAt = ContinuousClock.now
    do {
      let response = try await fetchDashboard(league: league)
      guard invalidation == invalidated, !backgrounded, !Task.isCancelled else { return nil }
      let fresh = snapshot(response, startedAt: startedAt)
      if generation == startGeneration {
        generation += 1
        publish(fresh)
      }
      return fresh
    } catch {
      guard invalidation == invalidated, generation == startGeneration, !UserMessage.isCancellation(error)
      else { return nil }
      failed(error)
      return nil
    }
  }

  private func fetchDashboard(league: String?) async throws -> SportsDashboard {
    #if DEBUG
      if fixtureServed, let fixture {
        let latency = Int(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_LATENCY_MS"] ?? "") ?? 400
        try await Task.sleep(for: .milliseconds(min(5000, max(0, latency))))
        return fixture
      }
    #endif
    return try await client.decodedOffMain(
      "sports/dashboard", query: league.map { [URLQueryItem(name: "league", value: $0)] } ?? [])
  }

  func save(avoidSpoilers: Bool, delay: Int, revision: Int? = nil) async {
    guard let prefs = dashboard?.preferences, !saving, (0...300).contains(delay) else { return }
    guard revision == nil || revision == prefs.revision else {
      message = "Settings changed. Review the current values and choose again."
      return
    }
    var next = prefs
    next.avoidSpoilers = avoidSpoilers
    next.scoreDelaySeconds = delay
    #if DEBUG
      if fixture != nil {
        saving = true
        hide()
        let requestGeneration = generation
        defer { saving = false }
        let delayMS = min(5000, max(0, Int(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SAVE_DELAY_MS"] ?? "0") ?? 0))
        if delayMS > 0 { try? await Task.sleep(for: .milliseconds(delayMS)) }
        guard generation == requestGeneration, !backgrounded, !Task.isCancelled else { return }
        fixture = SportsDashboardFixtures.response(
          hidden: avoidSpoilers, delay: delay, revision: prefs.revision + 1)
        dashboard = fixture
        return
      }
    #endif
    saving = true
    defer { saving = false }
    hide()
    let requestGeneration = generation
    busy = true
    var resultMessage: String?
    do {
      let _: SportsPreferences = try await client.request(
        "sports/preferences", method: "PUT", body: next)
    } catch {
      resultMessage =
        error as? PigTVError == .http(409)
        ? "Settings changed on another device. Current settings were reloaded; choose again to retry."
        : "Settings could not be saved. Current settings were reloaded."
    }
    guard generation == requestGeneration else { return }
    _ = await loadSnapshot(league: league, clear: true, completingSave: true)
    message = resultMessage
  }

  /// A menu/card stores only identities. Every action obtains a fresh authoritative projection.
  func event(gameID: String, channelKey: String? = nil, watch: Bool) async -> SportEvent? {
    #if DEBUG
      if fixture != nil, !fixtureServed {
        message = "Illustrative preview · playback and recording are disabled."
        return nil
      }
    #endif
    let actionInvalidation = invalidation
    guard let snapshot = await revalidate(),
      let game = snapshot.dashboard.games.first(where: { $0.id == gameID }),
      let event = game.actionableEvent(
        at: snapshot.eligibilityTime + elapsedMilliseconds(since: snapshot.receivedAt),
        channelKey: channelKey, watch: watch)
    else {
      message = "That airing is no longer available. Choose a current channel or event."
      return nil
    }
    if watch { return event }
    // C-O references can cover different airing windows on different channels.
    // Read their C-I association for recording/rules; keep the projected title, never raw guide prose.
    do {
      let guide: SportEventsResponse = try await client.decodedOffMain(
        "sports/events", query: [URLQueryItem(name: "hours", value: "72")])
      guard invalidation == actionInvalidation, !backgrounded, !Task.isCancelled,
        let chosen = event.best
      else { return nil }
      let now = snapshot.eligibilityTime + elapsedMilliseconds(since: snapshot.receivedAt)
      let references = Set(game.events.map(\.id))
      let candidates = guide.events.filter {
        references.contains($0.id) && $0.endTime > now
          && $0.channels.contains { $0.identityKey == chosen.identityKey }
      }
      .sorted { a, b in
        let aCurrent = a.startTime <= now
        let bCurrent = b.startTime <= now
        return aCurrent != bCurrent ? aCurrent : a.startTime < b.startTime
      }
      guard let airing = candidates.first,
        let channel = airing.channels.first(where: { $0.identityKey == chosen.identityKey })
      else {
        message = "That channel’s airing is no longer available. Choose a current event."
        return nil
      }
      return SportEvent(
        id: airing.id, title: game.title, league: game.league, startTime: airing.startTime,
        endTime: airing.endTime,
        channels: [channel] + event.channels.filter { $0.identityKey != channel.identityKey })
    } catch {
      message = "Could not revalidate that channel’s airing. Try again."
      return nil
    }
  }

  func keepFresh(league: String?, clear: Bool = false) async {
    async let scores: Void = keepScoresFresh(league: league, clear: clear)
    async let activity: Void = keepActivityFresh()
    _ = await (scores, activity)
  }

  private func keepActivityFresh() async {
    guard enabled, client.accountID != nil else { return }
    while !Task.isCancelled && !legacy {
      if !backgrounded { await refreshActivity() }
      do { try await Task.sleep(for: pollInterval) } catch { return }
    }
  }

  private func keepScoresFresh(league: String?, clear: Bool) async {
    _ = await load(league: league, clear: clear)
    while !Task.isCancelled && !legacy {
      do { try await Task.sleep(for: pollInterval) } catch { return }
      _ = await load(league: self.league)
    }
  }
}
