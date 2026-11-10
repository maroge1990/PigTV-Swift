import XCTest
@testable import PigTV

/// The preferences route as scripted: GET answers the stored value; PUT answers `putStatus` (200 stores the change).
private final class PreferencesRoutes: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var stored = #"{"avoidSpoilers":false,"scoreDelaySeconds":30,"revision":3}"#
    nonisolated(unsafe) static var putStatus = 200
    nonisolated(unsafe) static var puts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var status = 200
        if request.httpMethod == "PUT" {
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data()
            Self.puts.append(String(decoding: body, as: UTF8.self))
            status = Self.putStatus
            if status == 200, let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let seconds = sent["scoreDelaySeconds"] as? Int, let revision = sent["revision"] as? Int {
                Self.stored = #"{"avoidSpoilers":false,"scoreDelaySeconds":\#(seconds),"revision":\#(revision + 1)}"#
            }
        }
        let reply = status == 200 ? Data(Self.stored.utf8) : Data(#"{"error":"revision"}"#.utf8)
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// D-44 batch 6 (Apple 130): Settings › Sport's Score delay (C-O `sports/preferences`) and the logos beside your sports.
@MainActor
final class SettingsSportTests: XCTestCase {
    private func setting() throws -> ScoreDelaySetting {
        PreferencesRoutes.stored = #"{"avoidSpoilers":false,"scoreDelaySeconds":30,"revision":3}"#
        PreferencesRoutes.putStatus = 200
        PreferencesRoutes.puts = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreferencesRoutes.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(
            #"{"name":"PigTV","version":"3.9.0","build":"0444","apiVersion":1,"features":{"sportFront":true}}"#.utf8))
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration), info: info)
        return ScoreDelaySetting(client: client)
    }

    func testTheDelayStepsInTensWithinZeroToThreeHundred() {
        XCTAssertEqual(ScoreDelay.stepped(30, by: 10), 40)
        XCTAssertEqual(ScoreDelay.stepped(5, by: -10), 0)
        XCTAssertEqual(ScoreDelay.stepped(295, by: 10), 300)
        XCTAssertEqual(ScoreDelay.text(30), "30 s")
    }

    func testAStepSavesWithTheRevisionItRead() async throws {
        let delay = try setting()
        await delay.load()
        XCTAssertEqual(delay.preferences?.scoreDelaySeconds, 30)
        await delay.step(10)
        XCTAssertEqual(PreferencesRoutes.puts.count, 1)
        let sent = try JSONSerialization.jsonObject(with: Data(PreferencesRoutes.puts[0].utf8)) as? [String: Any]
        XCTAssertEqual(sent?["revision"] as? Int, 3)
        XCTAssertEqual(sent?["scoreDelaySeconds"] as? Int, 40)
        XCTAssertNil(sent?["avoidSpoilers"], "only the delay is sent")
        XCTAssertEqual(delay.preferences?.scoreDelaySeconds, 40)
        XCTAssertEqual(delay.preferences?.revision, 4)
        XCTAssertEqual(delay.message, "")
    }

    func testARefusedStepReadsTheDelayAgainAndSaysSo() async throws {
        let delay = try setting()
        await delay.load()
        PreferencesRoutes.stored = #"{"avoidSpoilers":false,"scoreDelaySeconds":120,"revision":9}"#
        PreferencesRoutes.putStatus = 409
        await delay.step(-10)
        XCTAssertEqual(delay.preferences?.scoreDelaySeconds, 120, "the value now on the server")
        XCTAssertEqual(delay.message, "Changed on another device: this is the delay now.")
    }

    func testFollowedNamesTakeTheFrontPagesCachedLogosElseAMonogram() throws {
        let follows = try JSONDecoder().decode([SportFront.Follow].self, from: Data(#"""
        [{"league":"Premier League","name":"Liverpool","logo":"/api/logo/abc","state":"none","sport":"Football"},
         {"league":"NRL","name":"Arsenal","logo":"/api/logo/zzz","state":"none","sport":"Rugby league"},
         {"league":"Cricket","name":"Australia","logo":"https://elsewhere.example/a.png","state":"none"}]
        """#.utf8))
        let football = SportFollows.Entry(sport: "Football", leagues: ["Premier League"], teams: ["liverpool", "Arsenal"])
        XCTAssertEqual(SettingsSportLogos.names(football, follows: follows),
                       [.init(name: "liverpool", logo: "/api/logo/abc"), .init(name: "Arsenal", logo: nil)],
                       "matched by name in the same sport; another sport's Arsenal is not this one")
        let cricket = SportFollows.Entry(sport: "Cricket", leagues: ["Cricket"], teams: ["Australia"])
        XCTAssertEqual(SettingsSportLogos.names(cricket, follows: follows), [.init(name: "Australia", logo: nil)],
                       "an older server's follow matches by league; only same-server cached logos are drawn")
    }
}
