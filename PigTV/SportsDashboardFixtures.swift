#if DEBUG
  import Foundation

  /// Invented situations for acceptance, never a claim about current games or source-field availability.
  nonisolated enum SportsDashboardFixtures {
    static func response(hidden: Bool = false, delay: Int = 90, revision: Int = 0)
      -> SportsDashboard
    {
      let now = Date().timeIntervalSince1970 * 1000
      var games: [[String: Any]] = []
      let leagues = [
        "AFL", "NBA", "EPL", "FA Cup", "UEFA", "Championship", "NFL", "MLB", "Cricket", "F1",
      ]
      func add(
        _ league: String, _ suffix: String, _ state: String = "live", progress: [String: Any] = [:],
        situation: [String: Any] = [:], label: String? = nil, availability: String = "matched",
        freshness: String = "fresh", future: Bool = false
      ) {
        let start = now + (future ? 48 * 3_600_000 : -3_600_000)
        var g: [String: Any] = [
          "id": "fixture-\(league)-\(suffix)", "league": league,
          "title": "Illustrative \(league) event · \(suffix)", "start": start, "end": NSNull(),
          "session": NSNull(), "circuit": NSNull(), "format": NSNull(),
          "competitors": [
            ["id": "a", "name": "A very long home team name", "logo": NSNull()],
            ["id": "b", "name": "Visiting team", "logo": NSNull()],
          ],
          "status": state, "freshness": freshness, "progress": progress,
          "availability": availability, "broadcastStatus": future ? "scheduled" : "on-tv",
          "channels": availability == "matched"
            ? [["sourceId": 1, "id": "ch1", "stableId": "fixture1", "name": "Fixture Sports HD"]]
            : [],
          "events": [["id": "fixture-airing", "start": start, "end": start + 3 * 3_600_000]],
          "canWatch": false,
        ]
        if league == "F1" {
          g["competitors"] = []
          g["session"] = suffix
          g["circuit"] = [
            "name": "Illustrative circuit", "city": "Example", "country": "Australia",
          ]
        } else if !hidden && freshness == "fresh" && state != "scheduled" {
          g["scores"] =
            [
              "NFL": ["17", "14"], "MLB": ["3", "2"], "Cricket": ["329", "330/4 (90 ov)"],
              "EPL": ["2", "1"], "FA Cup": ["1", "1"], "UEFA": ["1", "1"],
            ][league] ?? ["101", "99"]
          g["situation"] = situation
        }
        if ["finished", "cancelled", "postponed"].contains(state) {
          g["channels"] = []
          g["availability"] = "unavailable"
          g["broadcastStatus"] = "unavailable"
        }
        if let label { g["breakLabel"] = label }
        games.append(g)
      }
      add("AFL", "basic points", progress: ["period": 3, "clock": "3:21"])
      if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_WATCHABLE"] == "1" { games[0]["canWatch"] = true }
      if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_PLAY"] == "1" {
        // A watchable game with a second (non-preferred) channel, played through the ordinary path.
        games[0]["canWatch"] = true
        games[0]["channels"] = [
          ["sourceId": 1, "id": "ch1", "stableId": "fixture1", "name": "Fixture Sports HD"],
          ["sourceId": 1, "id": "ch2", "stableId": "fixture2", "name": "Fixture Sports 2"],
        ]
      }
      add("AFL", "no channel", availability: "unmatched")
      add("AFL", "unavailable", availability: "unavailable")
      add("AFL", "buffering", "unknown", freshness: "buffering")
      add("AFL", "stale", "unknown", freshness: "stale")
      add("AFL", "final", "finished")
      add("AFL", "guide only", "unknown", freshness: "unavailable")
      games[games.count - 1]["dataSource"] = "guide"
      games[games.count - 1]["competitors"] = []
      games[games.count - 1]["title"] =
        hidden ? "AFL · Guide event" : "Illustrative regional fixture (guide only)"

      add("NBA", "overtime", progress: ["period": 5, "clock": "1:23"])
      add("EPL", "stoppage", progress: ["period": 2, "clock": "90+4"])
      add("FA Cup", "extra time", progress: ["period": 4, "clock": "117"])
      add("UEFA", "penalties", progress: ["period": 5])
      add("Championship", "postponed", "postponed")
      add(
        "NFL", "overtime", progress: ["period": 5, "clock": "8:15"],
        situation: ["down": 3, "distance": 7, "yardLine": 38])
      add(
        "MLB", "extra innings", progress: ["period": 11, "half": "top"],
        situation: ["balls": 2, "strikes": 1, "outs": 1, "onFirst": true])
      add("MLB", "suspended", "suspended", progress: ["period": 6, "half": "bottom"])
      for label in ["Stumps", "Rain delay", "Innings break"] {
        add("Cricket", label, "break", progress: ["day": "Day 2", "overs": "90"], label: label)
      }
      add("Cricket", "unknown format", availability: "unmatched")
      add("Cricket", "two days ahead", "scheduled", future: true)
      for session in ["Practice 1", "Practice 2", "Qualifying", "Sprint", "Race"] {
        add("F1", session, "scheduled", future: true)
      }
      let json: [String: Any] = [
        "now": now, "timezone": "Australia/Melbourne", "scope": "preview", "leagues": leagues,
        "preferences": ["avoidSpoilers": hidden, "scoreDelaySeconds": delay, "revision": revision],
        "games": games,
      ]
      return try! JSONDecoder().decode(
        SportsDashboard.self, from: JSONSerialization.data(withJSONObject: json))
    }
    /// The served fixture's C-I answer (`PIGTV_UI_TEST_DASHBOARD_PLAY`): each game's airings on all its channels, so
    /// the ordinary channel association runs. Matched games come first, as C-I lists only playable events.
    static func guide(for dashboard: SportsDashboard) -> [SportEvent] {
      dashboard.games.filter { !$0.channels.isEmpty }.flatMap { game in
        game.events.map {
          SportEvent(
            id: $0.id, title: game.title, league: game.league, startTime: $0.start, endTime: $0.end,
            channels: game.channels)
        }
      }
    }
  }
#endif
