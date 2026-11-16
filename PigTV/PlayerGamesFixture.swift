#if DEBUG
import Foundation

/// #334 (PIGTV_UI_TEST_SCREEN=player-games): the Sport front answer behind the player's live games list, for the
/// simulators and UI tests: the game playing (followed, scored), another scored game, a game being recorded (its scores
/// sent, so they must not show), a race (no two sides) and a game at its break.
enum PlayerGamesFixture {
    static let playing = "fixture:nfl-gb-chi"

    static func front(now: Date = Date()) -> SportFront {
        let ms = now.timeIntervalSince1970 * 1000
        func channel(_ id: String, _ name: String) -> String {
            #"{"sourceId":1,"id":"\#(id)","name":"\#(name)","number":null,"logo":null,"quality":"HD","start":\#(ms - 3_600_000),"end":\#(ms + 3_600_000)}"#
        }
        func team(_ id: String, _ name: String, _ abbreviation: String?) -> String {
            #"{"id":"\#(id)","name":"\#(name)","logo":null\#(abbreviation.map { #","abbreviation":"\#($0)""# } ?? "")}"#
        }
        func game(_ id: String, league: String, title: String, status: String = "live", followed: Bool = false,
                  teams: [String], scores: [String]?, progress: String, channelID: String, channelName: String,
                  extra: String = "") -> String {
            let scoreText = scores.map { #","scores":[\#($0.map { "\"\($0)\"" }.joined(separator: ","))]"# } ?? ""
            return #"{"id":"\#(id)","league":"\#(league)","title":"\#(title)","start":\#(ms - 5_400_000),"status":"\#(status)","freshness":"fresh","progress":\#(progress),"availability":"matched","broadcastStatus":"on-tv","channels":[\#(channel(channelID, channelName))],"events":[],"canWatch":true,"competitors":[\#(teams.joined(separator: ","))],"followed":\#(followed)\#(scoreText)\#(extra)}"#
        }
        let games = [
            game(playing, league: "NFL", title: "Packers v Bears", followed: true,
                 teams: [team("9", "Green Bay Packers", "GB"), team("3", "Chicago Bears", "CHI")], scores: ["21", "17"],
                 progress: #"{"clock":"2:14","period":4}"#, channelID: "pos_3", channelName: "Sports One HD"),
            game("fixture:nba-lal-bos", league: "NBA", title: "Lakers v Celtics",
                 teams: [team("13", "Los Angeles Lakers", "LAL"), team("2", "Boston Celtics", "BOS")], scores: ["88", "84"],
                 progress: #"{"clock":"4:12","period":3}"#, channelID: "pos_4", channelName: "ESPN HD"),
            game("fixture:nfl-kc-buf", league: "NFL", title: "Chiefs v Bills",
                 teams: [team("12", "Kansas City Chiefs", "KC"), team("2", "Buffalo Bills", "BUF")], scores: ["10", "14"],
                 progress: #"{"clock":"8:40","period":2}"#, channelID: "pos_5", channelName: "Sports Two HD",
                 extra: #","recording":{"scheduleId":4,"status":"recording"}"#),
            game("fixture:f1-mex", league: "F1", title: "Mexico City Grand Prix", teams: [], scores: nil,
                 progress: "{}", channelID: "pos_6", channelName: "Motorsport HD", extra: #","session":"Race""#),
            game("fixture:epl-ars-che", league: "EPL", title: "Arsenal v Chelsea", status: "break",
                 teams: [team("359", "Arsenal", nil), team("363", "Chelsea", nil)], scores: ["1", "0"],
                 progress: #"{"clock":"45'","period":1}"#, channelID: "pos_7", channelName: "Football HD"),
        ]
        let sports = ["NFL", "NBA", "F1", "EPL"].map { #"{"league":"\#($0)","live":1,"next":null,"line":"live"}"# }
        let json = #"{"now":\#(ms),"spoilerFree":false,"scores":"fresh","sports":[\#(sports.joined(separator: ","))],"follows":[],"rails":[],"games":[\#(games.joined(separator: ","))]}"#
        do {
            return try JSONDecoder().decode(SportFront.self, from: Data(json.utf8))
        } catch {
            fatalError("PlayerGamesFixture: \(error)")
        }
    }
}
#endif
