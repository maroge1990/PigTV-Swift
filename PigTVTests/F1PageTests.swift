import XCTest
import SwiftUI
@testable import PigTV

private final class F1BundleToken {}

// C-P (#21): the Formula 1 page. `f1-page-0346.json` is the server's own answer (server 0346's sportPageF1 over its
// captured ESPN feed of 30 Oct 2026, the first session given one channel with its own airing), so the decoding is
// checked against what the server really sends. The presentation rules are pure (`F1PageText`).
final class F1PageTextTests: XCTestCase {
    static func fixture() throws -> Data {
        let bundle = Bundle(for: F1BundleToken.self)
        let enumerator = FileManager.default.enumerator(at: bundle.bundleURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "f1-page-0346.json" { return try Data(contentsOf: url) }
        }
        throw XCTSkip("f1-page-0346.json is not in the test bundle")
    }

    func testDecodesTheServersOwnAnswer() throws {
        let page = try JSONDecoder().decode(F1Page.self, from: Self.fixture())
        XCTAssertTrue(page.available)
        let weekend = try XCTUnwrap(page.weekend)
        XCTAssertEqual(weekend.name, "Mexico City Grand Prix")
        XCTAssertEqual(F1PageText.roundLine(weekend), "ROUND 21 OF 25")
        XCTAssertEqual(weekend.phase, .before)
        XCTAssertEqual(weekend.sessions.map(\.id), ["practice 1", "practice 2", "practice 3", "qualifying", "race"])
        XCTAssertEqual(weekend.sessions.map(\.status), Array(repeating: .scheduled, count: 5))
        XCTAssertEqual(weekend.info?.length, "4.304 km")
        XCTAssertEqual(weekend.info?.lapRecord, "1:17.774")
        XCTAssertNotNil(weekend.info?.map)
        let p1 = weekend.sessions[0]
        let channel = try XCTUnwrap(p1.channels.first)
        XCTAssertEqual(channel.name, "Fox Sports 506 HD")
        XCTAssertEqual(channel.startTime, p1.startTime - 1_800_000, "the channel's own airing (#20)")
        XCTAssertTrue(weekend.sessions.dropFirst().allSatisfy { $0.channels.isEmpty })
        let results = try XCTUnwrap(page.results)
        XCTAssertEqual(results.kind, "race")
        XCTAssertEqual(results.title, "Last race · United States GP")
        XCTAssertEqual(results.rows.count, 10)
        XCTAssertEqual(results.rows.first?.driver, "Kimi Antonelli")
        XCTAssertEqual(results.rows.first?.teamColor, "00D2BE")
        let standings = try XCTUnwrap(page.standings)
        XCTAssertEqual(standings.afterRound, 20)
        XCTAssertEqual(standings.drivers.count, 10)
        XCTAssertEqual(standings.constructors.count, 10)
        XCTAssertNotNil(standings.drivers.first?.points)
        XCTAssertEqual(F1PageText.standingsNote(standings, weekend: weekend), "After round 20 of 25")
    }

