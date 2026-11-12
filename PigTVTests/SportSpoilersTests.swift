import Foundation
import XCTest
@testable import PigTV

/// #278 (audit D5): "are scores hidden on this screen?" has one answer, `SportSpoilers.hidden`. Before, nine places
/// decided it with three expressions, and the Apple TV front page read the account's preference alone (its header chip
/// said "Scores shown" while the answer said spoiler-free).
@MainActor
final class SportSpoilersTests: XCTestCase {

    // MARK: The rule

    func testAnyInputSayingHiddenHides() {
        for preference in [false, true] {
            for answer in [false, true] {
                for page in [false, true] {
                    XCTAssertEqual(SportSpoilers.hidden(preference: preference, answer: answer, page: page),
                                   preference || answer || page,
                                   "preference \(preference), answer \(answer), page \(page)")
                }
            }
        }
        XCTAssertFalse(SportSpoilers.hidden(preference: false, answer: false, page: false), "only all three off shows scores")
    }

    func testNoAnswerYetAddsNothingByItself() {
        XCTAssertFalse(SportSpoilers.hidden(preference: false, answer: nil, page: false))
        XCTAssertTrue(SportSpoilers.hidden(preference: true, answer: nil, page: false), "unknown preference counts as hidden")
        XCTAssertTrue(SportSpoilers.hidden(preference: false, answer: nil, page: true))
    }

    // MARK: The Apple TV front page

    private func front(spoilerFree: Bool) throws -> SportFront {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SportFrontTests.fixture()) as? [String: Any])
        json["spoilerFree"] = spoilerFree
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The preference known and off, the answer spoiler-free: the page hides scores, and its header chip says so.
    func testTVFrontPageHonoursTheAnswersSpoilerFree() throws {
        let hiddenFront = try front(spoilerFree: true)
        let decision = SportFrontTVPage.scoresHidden(preference: false, front: hiddenFront)
        XCTAssertTrue(decision, "the answer says spoiler-free: the Apple TV front page must hide scores")
        XCTAssertEqual(SportPhoneLayout.scoresChip(hidden: decision), "Scores hidden", "the header chip")

        XCTAssertFalse(SportFrontTVPage.scoresHidden(preference: false, front: try front(spoilerFree: false)))
        XCTAssertTrue(SportFrontTVPage.scoresHidden(preference: true, front: try front(spoilerFree: false)))
        XCTAssertFalse(SportFrontTVPage.scoresHidden(preference: false, front: nil))
        XCTAssertTrue(SportFrontTVPage.scoresHidden(preference: true, front: nil), "unknown preference, no answer yet")
    }

    /// The hero's line through the page's decision: the score and situation shown when nothing hides them, withheld
    /// when the answer is spoiler-free with the preference off.
    func testTVFrontHeroWithholdsTheScoreThroughThePagesDecision() throws {
        let shownFront = try front(spoilerFree: false)
        let game = try XCTUnwrap(shownFront.game(SportFrontTests.packers))
        let shown = SportFrontLayout.hero(game, in: shownFront,
                                          hidden: SportFrontTVPage.scoresHidden(preference: false, front: shownFront), now: Date())
        XCTAssertTrue(shown.line.contains("7–3"), "control: the score shows with nothing hiding it (\(shown.line))")

        let hiddenFront = try front(spoilerFree: true)
        let hiddenGame = try XCTUnwrap(hiddenFront.game(SportFrontTests.packers))
        let hidden = SportFrontLayout.hero(hiddenGame, in: hiddenFront,
                                           hidden: SportFrontTVPage.scoresHidden(preference: false, front: hiddenFront), now: Date())
        XCTAssertFalse(hidden.line.contains("7–3"), hidden.line)
        XCTAssertFalse(hidden.line.contains("Down"), "no situation: \(hidden.line)")
    }

    // MARK: Read from one place

    private struct Line { let file: String; let number: Int; let text: String }

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PigTV")

    /// Every `PigTV/*.swift` line with `//` comments dropped, except the function's own definition.
    private func sourceLines() throws -> [Line] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 50, "the PigTV sources were not found at \(Self.sources.path)")
        return try names.flatMap { name -> [Line] in
            let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
            var inDefinition = false
            return text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
                if raw.hasPrefix("nonisolated enum SportSpoilers") || raw.hasPrefix("enum SportSpoilers") { inDefinition = true }
                if inDefinition {
                    if raw == "}" { inDefinition = false }
                    return nil
                }
                let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                return Line(file: name, number: index + 1, text: code)
            }
        }
    }

    /// The inputs as code reads them: the preference (`f1.hidesSpoilers`, `preferences.hidesSpoilers`; a local decided
    /// value named `hidesSpoilers` has no dot), the parent page's value, and the answer's own switch.
    private static let inputs = [".hidesSpoilers", "pageHidesSpoilers", "sportHidesSpoilers", "spoilerFree == true",
                                 "front.spoilerFree", "front?.spoilerFree"]

    private func report(_ found: [Line], _ rule: String) {
        XCTAssertTrue(found.isEmpty, "\(rule):\n" + found.map { "  \($0.file):\($0.number): \($0.text.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n"))
    }

    /// No line combines an input with `||` (also across a line break: an `||` ending the line before or starting the line
    /// after) outside `SportSpoilers.hidden`.
    func testNoScreenCombinesTheInputsItself() throws {
        let lines = try sourceLines()
        var found: [Line] = []
        for (index, line) in lines.enumerated() where Self.inputs.contains(where: { line.text.contains($0) }) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let before = index > 0 && lines[index - 1].file == line.file
                ? lines[index - 1].text.trimmingCharacters(in: .whitespaces) : ""
            let after = index + 1 < lines.count && lines[index + 1].file == line.file
                ? lines[index + 1].text.trimmingCharacters(in: .whitespaces) : ""
            if trimmed.contains("||") || before.hasSuffix("||") || after.hasPrefix("||") { found.append(line) }
        }
        report(found, "#278: combine the spoiler inputs only through SportSpoilers.hidden(preference:answer:page:)")
    }

    /// Every read of an input that decides drawing is an argument to `SportSpoilers.hidden(` on that line. Allowed
    /// otherwise: the Apple TV front page's seam `scoresHidden(preference:front:)`, the preference's own definition (`F1PageModel.swift`), the environment key's definition and the one
    /// place a page sets it (`.environment(\.sportHidesSpoilers, ...)`, a decided value), the `@Environment` declarations,
    /// and `.onChange(of: ...)` (a reload, not a drawing decision).
    func testEveryDecisionCallsTheOneFunction() throws {
        let found = try sourceLines().filter { line in
            guard line.file != "F1PageModel.swift", Self.inputs.contains(where: { line.text.contains($0) }) else { return false }
            let text = line.text
            if text.contains("SportSpoilers.hidden(") { return false }
            if text.contains("@Environment(\\.sportHidesSpoilers)") || text.contains(".environment(\\.sportHidesSpoilers,") { return false }
            if text.contains(".onChange(of:") { return false }
            // The Apple TV front page's pure seam (it calls SportSpoilers.hidden itself; testTVFrontPageHonoursTheAnswersSpoilerFree checks it).
            if line.file == "SportFrontTVPage.swift" && text.contains("Self.scoresHidden(preference:") { return false }
            if line.file == "SportPageParts.swift" && text.contains("var sportHidesSpoilers: Bool") { return false }
            return true
        }
        report(found, "#278: decide whether scores are hidden with SportSpoilers.hidden(preference:answer:page:)")
    }
}
