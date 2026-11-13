import SwiftUI
import XCTest
@testable import PigTV

/// maroge1990/PigTV#310 (iPad; the card is shared with Apple TV and iPhone): a game card with a record mark was taller than
/// the others, because the mark was a row of the card. Every record mark is now an icon in the card's top-trailing corner, so
/// a card with a mark must measure exactly as a card without one, at the card width of the platform.
@MainActor
final class SportCardMarkSizeTests: XCTestCase {
    private func height(_ game: SportsGame, front: SportFront) -> CGFloat {
        let card = SportGameCard(game: game, front: front, hidden: false, now: Date(timeIntervalSince1970: front.now / 1000),
                                 client: nil, onSelect: {})
        let host = UIHostingController(rootView: card)
        return host.sizeThatFits(in: CGSize(width: SportCardMetrics.width, height: 3_000)).height
    }

    func testARecordMarkDoesNotChangeTheCardsSize() throws {
        let front = try SportFrontLayoutTests.front()
        let game = try XCTUnwrap(front.games.first { $0.competitors.count == 2 && $0.recording == nil && $0.recordWhenListed == nil })
        let plain = height(game, front: front)
        XCTAssertGreaterThan(plain, 0)

        var recording = game
        recording.recording = .init(scheduleId: 1, status: "recording")
        var set = game
        set.recording = .init(scheduleId: 2, status: "scheduled", ruleId: 4)
        var clash = game
        clash.recording = .init(scheduleId: 3, status: "scheduled", clashesWith: ["Evening Match"])
        var waiting = game
        waiting.recordWhenListed = .init(ruleId: 12)
        for (name, marked) in [("recording", recording), ("set to record", set), ("clash", clash), ("records when listed", waiting)] {
            XCTAssertEqual(height(marked, front: front), plain, accuracy: 0.5, "a card that is \(name) is as tall as one that is not")
        }
    }

    func testASessionCardWithAMarkKeepsItsSize() throws {
        let front = try SportFrontLayoutTests.front()
        guard let game = front.games.first(where: { $0.competitors.count != 2 && $0.recording == nil }) else {
            throw XCTSkip("no session card in the fixture")
        }
        var marked = game
        marked.recording = .init(scheduleId: 1, status: "scheduled", clashesWith: ["Evening Match"])
        XCTAssertEqual(height(marked, front: front), height(game, front: front), accuracy: 0.5)
    }
}