    func testDecodesTolerantly() throws {
        let notYet = try JSONDecoder().decode(F1Page.self, from: Data(#"{"available":false}"#.utf8))
        XCTAssertFalse(notYet.available)
        XCTAssertNil(notYet.weekend)
        let odd = #"""
        {"available":true,"weekend":{"round":null,"name":"Las Vegas Grand Prix","phase":"warp","info":null,
          "sessions":[{"id":"race","name":"Race","start":2000,"end":1000,"status":"done","top":{"kind":"winner","driver":"Lando Norris"}},
                      {"id":"practice 1","start":"soon"},{"id":"practice 2","name":"Practice 2","start":1000,"status":"later",
                       "channels":[{"sourceId":1,"id":7,"name":"Seven"},{"name":"broken"}]}]},
         "results":{"kind":"race","title":"Last race","rows":[{"pos":1,"driver":"A"},{"pos":"x"}]},"standings":null}
        """#
        let page = try JSONDecoder().decode(F1Page.self, from: Data(odd.utf8))
        let weekend = try XCTUnwrap(page.weekend)
        XCTAssertEqual(weekend.phase, .before, "an unknown phase reads as before")
        XCTAssertNil(F1PageText.roundLine(weekend))
        XCTAssertEqual(weekend.sessions.map(\.id), ["practice 2", "race"], "the broken session is dropped; in time order")
        XCTAssertEqual(weekend.sessions[0].status, .scheduled)
        XCTAssertEqual(weekend.sessions[0].channels.map(\.name), ["Seven"])
        XCTAssertEqual(weekend.sessions[1].endTime, 2000 + 3_600_000, "an end before the start is replaced")
        XCTAssertEqual(page.results?.rows.map(\.driver), ["A"])
        XCTAssertNil(page.standings)
        XCTAssertEqual(F1PageText.stats(nil).map(\.value), ["—", "—", "—", "—"])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func weekend(_ statuses: [(F1Session.Status, Double)], top: F1Session.Top? = nil) -> F1Weekend {
        let names = ["Practice 1", "Practice 2", "Qualifying", "Race"]
        let sessions = statuses.enumerated().map { index, item in
            let start = (now.timeIntervalSince1970 + item.1) * 1000
            return F1Session(id: names[index].lowercased(), name: names[index], startTime: start, endTime: start + 3_600_000,
                             status: item.0, top: item.0 == .done ? top : nil)
        }
        return F1Weekend(round: 21, rounds: 25, name: "Mexico City Grand Prix", circuit: "Autódromo Hermanos Rodríguez",
                         city: "Mexico City", country: "Mexico", phase: .before, info: nil, sessions: sessions)
    }

    func testBeforeTheWeekendTheFirstSessionIsNext() {
        let w = weekend([(.scheduled, 14 * 3600), (.scheduled, 18 * 3600), (.scheduled, 40 * 3600), (.scheduled, 60 * 3600)])
        XCTAssertEqual(F1PageText.focusSession(w, now: now)?.id, "practice 1")
        XCTAssertEqual(w.sessions.map { F1PageText.pill($0, in: w, now: now, spoilerFree: false) }, [.next, .none, .none, .none])
        XCTAssertTrue(F1PageText.headline(w, now: now).hasPrefix("Practice 1 in 14 h · "))
        XCTAssertEqual(F1PageText.placeLine(w), "Autódromo Hermanos Rodríguez · Mexico City, Mexico")
    }

    func testDuringTheWeekendDoneSessionsNameTheirDriverUnlessSpoilerFree() {
        let w = weekend([(.done, -48 * 3600), (.done, -24 * 3600), (.done, -3 * 3600), (.live, -600)],
                        top: .init(kind: "pole", driver: "Kimi Antonelli"))
        XCTAssertEqual(F1PageText.focusSession(w, now: now)?.id, "race")
        XCTAssertEqual(F1PageText.pill(w.sessions[2], in: w, now: now, spoilerFree: false), .done("Pole · Antonelli"))
        XCTAssertEqual(F1PageText.pill(w.sessions[2], in: w, now: now, spoilerFree: true), .done("Finished"),
                       "spoiler-free hides who took pole")
        XCTAssertEqual(F1PageText.pill(w.sessions[3], in: w, now: now, spoilerFree: true), .live)
        XCTAssertEqual(F1PageText.headline(w, now: now), "Race is live")
    }

    func testTheClockMakesASessionLiveBeforeTheFeedDoes() {
        // ESPN lags a few minutes: inside its time a "scheduled" session is live; past its end it is finished.
        let w = weekend([(.scheduled, -300), (.scheduled, -5 * 3600)])
        XCTAssertEqual(F1PageText.pill(w.sessions[0], in: w, now: now, spoilerFree: false), .live)
        XCTAssertEqual(F1PageText.pill(w.sessions[1], in: w, now: now, spoilerFree: false), .done("Finished"))
        let over = weekend([(.done, -48 * 3600), (.done, -3 * 3600)])
        XCTAssertNil(F1PageText.focusSession(over, now: now))
        XCTAssertEqual(F1PageText.headline(over, now: now), "Weekend finished")
    }

    func testASessionIsASportEventOnItsChannelsOwnTimes() throws {
        let start = now.timeIntervalSince1970 * 1000 + 3_600_000
        let channel = SportEventChannel(sourceId: 1, rawID: "506", name: "Fox Sports 506", startTime: start - 1_800_000, endTime: start + 3_600_000)
        let session = F1Session(id: "practice 1", name: "Practice 1", startTime: start, endTime: start + 3_600_000, status: .scheduled,
                                channels: [channel])
        let w = F1Weekend(round: 21, rounds: 25, name: "Mexico City Grand Prix", circuit: nil, city: nil, country: nil,
                          phase: .before, info: nil, sessions: [session])
        let event = F1PageText.event(session, in: w)
        XCTAssertEqual(event.title, "Mexico City GP · Practice 1")
        XCTAssertEqual(event.league, "F1")
        XCTAssertEqual(event.id, "f1:21:practice 1")
        XCTAssertEqual(event.programme(on: channel).startTime, start - 1_800_000, "Record takes the channel's pre-show too")
    }

    func testFollowableDriversAndPoints() {
        let page = F1Page(available: true, results: F1Results(kind: "race", title: "Last race", rows: [
            F1ResultRow(pos: 1, driver: "Kimi Antonelli"), F1ResultRow(pos: 2, driver: "Arvid Lindblad")]),
            standings: F1Standings(afterRound: 20, drivers: [F1StandingRow(pos: 1, name: "Kimi Antonelli", points: 365)], constructors: []))
        XCTAssertEqual(F1PageText.drivers(page), ["Kimi Antonelli", "Arvid Lindblad"])
        XCTAssertEqual(F1PageText.points(365), "365")
        XCTAssertEqual(F1PageText.points(12.5), "12.5")
        XCTAssertEqual(F1PageText.points(nil), "")
        XCTAssertNil(Color(teamHex: "nope"))
        XCTAssertNotNil(Color(teamHex: "00D2BE"))
    }

    func testPreferencesRoundTrip() throws {
        let decoded = try JSONDecoder().decode(SportPagePreferences.self,
                                               from: Data(#"{"spoilerFree":true,"following":{"F1":"Oscar Piastri"}}"#.utf8))
        XCTAssertEqual(decoded, SportPagePreferences(spoilerFree: true, f1Following: "Oscar Piastri"))
        let none = try JSONDecoder().decode(SportPagePreferences.self, from: Data(#"{"spoilerFree":false,"following":{"F1":null}}"#.utf8))
        XCTAssertNil(none.f1Following)
        let again = try JSONDecoder().decode(SportPagePreferences.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }
}

/// The model against a local server: the page and the household's preferences load; a change is sent as only its
/// own field; a refused change is put back; an older server (no preferences route) keeps them on the device.
@MainActor
final class F1PageModelTests: XCTestCase {
    private func server(preferences: Int = 200, put: Int = 200) throws -> (LocalHTTPServer, Locked<[Data]>) {
        let puts = Locked<[Data]>([])
        let page = try F1PageTextTests.fixture()
        let http = try LocalHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/sports/pages/f1"):
                return .init(status: 200, contentType: "application/json", body: page)
            case ("GET", "/api/sports/pages/preferences"):
                return preferences == 200 ? .json(#"{"spoilerFree":false,"following":{"F1":"Lando Norris"}}"#) : .json(#"{"error":"x"}"#, status: preferences)
            case ("PUT", "/api/sports/pages/preferences"):
                puts.value.append(request.body)
                return put == 200 ? .json(#"{"spoilerFree":true,"following":{"F1":"Lando Norris"}}"#) : .json(#"{"error":"x"}"#, status: put)
            default:
                return .notFound
            }
        }
        return (http, puts)
    }

    private func defaults() -> UserDefaults {
        let suite = "F1PageModelTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testLoadsThePageAndTheHouseholdsPreferences() async throws {
        let (http, puts) = try server()
        defer { http.stop() }
        let model = F1PageModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), defaults: defaults())
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.page?.weekend?.name, "Mexico City Grand Prix")
        XCTAssertEqual(model.preferences.f1Following, "Lando Norris")
        await model.setSpoilerFree(true)
        XCTAssertTrue(model.preferences.spoilerFree)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(puts.value.first)) as? [String: Any]
        XCTAssertEqual(body?.keys.sorted(), ["spoilerFree"], "only the switch is sent, never a stale copy of the rest")
        XCTAssertEqual(body?["spoilerFree"] as? Bool, true)
    }

    func testARefusedChangeIsPutBack() async throws {
        let (http, _) = try server(put: 500)
        defer { http.stop() }
        let model = F1PageModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), defaults: defaults())
        await model.load()
        await model.setFollowing("Oscar Piastri")
        XCTAssertEqual(model.preferences.f1Following, "Lando Norris", "the server's value stays")
        XCTAssertNotNil(model.saveError)
    }

    func testAnOlderServerKeepsThemOnTheDevice() async throws {
        let (http, puts) = try server(preferences: 404)
        defer { http.stop() }
        let store = defaults()
        let client = APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1)
        let model = F1PageModel(client: client, defaults: store)
        await model.load()
        XCTAssertEqual(model.preferences, SportPagePreferences())
        await model.setFollowing("Oscar Piastri")
        XCTAssertTrue(puts.value.isEmpty, "nothing is sent to a server without the route")
        let again = F1PageModel(client: client, defaults: store)
        await again.load()
        XCTAssertEqual(again.preferences.f1Following, "Oscar Piastri", "kept on this device")
    }
}
