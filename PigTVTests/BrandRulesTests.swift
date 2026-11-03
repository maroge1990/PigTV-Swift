import Foundation
import XCTest

/// The Pig brand kit (1.7.0) rules the source can be checked for (maroge1990/PigTV#190): colours by role from the
/// catalog (§4), playback panels from 82 % black and the rose live dot (§7), corner radii from the shared `PigRadius`
/// scale (§6), and the kit's lockup files instead of a pig and wordmark put together by hand (§3). It reads the files in
/// `PigTV/` from the checkout, so it runs on the simulator with no app state.
final class BrandRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let sources = root.appendingPathComponent("PigTV")

    /// The file that defines the shared roles (the radius scale and the one artwork-colour initialiser).
    private static let rolesFile = "PigBrandRoles.swift"

    /// Files that could not be changed with the rest of #190, each with its reason. Only literal radii are allowed here.
    private static let radiusAllowlist: [String: String] = [
        "CricketPageView.swift": "build 99 (D-43 sport pages) is under Codex review; its radii move with the review's fixes",
        "F1PageView.swift": "build 99 (D-43 sport pages) is under Codex review",
        "SportFrontView.swift": "build 99 (D-43 sport pages) is under Codex review",
        "SportFrontTVPage.swift": "build 99 (D-43 sport pages) is under Codex review",
        "SportEventsViews.swift": "build 99 (D-43 sport pages) is under Codex review",
        "SportMotorViews.swift": "build 99 (D-43 sport pages) is under Codex review",
        "SportPageParts.swift": "build 99 (D-43 sport pages) is under Codex review",
        "PigTVApp.swift": "build 99 (D-43 sport pages) is under Codex review",
    ]

    /// Files allowed a `Color(white:)` grey, each with its reason (same rule as the radius allowlist).
    private static let greyAllowlist: [String: String] = [
        "PigTVApp.swift": "build 99 (D-43 sport pages) is under Codex review",
    ]

    /// Files allowed a literal black or white, each with its reason. The player files keep theirs until the player's own
    /// brand pass (out of the shell batch, #190); the fixtures draw synthetic logos and debug-only screens.
    private static let blackWhiteAllowlist: [String: String] = [
        "CustomPlayer.swift": "player file: out of the shell batch's scope", "PlayerControls.swift": "player file",
        "PlayerExtras.swift": "player file", "PlayerShared.swift": "player file", "RecordingPlayer.swift": "player file",
        "RecordingTouchChrome.swift": "player file", "RecordingPlayback.swift": "player file", "PlaybackModel.swift": "player file",
        "GuideFixtures.swift": "synthetic test logos (DEBUG fixtures)", "PigTVApp.swift": "DEBUG fixture screens",
    ]

    /// Tab roots: each draws the page canvas and its corner bloom (`pigPageBackdrop`, PigPageBackground).
    private static let tabRootFiles = ["SportFrontView.swift", "SportsDashboardView.swift", "SportView.swift", "GuideView.swift",
                                       "RecordingsView.swift", "SettingsView.swift"]

    /// The views drawn over video: §7 applies (protected dark surfaces, black panels from 82 %).
    private static let playerFiles: Set<String> = [
        "CustomPlayer.swift", "PlayerControls.swift", "PlayerExtras.swift", "PlayerShared.swift",
        "RecordingPlayer.swift", "RecordingTouchChrome.swift",
    ]

    private struct Line { let file: String; let number: Int; let text: String }

    private func sourceLines() throws -> [Line] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 50, "the PigTV sources were not found at \(Self.sources.path)")
        return try names.flatMap { name -> [Line] in
            let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
            return text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
                // Comments are not code: drop `//` comments (a URL's "://" never starts one here).
                let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                return Line(file: name, number: index + 1, text: code)
            }
        }
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func report(_ found: [Line], _ rule: String) {
        XCTAssertTrue(found.isEmpty, "\(rule):\n" + found.map { "  \($0.file):\($0.number): \($0.text.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n"))
    }

    // §4: colours by role. A typed-in RGB colour or a system red/yellow is never a role.
    func testNoLiteralOrSystemColours() throws {
        let lines = try sourceLines().filter { $0.file != Self.rolesFile }
        report(lines.filter { matches(#"\bColor\(red:"#, $0.text) }, "Color(red:) outside the catalog (use a Pig colour role)")
        report(lines.filter { matches(#"\bColor\.(red|yellow)\b"#, $0.text) || matches(#"[(:?,]\s*\.(red|yellow)\b"#, $0.text) },
               "system red/yellow (use pigDanger/pigWarning, or pigMediaAccent for live on video)")
        report(lines.filter { Self.greyAllowlist[$0.file] == nil && matches(#"\bColor\(white:"#, $0.text) },
               "Color(white:) grey (use a Pig colour role)")
    }

    // §4 (#190, Apple 104): black and white are roles too: `pigMediaCanvas`/`pigMediaText`/`pigMediaPanel` around video,
    // `pigOnAccent` on the accent, `pigOnStatus` on a status fill or team disc. Before 104 the sport pages' LIVE pills, the
    // badges, the player host and the guide's strip mask used `Color.white`/`Color.black`.
    func testNoLiteralBlackOrWhite() throws {
        let lines = try sourceLines().filter { $0.file != Self.rolesFile && Self.blackWhiteAllowlist[$0.file] == nil }
        report(lines.filter {
            matches(#"\b(Color|UIColor)\.(black|white)\b"#, $0.text) || matches(#"[(:?,]\s*\.(black|white)\b"#, $0.text)
        }, "a literal black or white (use a Pig colour role)")
        for name in Self.blackWhiteAllowlist.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.sources.appendingPathComponent(name).path), "\(name) is allowlisted but gone")
        }
    }

    // §5 (brand 1.6): every tab page sits on the canvas with the corner bloom.
    func testEveryTabRootDrawsThePageCanvas() throws {
        for name in Self.tabRootFiles {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(".pigPageBackdrop()"), "\(name) draws no page canvas")
        }
    }

    // §7: over video, black panels and shades start at 82 %. Shadows are not panels. A line marked `brand: scrim` is a
    // full-screen dimmer behind a panel, not a panel itself.
    func testPlaybackPanelsStartAtEightyTwoPercent() throws {
        let lines = try sourceLines().filter { Self.playerFiles.contains($0.file) }
        XCTAssertEqual(Set(lines.map(\.file)), Self.playerFiles, "a player file is missing")
        let raw = try Self.playerFiles.flatMap { name in
            try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
                .enumerated().map { (name, $0.offset + 1, $0.element) }
        }
        let scrims = Set(raw.filter { $0.2.contains("brand: scrim") }.map { "\($0.0):\($0.1)" })
        let weak = lines.filter { line in
            guard !line.text.contains(".shadow("), !scrims.contains("\(line.file):\(line.number)") else { return false }
            return Self.opacities(after: #"(black|pigMediaCanvas)\.opacity\("#, in: line.text).contains { $0 < 0.82 }
        }
        report(weak, "a playback panel or shade under 82 % black (use Color.pigMediaPanel, or pigMediaCanvas at 0.82 or more)")
        report(lines.filter { matches(#"\bColor\(white:"#, $0.text) }, "a grey playback fallback (use Color.pigMediaSolidPanel)")
    }

    // §6: radii come from the shared scale.
    func testCornerRadiiComeFromTheSharedScale() throws {
        let lines = try sourceLines().filter { $0.file != Self.rolesFile && Self.radiusAllowlist[$0.file] == nil }
        let literal = lines.filter {
            matches(#"cornerRadius:\s*[0-9]"#, $0.text)
                || matches(#"\b(radius|cornerRadius|heroRadius|cardRadius|rowRadius)\s*:\s*CGFloat\s*=\s*[0-9]"#, $0.text)
                || matches(#"(Leading|Trailing)Radius:[^,)]*\b[1-9]"#, $0.text)
        }
        report(literal, "a literal corner radius (use PigRadius.compact/card/hero/inner)")
        // The allowlist names only files that exist and still need it.
        for name in Self.radiusAllowlist.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.sources.appendingPathComponent(name).path), "\(name) is allowlisted but gone")
        }
    }

    // §3: the kit's lockups are in the catalog (vector, light and dark), and no view rebuilds one from the wordmark.
    func testKitLockupsAreInTheCatalog() throws {
        let catalog = Self.sources.appendingPathComponent("Assets.xcassets")
        for (set, stem) in [("LockupHorizontal", "lockup-horizontal"), ("LockupStacked", "lockup-stacked")] {
            let folder = catalog.appendingPathComponent("\(set).imageset")
            for variant in ["light", "dark"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem)-\(variant).svg").path),
                              "\(set).imageset has no \(stem)-\(variant).svg")
            }
            let contents = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: contents) as? [String: Any])
            let properties = json["properties"] as? [String: Any]
            XCTAssertEqual(properties?["preserves-vector-representation"] as? Bool, true, "\(set) must keep its vector")
        }
        let lines = try sourceLines()
        report(lines.filter { $0.text.contains("Image(\"BrandWordmark\")") }, "the wordmark drawn on its own (use the kit's lockup)")
    }

    /// Every decimal literal inside the parentheses that follow `prefix` ("0.45" and both sides of "x ? 0.9 : 0.7").
    static func opacities(after prefix: String, in text: String) -> [Double] {
        var values: [Double] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: prefix, options: .regularExpression, range: search) {
            var depth = 1, end = hit.upperBound
            while end < text.endIndex, depth > 0 {
                if text[end] == "(" { depth += 1 } else if text[end] == ")" { depth -= 1 }
                end = text.index(after: end)
            }
            let inside = String(text[hit.upperBound..<end])
            let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z_0-9.])(0?\.[0-9]+|1(\.0+)?)(?![0-9])"#)
            let found = regex.matches(in: inside, range: NSRange(inside.startIndex..., in: inside))
            values += found.compactMap { Range($0.range(at: 1), in: inside).flatMap { Double(inside[$0]) } }
            search = end..<text.endIndex
        }
        return values
    }

    func testOpacityParser() {
        XCTAssertEqual(Self.opacities(after: #"black\.opacity\("#, in: ".black.opacity(reduce ? 0.95 : 0.7)"), [0.95, 0.7])
        XCTAssertEqual(Self.opacities(after: #"black\.opacity\("#, in: "Color.black.opacity(0.82), x.opacity(0.1)"), [0.82])
        XCTAssertEqual(Self.opacities(after: #"black\.opacity\("#, in: ".black.opacity(max(opacity, 0.9))"), [0.9])
    }
}
