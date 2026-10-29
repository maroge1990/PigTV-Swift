import Foundation

/// C-O is a complete server-projected delayed state. Never tick its game clocks locally.
nonisolated struct SportsPreferences: Codable, Equatable, Sendable {
  var avoidSpoilers: Bool
  var scoreDelaySeconds: Int
  var revision: Int
}

nonisolated struct SportsDashboard: Decodable, Sendable {
  let now: Double
  let timezone: String
  let scope: String
  let preferences: SportsPreferences
  let games: [SportsGame]
  let leagues: [String]?
}

nonisolated struct SportsGame: Decodable, Identifiable, Equatable, Sendable {
  let id: String
  let league: String
  let title: String
  let start: Double
  let end: Double?
  let session: String?
  let circuit: Circuit?
  let format: String?
  let competitors: [Competitor]
  let status: String
  let freshness: String
  let progress: Progress
  let scores: [String]?
  let situation: Situation?
  let breakLabel: String?
  let availability: String
  let broadcastStatus: String
  let channels: [SportEventChannel]
  let events: [Airing]
  let canWatch: Bool
  let dataSource: String?

  struct Competitor: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let logo: String?
    /// Only use cached same-server logos. Never fetch source URLs from a card.
    var cachedLogo: String? {
      logo.flatMap {
        $0.hasPrefix("/api/logo/") && !$0.contains("?") && !$0.contains("..") ? $0 : nil
      }
    }
  }
  struct Circuit: Decodable, Equatable, Sendable {
    let name: String
    let city: String?
    let country: String?
  }
  struct Progress: Decodable, Equatable, Sendable {
    let clock: String?
    let period: Int?
    let half: String?
    let day: String?
    let overs: String?
  }
  struct Situation: Decodable, Equatable, Sendable {
    let down: Int?
    let distance: Int?
    let yardLine: Int?
    let possession: String?
    let balls: Int?
    let strikes: Int?
    let outs: Int?
    let onFirst: Bool?
    let onSecond: Bool?
    let onThird: Bool?
  }
  struct Airing: Decodable, Equatable, Sendable {
    let id: String
    let start: Double
    let end: Double
  }

  enum Family: String, CaseIterable, Sendable {
    case australianFootball, basketball, football, americanFootball, baseball, cricket, motorsport,
      guide
  }
  var family: Family {
    switch league {
    case "AFL", "AFLW": .australianFootball
    case "NBA": .basketball
    case "EPL", "FA Cup", "UEFA", "Championship": .football
    case "NFL": .americanFootball
    case "MLB": .baseball
    case "Cricket": .cricket
    case "F1": .motorsport
    default: .guide
    }
  }
  var terminal: Bool { ["finished", "cancelled", "postponed"].contains(status) }
  var statusLabel: String {
    switch status {
    case "finished": "FINAL"
    case "cancelled": "CANCELLED"
    case "postponed": "POSTPONED"
    case "suspended": "SUSPENDED"
    case "break": breakLabel ?? "BREAK"
    case "live" where freshness == "fresh": "LIVE"
    case "scheduled": "UPCOMING"
    default:
      broadcastStatus == "on-tv"
        ? "ON TV NOW" : freshness == "buffering" ? "BUFFERING" : "STATUS UNAVAILABLE"
    }
  }
  var availabilityLabel: String {
    if status == "finished" { return "Event ended · playback unavailable" }
    if availability == "unmatched" { return "No channel found" }
    if availability == "unavailable" { return "Channel unavailable" }
    return channels.first?.name ?? "No channel found"
  }
  /// The same strings feed sighted and accessible content, with no raw status prose.
  func progressLabel() -> String {
    guard freshness == "fresh", family != .motorsport else { return "" }
    var parts: [String] = []
    if let period = progress.period, period > 0 {
      switch family {
      case .australianFootball:
        parts.append(period <= 4 ? "Quarter \(period)" : "Extra time \(period - 4)")
      case .basketball, .americanFootball:
        parts.append(period <= 4 ? "Quarter \(period)" : "Overtime \(period - 4)")
      case .football:
        parts.append(
          [
            1: "First half", 2: "Second half", 3: "Extra time · first half",
            4: "Extra time · second half", 5: "Penalties",
          ][period] ?? "Period \(period)")
      case .baseball: parts.append("\(progress.half?.capitalized ?? "Inning") \(period)")
      default: break
      }
    }
    if let clock = progress.clock { parts.append(clock) }
    if family == .cricket {
      if let format { parts.append(format.uppercased()) }
      if let day = progress.day { parts.append(day) }
      if let overs = progress.overs { parts.append("\(overs) overs") }
    }
    return parts.joined(separator: " · ")
  }
  func visibleScores(hidden: Bool) -> [String]? {
    guard !hidden, freshness == "fresh", family != .motorsport, scores?.count == 2 else {
      return nil
    }
    return scores
  }
  func situationLabel(hidden: Bool) -> String? {
    guard !hidden, freshness == "fresh", let situation else { return nil }
    if family == .americanFootball {
      var parts: [String] = []
      if let down = situation.down, let distance = situation.distance {
        parts.append("Down \(down) · \(distance) yards")
      }
      if let yard = situation.yardLine { parts.append("Yard line \(yard)") }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    if family == .baseball {
      var parts: [String] = []
      if let balls = situation.balls, let strikes = situation.strikes {
        parts.append("\(balls) balls · \(strikes) strikes")
      }
      if let outs = situation.outs { parts.append("\(outs) outs") }
      let bases = [
        ("First", situation.onFirst), ("Second", situation.onSecond), ("Third", situation.onThird),
      ].compactMap { $0.1 == true ? $0.0 : nil }
      if !bases.isEmpty { parts.append("On base: " + bases.joined(separator: ", ")) }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    return nil
  }
  /// Use only the fresh response's airing bounds and channel order; no 5-minute early-tune grace.
  func actionableEvent(at now: Double, channelKey: String? = nil, watch: Bool) -> SportEvent? {
    guard !terminal else { return nil }
    let eligible = events.filter { $0.end > now && (watch ? $0.start <= now : true) }
    guard !watch || canWatch, let airing = eligible.first else { return nil }
    let selected =
      channelKey.flatMap { key in channels.first { $0.identityKey == key } }
      ?? (channelKey == nil ? channels.first : nil)
    guard let selected else { return nil }
    let ordered = [selected] + channels.filter { $0.identityKey != selected.identityKey }
    return SportEvent(
      id: airing.id, title: title, league: league, startTime: airing.start, endTime: airing.end,
      channels: ordered)
  }
}

/// Covers containing a captured guide title cannot outlive the preferences used to construct it.
nonisolated enum SportsPresentationPolicy {
  static func canRender(storedRevision: Int, current: SportsPreferences?) -> Bool {
    current?.revision == storedRevision
  }
}
