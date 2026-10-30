#if DEBUG
import Foundation

// Offline F1 page (#21): PIGTV_UI_TEST_SCREEN=f1 (the weekend ahead: Mexico City, round 21), f1-live (Austin, the
// race on now with the starting grid), f1-spoilers (f1 with spoiler-free on and a driver followed). The data is the
// ESPN feed's own from 29–30 Oct 2026 (as the mock-ups), with session times moved around the simulator's clock.
enum F1PageFixtures {
    static func page(live: Bool, guide: [GuideChannel], now date: Date = Date()) -> F1Page {
        let now = (date.timeIntervalSince1970 / 300).rounded(.down) * 300_000
        let hour = 3_600_000.0
        func channel(_ index: Int, _ start: Double, _ end: Double) -> [SportEventChannel] {
            guard guide.indices.contains(index) else { return [] }
            let row = guide[index]
            return [SportEventChannel(sourceId: row.sourceId, rawID: row.rawID, stableId: row.stableId, name: row.name,
                                      number: row.number, logo: row.logo, quality: .uhd, startTime: start, endTime: end)]
        }
        let colours = ["Mercedes": "27F4D2", "Ferrari": "E8002D", "Red Bull": "3671C6", "McLaren": "FF8000",
                       "Racing Bulls": "6692FF", "Alpine": "0093CC", "Haas": "B6BABD", "Audi": "C9C9C9",
                       "Williams": "64C4FF", "Aston Martin": "229971"]
        let team = ["Kimi Antonelli": "Mercedes", "George Russell": "Mercedes", "Charles Leclerc": "Ferrari",
                    "Lewis Hamilton": "Ferrari", "Max Verstappen": "Red Bull", "Isack Hadjar": "Red Bull",
                    "Lando Norris": "McLaren", "Oscar Piastri": "McLaren", "Liam Lawson": "Racing Bulls",
                    "Arvid Lindblad": "Racing Bulls", "Pierre Gasly": "Alpine"]
        func rows(_ names: [String]) -> [F1ResultRow] {
            names.enumerated().map { F1ResultRow(pos: $0.offset + 1, driver: $0.element, team: team[$0.element],
                                                 teamColor: team[$0.element].flatMap { colours[$0] }) }
        }
        let standings = F1Standings(afterRound: 20,
            drivers: [("Kimi Antonelli", 365.0), ("George Russell", 242), ("Lewis Hamilton", 241), ("Max Verstappen", 236),
                      ("Charles Leclerc", 233), ("Lando Norris", 211), ("Oscar Piastri", 144), ("Isack Hadjar", 105),
                      ("Liam Lawson", 77), ("Pierre Gasly", 42)].enumerated().map {
                F1StandingRow(pos: $0.offset + 1, name: $0.element.0, team: team[$0.element.0],
                              teamColor: team[$0.element.0].flatMap { colours[$0] }, points: $0.element.1) },
            constructors: [("Mercedes", 607.0), ("Ferrari", 474), ("Red Bull", 355), ("McLaren", 355), ("Racing Bulls", 102),
                           ("Alpine", 69), ("Haas", 30), ("Audi", 23), ("Williams", 12), ("Aston Martin", 7)].enumerated().map {
                F1StandingRow(pos: $0.offset + 1, name: $0.element.0, teamColor: colours[$0.element.0], points: $0.element.1) })
        let info = F1CircuitInfo(length: live ? "5.513 km" : "4.304 km", laps: live ? 56 : 71, turns: live ? 20 : 17,
                                 lapRecord: live ? "1:36.169" : "1:17.774", lapRecordYear: 2021, map: nil)
        if live {
            let race = now - 0.7 * hour
            let sessions = [
                F1Session(id: "practice 1", name: "Practice 1", startTime: race - 50.5 * hour, endTime: race - 49.5 * hour, status: .done,
                          top: .init(kind: "fastest", driver: "Charles Leclerc")),
                F1Session(id: "practice 2", name: "Practice 2", startTime: race - 47 * hour, endTime: race - 46 * hour, status: .done,
                          top: .init(kind: "fastest", driver: "Charles Leclerc")),
                F1Session(id: "practice 3", name: "Practice 3", startTime: race - 26.5 * hour, endTime: race - 25.5 * hour, status: .done,
                          top: .init(kind: "fastest", driver: "Lewis Hamilton")),
                F1Session(id: "qualifying", name: "Qualifying", startTime: race - 23 * hour, endTime: race - 22 * hour, status: .done,
                          top: .init(kind: "pole", driver: "Kimi Antonelli")),
                F1Session(id: "race", name: "Race", startTime: race, endTime: race + 2 * hour, status: .live,
                          channels: channel(2, race - 0.5 * hour, race + 2.5 * hour) + channel(3, race, race + 2 * hour))
            ]
            return F1Page(available: true,
                          weekend: F1Weekend(round: 20, rounds: 25, name: "United States Grand Prix", circuit: "Circuit of the Americas",
                                             city: "Austin", country: "Texas", phase: .during, info: info, sessions: sessions),
                          results: F1Results(kind: "grid", title: "Starting grid · Qualifying",
                                             rows: rows(["Kimi Antonelli", "Max Verstappen", "Isack Hadjar", "Charles Leclerc", "Lewis Hamilton",
                                                         "George Russell", "Oscar Piastri", "Lando Norris", "Arvid Lindblad", "Liam Lawson"])),
                          standings: standings)
        }
        let p1 = now + 14 * hour
        let sessions = [
            F1Session(id: "practice 1", name: "Practice 1", startTime: p1, endTime: p1 + hour, status: .scheduled,
                      channels: channel(2, p1 - 0.5 * hour, p1 + hour)),
            F1Session(id: "practice 2", name: "Practice 2", startTime: p1 + 3.5 * hour, endTime: p1 + 4.5 * hour, status: .scheduled),
            F1Session(id: "practice 3", name: "Practice 3", startTime: p1 + 23 * hour, endTime: p1 + 24 * hour, status: .scheduled),
            F1Session(id: "qualifying", name: "Qualifying", startTime: p1 + 26.5 * hour, endTime: p1 + 27.5 * hour, status: .scheduled),
            F1Session(id: "race", name: "Race", startTime: p1 + 49.5 * hour, endTime: p1 + 51.5 * hour, status: .scheduled)
        ]
        return F1Page(available: true,
                      weekend: F1Weekend(round: 21, rounds: 25, name: "Mexico City Grand Prix", circuit: "Autódromo Hermanos Rodríguez",
                                         city: "Mexico City", country: "Mexico", phase: .before, info: info, sessions: sessions),
                      results: F1Results(kind: "race", title: "Last race · United States GP",
                                         rows: rows(["Kimi Antonelli", "Charles Leclerc", "Max Verstappen", "Lewis Hamilton", "Lando Norris",
                                                     "Isack Hadjar", "Oscar Piastri", "George Russell", "Liam Lawson", "Pierre Gasly"])),
                      standings: standings)
    }
}
#endif
