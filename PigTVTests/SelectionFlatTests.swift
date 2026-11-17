import Foundation
import XCTest

/// maroge1990/PigTV#344: a selected item (a Settings row, a pill, a chip, a segmented choice) is shown by its shading
/// alone (`pigSelection`), never by a pink line, bar, underline or outline drawn on it. Focus keeps its ring (tvOS focus
/// is `PigFocus`). The source is checked, as in BrandRulesTests.
final class SelectionFlatTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PigTV")

    /// The pink accent drawn as a bar or outline inside a block that tests a selected flag.
    func testNoSelectedItemDrawsAnAccentLine() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        // A line that draws the accent as a capsule/rectangle bar or a stroked outline.
        let draws = try NSRegularExpression(pattern: #"\.(fill|strokeBorder|stroke)\(\s*((isSelected|selected|picked) \? )?Color\.pigAccent\b"#)
        // The selected flag in the line itself, or an `if` on it in the four lines above (a bar drawn only when selected).
        let flag = try NSRegularExpression(pattern: #"\b(if|case) +(isSelected|selected|on|picked|appearance == value)\b|(isSelected|selected|picked|on) \? Color\.pigAccent"#)
        var found: [String] = []
        for name in names {
            let lines = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                // (a radio's ring and dot are the control's own glyph, drawn with a Circle, and stay)
                guard !line.contains("Circle()"), draws.firstMatch(in: line, range: range) != nil else { continue }
                // the selected flag on this line or in the four lines above it
                let window = lines[max(0, i - 4)...i].joined(separator: "\n")
                if flag.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) != nil { found.append("\(name):\(i + 1)") }
            }
        }
        XCTAssertEqual(found, [], "selected items must be shaded, not lined (#344)")
    }
}
