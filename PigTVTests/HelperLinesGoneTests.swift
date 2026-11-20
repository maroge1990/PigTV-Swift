import Foundation
import XCTest

/// maroge1990/PigTV#341: lines that repeat what the control already says are gone. The source is checked, as in
/// SelectionFlatTests: none of these strings may come back into the app's views.
final class HelperLinesGoneTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PigTV")

    private static let removed = [
        "Clocks and scores follow it", "0–300 seconds", "Select one to change its leagues and teams",
        "your order, playing now on top", "Hidden while Hide scores is on", "Hide scores is on",
        "reveal results while", "Never replays", "never replays", "channels in your guide carry it",
        "Same times", "Best channel", "Else the guide end", "every provider connection is in use",
        "once it's listed in the TV guide", "with the usual padding", "Start early, finish late",
        "Still recording: watch it from the start", "Playback is available once", "Plays once it has finished",
        "You can cancel and try again", "Undo for 10 seconds", "Long press for options", "Touch and hold for options",
        "Select a programme on now", "Choices: System, Light, Dark", "Hide scores and your sport", "Scores are \\(",
        // #358 (Mark's final record page: no descriptive text; Start early shows "Started" once it records)
        "When it stops", "When the game ends (ESPN)", "Repeats as well", "Changes apply to this recording only.",
        "It is recording: only Finish late can change.",
    ]

    func testTheHelperLinesAreGone() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        var found: [String] = []
        for name in names {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for string in Self.removed where line.contains(string) { found.append("\(name): \(string)") }
            }
        }
        XCTAssertEqual(found, [], "helper lines that repeat the control are gone (#341)")
    }

    func testTheKeptLinesStay() throws {
        let record = try String(contentsOf: Self.sources.appendingPathComponent("RecordPage.swift"), encoding: .utf8)
        for kept in ["It has started: only the rest of it is recorded."] {
            XCTAssertTrue(record.contains(kept), kept)
        }
    }
}
