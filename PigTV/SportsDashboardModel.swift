import Combine
import Foundation

/// Ephemeral, per authenticated APIClient. Never persist a score or preference on this device.
@MainActor
final class SportsDashboardModel: ObservableObject {
  let client: APIClient
  private let refreshActivity: @MainActor () async -> Void
  @Published private(set) var dashboard: SportsDashboard?
  @Published private(set) var legacy = false
  @Published private(set) var message: String?
  @Published private(set) var busy = false
  private var generation = 0
  private var eligibilityTime: Double?
  private var receivedAt: ContinuousClock.Instant?
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
  #endif
  init(client: APIClient, refreshActivity: @escaping @MainActor () async -> Void = {}) {
    self.client = client
    self.refreshActivity = refreshActivity
    #if DEBUG
      if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "sport-dashboard" {
        fixture = SportsDashboardFixtures.response(
          hidden: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SPOILERS"] == "hidden")
        dashboard = fixture
      }
    #endif
  }

  /// Invalidate before backgrounding/resume, changing identity/scope or saving preferences.
  /// Late responses and already-open details cannot resurrect a previously revealed score.
  func hide() {
    generation += 1
    dashboard = nil
    eligibilityTime = nil
    receivedAt = nil
    busy = false
  }

  func sceneActive(_ active: Bool) {
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
      if let fixture {
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
      let response: SportsDashboard = try await client.decodedOffMain(
        "sports/dashboard",
        query: league.map { [URLQueryItem(name: "league", value: $0)] } ?? [])
      guard generation == requestGeneration, !Task.isCancelled else { return false }
      // Only airing eligibility ages locally. The displayed delayed game state never ticks.
      // Use the full round-trip as a conservative bound on response transit, with a monotonic clock.
      eligibilityTime = response.now + elapsedMilliseconds(since: startedAt)
      receivedAt = ContinuousClock.now
      dashboard = response
      return true
    } catch {
      guard generation == requestGeneration else { return false }
      dashboard = nil
      if error as? PigTVError == .http(404) {
        legacy = true
      } else if !(error is CancellationError) {
        message = "Sports data unavailable. Reconnect and try again."
      }
      return false
    }
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
      if fixture != nil {
        message = "Illustrative preview · playback and recording are disabled."
        return nil
      }
    #endif
    guard await load(league: league), let dashboard, let eligibilityTime, let receivedAt,
      let game = dashboard.games.first(where: { $0.id == gameID }),
      let event = game.actionableEvent(
        at: eligibilityTime + elapsedMilliseconds(since: receivedAt), channelKey: channelKey,
        watch: watch)
    else {
      message = "That airing is no longer available. Choose a current channel or event."
      return nil
    }
    if watch { return event }
    // C-O references can cover different airing windows on different channels.
    // Read their C-I association for recording/rules; keep the projected title, never raw guide prose.
    let actionGeneration = generation
    do {
      let guide: SportEventsResponse = try await client.decodedOffMain(
        "sports/events", query: [URLQueryItem(name: "hours", value: "72")])
      guard generation == actionGeneration, !backgrounded, !Task.isCancelled,
        let chosen = event.best
      else { return nil }
      let now = eligibilityTime + elapsedMilliseconds(since: receivedAt)
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

  func keepFresh(league: String?, clear: Bool = true) async {
    async let scores: Void = keepScoresFresh(league: league, clear: clear)
    async let activity: Void = keepActivityFresh()
    _ = await (scores, activity)
  }

  private func keepActivityFresh() async {
    guard enabled, client.accountID != nil else { return }
    while !Task.isCancelled && !legacy {
      if !backgrounded { await refreshActivity() }
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
    }
  }

  private func keepScoresFresh(league: String?, clear: Bool) async {
    _ = await load(league: league, clear: clear)
    while !Task.isCancelled && !legacy {
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      _ = await load(league: self.league)
    }
  }
}
