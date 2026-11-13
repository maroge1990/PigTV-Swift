import XCTest
@testable import PigTV

/// #278 (audit D5): Hide scores has one writer, Settings › Sport (a whole-list `PUT sports/follows`). The cricket page's
/// chip and its own save path are gone; the sport pages only read the choice.
final class SportHideScoresWriterTests: XCTestCase {
    /// The sport pages' model only reads: no write path is left in it.
    func testTheSportPagesModelHasNoWritePath() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTV/F1PageModel.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(#"method: "PUT""#), "F1PageModel sends no PUT")
        XCTAssertFalse(text.contains("UserDefaults"), "and keeps no device copy")
    }
}
