import Foundation
import XCTest

/// The Pig brand kit's (PigBrand guide 1.8.1, tokens 1.7.0) rules the source can be checked for (maroge1990/PigTV#190): colours by role from the
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
    private static let tabRootFiles = ["SportFrontView.swift", "GuideView.swift",
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

    // §5: every tab page sits on the canvas with the corner bloom.
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

    // #243: paddings and stack spacings come from PigSpacing. A bare number in a `.padding(...)` or after `spacing:` is a
    // new value outside the scale (0 is not a distance; a number after `*` or `/` is a multiple of a token, not a size).
    // Whole files are read, so a call written over several lines is checked too (batch 3 Codex round 1).
    func testSpacingComesFromTheScale() throws {
        let skip: Set<String> = [Self.rolesFile, "BrandLayout.swift"]
        report(try sourceFiles().filter { !skip.contains($0.file) }.flatMap { file in
            (Self.literals(in: file.code, kind: .padding) + Self.literals(in: file.code, kind: .spacing)).map { file.line($0.offset) }
        }, "a literal padding or spacing (use PigSpacing.xxs/xs/s/m/l/xl, section, empty, or a named metric)")
    }

    /// Files allowed the system bordered style, each with its reason.
    private static let borderedAllowlist: [String: String] = [
        "GuideView.swift": "the guide's icon-only toolbar (Search, Jump to): navigation controls, not actions",
        "SettingsView.swift": "Sign out's destructive confirmation, tinted danger",
    ]

    // #243: a secondary action has one look per platform (PigSecondaryButtonStyle / pigSecondaryButton()); the system
    // bordered style tinted the accent and made a second pink control beside the primary.
    func testSecondaryActionsShareOneStyle() throws {
        let files = try sourceFiles()
        report(files.filter { Self.borderedAllowlist[$0.file] == nil }.flatMap { file in
            Self.borderedStyles(in: file.code).map { file.line($0) }
        }, "the system bordered style on an action (use .pigSecondaryButton(), or .pigPrimaryButton() for the one primary)")
        report(try sourceLines().filter { matches(#"\bTVActionStyle\b"#, $0.text) }, "TVActionStyle is PigSecondaryButtonStyle now")
    }

    /// The only files that turn the system focus effect off: the players draw their own cursor over video (their buttons
    /// are one blank, focused surface that takes the remote's moves).
    private static let focusEffectAllowlist: Set<String> = ["CustomPlayer.swift", "RecordingPlayer.swift"]

    // Brand 1.8 §6 and §15 (maroge1990/PigTV#279): on Apple TV a focused item lifts and carries the accent ring outside
    // its edge, one way everywhere. Every tvOS button style that reads focus draws it through the shared treatment
    // (`pigFocus`, PigFocus.swift), and no tvOS code draws a focus ring, fill, scale or shadow of its own. Before build
    // 198 nine styles each drew focus their own way (a ring inside or outside, a scale or none, no Reduce Motion).
    func testTVFocusGoesThroughTheSharedTreatment() throws {
        var found: [Line] = []
        for file in try sourceFiles() where file.file != "PigFocus.swift" {
            let tv = SourceFile(file: file.file, code: Self.tvOSCode(file.code))
            for style in Self.buttonStyles(in: tv.code) where style.body.contains("isFocused")
                && !style.body.contains(".pigFocus(") && !style.body.contains("PigFocusSurface(") {
                found.append(tv.line(style.offset))
            }
            found += Self.handDrawnFocus(in: tv.code).map { tv.line($0) }
            // The surface that the secondary and surface styles share must itself go through the shared treatment.
            if let surface = Self.block(after: #"struct\s+PigFocusSurface\b"#, in: tv.code), !surface.body.contains(".pigFocus(") {
                found.append(tv.line(surface.offset))
            }
        }
        report(found, "a tvOS focus look drawn outside the shared treatment (use .pigFocus(_:in:lift:) and PigFocus.fill)")
    }

    /// #293 (Codex on Apple 198–203, item 11): the television's focus styles and focus views, by name. Each must read
    /// its real focus state and pass that to the shared treatment, and take the focus fill. The scan above only asked
    /// that a style reading `isFocused` mention `.pigFocus(`: a style passing a constant (`.pigFocus(false, …)`), or one
    /// with both its focus property and the treatment removed, passed it.
    private static let focusStyles: Set<String> = [
        "PigFocusSurface", "PigSecondaryButtonStyle", "PigSurfaceButtonStyle", "PigMenuRowStyle", "PigPrimaryButtonStyle",
        "GuideFilterStyle", "SettingsMenuRowStyle", "SignInTileStyle", "GuideGridProgrammeView", "GuideGridTileView",
    ]
    /// Button styles that draw no focus of their own, each with its reason. Every tvOS button style is in one list.
    private static let plainButtonStyles: [String: String] = [
        "BlankButtonStyle": "the players: one blank focused surface, the player draws its own cursor over video",
        "PlayerRowPressStyle": "the touch player's pressed look", "PlayerPressStyle": "the touch player's pressed look",
        "PigPressStyle": "the touch pressed look; on the television plain cards keep the system focus effect",
    ]
    /// Focus styles that keep their own fill under focus, each with its reason.
    private static let focusFillExempt: [String: String] = [
        "PigPrimaryButtonStyle": "the one primary action keeps its accent fill (§6)",
    ]

    func testEachFocusStylePassesItsRealFocusStateAndTakesTheFill() throws {
        let files = try sourceFiles().filter { $0.file != "PigFocus.swift" }.map { (file: $0.file, code: Self.tvOSCode($0.code)) }
        let problems = Self.focusStyleProblems(files: files, styles: Self.focusStyles, plain: Set(Self.plainButtonStyles.keys),
                                               fillExempt: Set(Self.focusFillExempt.keys))
        XCTAssertTrue(problems.isEmpty, "a tvOS focus style that does not draw the real focus state (#293):\n" + problems.joined(separator: "\n"))
    }

    /// What is wrong with the focus styles in `files` (tvOS code, comments dropped): a listed style that is missing, reads
    /// no focus state, does not hand that state to `.pigFocus`/`.pigFocusWhenFocused`/`PigFocusSurface` as its first
    /// argument, or takes no focus fill; a button style in neither list; a plain style that reads focus; a call of the
    /// shared treatment outside the listed styles (`.pigFocus(false, …)` in some view). Pure (negative fixtures in
    /// `testTheFocusStyleCheckRejectsFakes`).
    static func focusStyleProblems(files: [(file: String, code: String)], styles: Set<String>, plain: Set<String>,
                                   fillExempt: Set<String>) -> [String] {
        func capture(_ pattern: String, _ text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        func has(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var problems: [String] = []
        var found = Set<String>()
        for file in files {
            var covered: [Range<Int>] = []
            for name in styles {
                guard let block = block(after: #"struct\s+"# + name + #"\b"#, in: file.code) else { continue }
                found.insert(name)
                covered.append(block.offset..<(block.offset + block.body.count))
                let body = block.body
                // The focus state: the environment's, or (a view or modifier handed it) a stored `focused: Bool`.
                guard let state = capture(#"@Environment\(\\\.isFocused\)\s*(?:private\s+)?var\s+(\w+)"#, body)
                        ?? capture(#"\b(?:let|var)\s+(focused)\s*:\s*Bool\b"#, body) else {
                    problems.append("\(file.file): \(name) reads no focus state"); continue
                }
                let treatment = #"(\.pigFocus(WhenFocused)?\(|PigFocusSurface\(\s*focused:)\s*"# + state + #"\s*,"#
                if !has(treatment, body) {
                    problems.append("\(file.file): \(name) does not pass `\(state)` to .pigFocus(_:in:lift:) or PigFocusSurface")
                }
                let fill = has(#"PigFocus\.fill\b"#, body) || has(#"PigFocusSurface\(\s*focused:\s*"# + state + #"\b"#, body)
                    || has(#"ChannelTile\([^)]*\bfocused:\s*"# + state + #"\b"#, body)
                if !fill && !fillExempt.contains(name) { problems.append("\(file.file): \(name) takes no focus fill (PigFocus.fill)") }
            }
            for style in buttonStyles(in: file.code) where !styles.contains(style.name) {
                if !plain.contains(style.name) {
                    problems.append("\(file.file): \(style.name) is in neither list (focus styles, plain styles)")
                } else if style.body.contains("isFocused") || has(#"\.pigFocus|PigFocusSurface\("#, style.body) {
                    problems.append("\(file.file): \(style.name) is listed plain but draws focus")
                }
            }
            let call = try! NSRegularExpression(pattern: #"\.pigFocus(WhenFocused)?\(|\bPigFocusSurface\("#)
            for m in call.matches(in: file.code, range: NSRange(file.code.startIndex..., in: file.code)) {
                guard let r = Range(m.range, in: file.code) else { continue }
                let offset = file.code.distance(from: file.code.startIndex, to: r.lowerBound)
                if !covered.contains(where: { $0.contains(offset) }) {
                    let line = file.code.prefix(offset).filter { $0 == "\n" }.count + 1
                    problems.append("\(file.file):\(line): the shared focus treatment outside a listed focus style")
                }
            }
        }
        for name in styles.subtracting(found).sorted() { problems.append("\(name) is listed but gone") }
        return problems
    }

    func testTheFocusStyleCheckRejectsFakes() {
        let all: Set<String> = ["Good", "Constant", "Removed", "Other", "NoFill", "Surface"]
        func problems(_ code: String, styles: Set<String> = all, plain: Set<String> = []) -> [String] {
            Self.focusStyleProblems(files: [(file: "F.swift", code: code)], styles: styles, plain: plain, fillExempt: [])
        }
        let good = """
        struct Good: ButtonStyle {
            @Environment(\\.isFocused) private var focused
            func makeBody(configuration: Configuration) -> some View {
                configuration.label.background(focused ? PigFocus.fill : Color.pigRaised, in: Capsule())
                    .pigFocus(focused, in: Capsule(), lift: .control)
            }
        }
        """
        XCTAssertEqual(problems(good, styles: ["Good"]), [])
        // A constant: the old scan passed it (it reads isFocused and mentions .pigFocus().
        let constant = good.replacingOccurrences(of: "struct Good", with: "struct Constant")
            .replacingOccurrences(of: ".pigFocus(focused,", with: ".pigFocus(false,")
        XCTAssertEqual(problems(constant, styles: ["Constant"]).count, 1, "a constant focus state")
        // Its focus property and the treatment both removed: the old scan skipped it (it no longer reads isFocused).
        let removed = """
        struct Removed: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View { configuration.label.background(Color.pigRaised) }
        }
        """
        XCTAssertEqual(problems(removed, styles: ["Removed"]), ["F.swift: Removed reads no focus state"])
        // Another variable passed in place of the focus state.
        let other = good.replacingOccurrences(of: "struct Good", with: "struct Other")
            .replacingOccurrences(of: ".pigFocus(focused,", with: ".pigFocus(selected,")
        XCTAssertEqual(problems(other, styles: ["Other"]).count, 1)
        // The focus state passed but no fill: lift and ring without the tint (#293 item 10).
        let noFill = good.replacingOccurrences(of: "struct Good", with: "struct NoFill")
            .replacingOccurrences(of: "focused ? PigFocus.fill : Color.pigRaised", with: "Color.pigRaised")
        XCTAssertEqual(problems(noFill, styles: ["NoFill"]), ["F.swift: NoFill takes no focus fill (PigFocus.fill)"])
        // A surface handed its state, passing it on.
        let surface = """
        private struct Surface<S: InsettableShape>: ViewModifier {
            var focused: Bool
            func body(content: Content) -> some View {
                content.background(focused ? PigFocus.fill : .clear).pigFocus(focused, in: shape, lift: lift)
            }
        }
        """
        XCTAssertEqual(problems(surface, styles: ["Surface"]), [])
        // A listed style that is gone; a new button style in neither list; the treatment called from a view.
        XCTAssertEqual(problems("", styles: ["Good"]), ["Good is listed but gone"])
        XCTAssertEqual(problems(good, styles: []).filter { $0.contains("neither list") }.count, 1)
        XCTAssertEqual(problems(good + "\nstruct V: View { var body: some View { Text(\"x\").pigFocus(false, in: Capsule(), lift: .card) } }",
                                styles: ["Good"]),
                       ["F.swift:8: the shared focus treatment outside a listed focus style"])
        // A plain style that draws focus.
        XCTAssertTrue(problems(good.replacingOccurrences(of: "struct Good", with: "struct P"), styles: [], plain: ["P"])
                        .contains("F.swift: P is listed plain but draws focus"))
    }

    // Brand 1.8 §15: the system effect is never switched off, except by the players (their cursor is drawn).
    func testOnlyThePlayersTurnOffTheSystemFocusEffect() throws {
        report(try sourceLines().filter {
            !Self.focusEffectAllowlist.contains($0.file) && matches(#"\.(focusEffectDisabled|hoverEffectDisabled)\("#, $0.text)
        }, "the system focus effect switched off outside the players")
        for name in Self.focusEffectAllowlist {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.sources.appendingPathComponent(name).path), "\(name) is allowlisted but gone")
        }
    }

    // Brand 1.8 §15 (#279): every focusable control on the television is at least 56 x 56 pt. The shared focus styles
    // carry the minimum (`pigTarget()`, `PigFocus.minTarget`): a tvOS button style that draws focus through the shared
    // treatment must apply it too, and the minimum must stay 56. Before Apple 200 chips and the secondary buttons in a
    // page's action row were about 51 pt high, the primary about 55, the score-delay steppers about 24.
    func testTelevisionFocusTargetsAreAtLeastFiftySixPoints() throws {
        let files = try sourceFiles()
        let focus = try XCTUnwrap(files.first { $0.file == "PigFocus.swift" })
        let tvFocus = Self.tvOSCode(focus.code)
        let minimum = Self.sizeConstants(in: tvFocus).first { $0.name == "minTarget" }
        XCTAssertGreaterThanOrEqual(minimum?.value ?? 0, 56, "PigFocus.minTarget on the television")
        var found: [Line] = []
        for file in files where file.file != "PigFocus.swift" {
            let tv = SourceFile(file: file.file, code: Self.tvOSCode(file.code))
            for style in Self.buttonStyles(in: tv.code)
            where style.body.contains(".pigFocus(") && !style.body.contains(".pigTarget()") {
                found.append(tv.line(style.offset))
            }
            if let surface = Self.block(after: #"struct\s+PigFocusSurface\b"#, in: tv.code), !surface.body.contains(".pigTarget()") {
                found.append(tv.line(surface.offset))
            }
        }
        report(found, "a tvOS focus style without the 56 pt minimum (apply .pigTarget() before its surface)")
    }

    /// The smallest text the television draws (brand 1.8 §15).
    private static let tvMinimumText: Double = 23

    /// tvOS type roles allowed under the minimum, each with its reason.
    private static let smallRoleAllowlist: [String: String] = [
        "micro": "letters inside a small team or league badge: artwork, not text (#279), and unused on the television",
    ]

    /// Files allowed a plain `minimumScaleFactor` on the television, each with its reason.
    private static let scaleAllowlist: [String: String] = [
        "PigBrandRoles.swift": "defines pigMinimumScale",
        "SportFrontView.swift": "the initials inside a team badge disc: artwork, not text (#279)",
    ]

    /// `static let <name>: CGFloat = <number>` in `text`, in order.
    static func sizeConstants(in text: String) -> [(name: String, value: Double, offset: Int)] {
        let regex = try! NSRegularExpression(pattern: #"\b(\w+)\s*:\s*CGFloat\s*=\s*([0-9]+(?:\.[0-9]+)?)\b"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let name = Range(m.range(at: 1), in: text), let value = Range(m.range(at: 2), in: text),
                  let whole = Range(m.range, in: text), let number = Double(text[value]) else { return nil }
            return (String(text[name]), number, text.distance(from: text.startIndex, to: whole.lowerBound))
        }
    }

    /// The text between the braces that follow the first match of `pattern` (the opening brace excluded).
    static func block(after pattern: String, in text: String) -> (body: String, offset: Int)? {
        guard let hit = text.range(of: pattern, options: .regularExpression),
              let open = text[hit.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 1, end = text.index(after: open)
        while end < text.endIndex, depth > 0 {
            if text[end] == "{" { depth += 1 } else if text[end] == "}" { depth -= 1 }
            end = text.index(after: end)
        }
        let start = text.index(after: open)
        return (String(text[start..<text.index(before: end)]), text.distance(from: text.startIndex, to: start))
    }

    // Brand 1.8 §15 (maroge1990/PigTV#279): no text on the television is under 23 pt. The tvOS type roles (PigType) and
    // the player's and guide's own text sizes are read from the tvOS branch of the source; a UIKit `ofSize:` literal
    // under 23 in tvOS code fails, and so does a `minimumScaleFactor` that is not floored (`pigMinimumScale`). Before
    // Apple 199 caption and kicker were 17 and secondary 20, the player's tuning card 18 and 16, the guide's time header
    // a UIKit 20.
    func testTelevisionTextIsAtLeastTwentyThreePoints() throws {
        let files = try sourceFiles()
        var found: [Line] = []
        let roles = try XCTUnwrap(files.first { $0.file == Self.rolesFile })
        let tvRoles = SourceFile(file: roles.file, code: Self.tvOSCode(roles.code))
        let typeBlock = try XCTUnwrap(Self.block(after: #"enum\s+PigType\b"#, in: tvRoles.code), "PigType was not found")
        let roleSizes = Self.sizeConstants(in: typeBlock.body)
        XCTAssertGreaterThan(roleSizes.count, 8, "PigType's tvOS roles were not read")
        found += roleSizes.filter { $0.value < Self.tvMinimumText && Self.smallRoleAllowlist[$0.name] == nil }
            .map { tvRoles.line(typeBlock.offset + $0.offset) }
        let player = try XCTUnwrap(files.first { $0.file == "PlayerShared.swift" })
        let tvPlayer = SourceFile(file: player.file, code: Self.tvOSCode(player.code))
        let metrics = try XCTUnwrap(Self.block(after: #"enum\s+PlayerMetrics\b"#, in: tvPlayer.code), "PlayerMetrics was not found")
        let textNames: Set = ["tuningName", "tuningTitle", "tuningDetail", "tuningNext", "rowName", "rowNumber", "rowTitle"]
        let playerSizes = Self.sizeConstants(in: metrics.body).filter { textNames.contains($0.name) }
        XCTAssertEqual(Set(playerSizes.map(\.name)), textNames, "the player's text sizes were not all read")
        found += playerSizes.filter { $0.value < Self.tvMinimumText }.map { tvPlayer.line(metrics.offset + $0.offset) }
        for file in files {
            let tv = SourceFile(file: file.file, code: Self.tvOSCode(file.code))
            found += Self.uiFontSizes(in: tv.code).filter { $0.value < Self.tvMinimumText }.map { tv.line($0.offset) }
            if Self.scaleAllowlist[file.file] == nil {
                found += Self.offsets(of: #"\.minimumScaleFactor\("#, in: tv.code).map { tv.line($0) }
            }
        }
        report(found, "television text under \(Int(Self.tvMinimumText)) pt (use PigType's roles, and .pigMinimumScale(_:size:) for a scale factor)")
        for name in Self.scaleAllowlist.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.sources.appendingPathComponent(name).path), "\(name) is allowlisted but gone")
        }
    }

    // Brand 1.8 §16 (maroge1990/PigTV#280): on iPhone and iPad no text is under 11 pt and a control is at least 44 pt to
    // touch. Before Apple 206 a league badge's letters were 9 pt on the iPhone front page, the iPhone Sport pages' "‹ Back"
    // was about 20 pt high, the iPhone landscape guide's icon buttons were `.controlSize(.small)` (about 28 pt), and the
    // iPhone follow card had a fixed 212 pt height that pushed Remind me and Record out of it (Mark's report, 10 Nov).
    func testTouchTextAndTargetsMeetTheMinimums() throws {
        let files = try sourceFiles()
        var found: [Line] = []
        let roles = try XCTUnwrap(files.first { $0.file == Self.rolesFile })
        let touchRoles = SourceFile(file: roles.file, code: Self.touchCode(roles.code))
        let typeBlock = try XCTUnwrap(Self.block(after: #"enum\s+PigType\b"#, in: touchRoles.code), "PigType was not found")
        let sizes = Self.sizeConstants(in: typeBlock.body).filter { $0.name != "minimum" }
        XCTAssertGreaterThan(sizes.count, 8, "PigType's touch roles were not read")
        found += sizes.filter { $0.value < 11 }.map { touchRoles.line(typeBlock.offset + $0.offset) }
        let target = Self.sizeConstants(in: Self.block(after: #"enum\s+PigTouch\b"#, in: roles.code)?.body ?? "")
        XCTAssertGreaterThanOrEqual(target.first { $0.name == "minTarget" }?.value ?? 0, 44, "PigTouch.minTarget")
        for file in files {
            let touch = SourceFile(file: file.file, code: Self.touchCode(file.code))
            found += Self.uiFontSizes(in: touch.code).filter { $0.value < 11 }.map { touch.line($0.offset) }
            // a small control (a ProgressView may be small: it is not a target)
            found += Self.offsets(of: #"\.controlSize\(\.(small|mini)\)"#, in: touch.code).map { touch.line($0) }
                .filter { !$0.text.contains("ProgressView") }
        }
        // The follow card sizes by its content, and the sport page's back control carries the touch minimum.
        for name in ["SportPhonePage.swift", "SportFrontPhonePage.swift"] {
            let file = try XCTUnwrap(files.first { $0.file == name })
            found += Self.offsets(of: #"height:\s*SportPhoneMetrics\.card"#, in: file.code).map { file.line($0) }
        }
        let page = try XCTUnwrap(files.first { $0.file == "SportPhonePage.swift" })
        let header = try XCTUnwrap(Self.block(after: #"struct\s+SportPhonePageHeader\b"#, in: page.code))
        if !header.body.contains(".pigTouchTarget(") { found.append(page.line(header.offset)) }
        report(found, "touch text under 11 pt or a target under 44 pt (use PigType's roles, .pigTouchTarget(), a regular or large control)")
    }

    /// The code compiled for iOS (the mirror of `tvOSCode`).
    static func touchCode(_ text: String) -> String {
        var stack: [(active: Bool, iosTaken: Bool, osGroup: Bool)] = []
        func iosCondition(_ condition: String) -> (active: Bool, isOS: Bool, ios: Bool) {
            let c = condition.replacingOccurrences(of: " ", with: "")
            if c == "os(iOS)" || c == "!os(tvOS)" { return (true, true, true) }
            if c == "os(tvOS)" || c == "!os(iOS)" { return (false, true, false) }
            return (true, false, false)
        }
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") || line == "#if" {
                let t = iosCondition(String(line.dropFirst(3)))
                stack.append((t.active, t.ios, t.isOS)); out.append(""); continue
            }
            if line.hasPrefix("#elseif"), let top = stack.popLast() {
                let t = iosCondition(String(line.dropFirst(7)))
                stack.append((!top.iosTaken && t.active, top.iosTaken || t.ios, top.osGroup || t.isOS)); out.append(""); continue
            }
            if line.hasPrefix("#else"), let top = stack.popLast() {
                stack.append((top.osGroup ? !top.iosTaken : true, top.iosTaken, top.osGroup)); out.append(""); continue
            }
            if line.hasPrefix("#endif") { _ = stack.popLast(); out.append(""); continue }
            out.append(stack.allSatisfy(\.active) ? raw : "")
        }
        return out.joined(separator: "\n")
    }

    func testTouchCodeParser() {
        let ios = Self.touchCode("a\n#if os(tvOS)\nb\n#else\nc\n#endif\n#if os(iOS)\nd\n#elseif os(tvOS)\ne\n#endif\n#if !os(tvOS)\nf\n#endif")
        XCTAssertEqual(ios.components(separatedBy: "\n").filter { !$0.isEmpty }, ["a", "c", "d", "f"])
    }

    /// The literal sizes in UIKit `ofSize:` arguments.
    static func uiFontSizes(in text: String) -> [(value: Double, offset: Int)] {
        let regex = try! NSRegularExpression(pattern: #"ofSize:\s*([0-9]+(?:\.[0-9]+)?)\b"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let value = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: text),
                  let number = Double(text[value]) else { return nil }
            return (number, text.distance(from: text.startIndex, to: whole.lowerBound))
        }
    }

    static func offsets(of pattern: String, in text: String) -> [Int] {
        try! NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }
    }

    func testTextSizeParsers() {
        let sizes = Self.sizeConstants(in: "static let caption: CGFloat = 17\n    static let a: CGFloat = 2, b: CGFloat = 23.5")
        XCTAssertEqual(sizes.map(\.name), ["caption", "a", "b"])
        XCTAssertEqual(sizes.map(\.value), [17, 2, 23.5])
        let block = Self.block(after: #"enum\s+X\b"#, in: "enum Y { a }\nenum X {\n  b { c }\n}\nd")
        XCTAssertEqual(block?.body, "\n  b { c }\n")
        XCTAssertEqual(Self.uiFontSizes(in: "UIFont.systemFont(ofSize: 20); f(ofSize: PigType.body)").map(\.value), [20])
    }

    // #243: one tagline, one field style and current copy on every platform (the 6 Nov audit found "Welcome to PigTV" on
    // touch beside the television's tagline, the system's black rounded field on touch, and an empty Sport page sending
    // the viewer to Home, which #216 retired).
    func testCopyAndFieldsMatchAcrossPlatforms() throws {
        let lines = try sourceLines()
        report(lines.filter { $0.text.contains("Welcome to PigTV") }, "a second tagline (SignInMetrics.welcome is one line)")
        report(lines.filter { matches(#"textFieldStyle\(\.roundedBorder\)"#, $0.text) }, "the system's rounded field (use .pigField())")
        report(lines.filter { $0.text.contains("and on Home") }, "Home is gone (D-44)")
    }

    /// Words that must not come back (brand 1.8 §14, maroge1990/PigTV#280), each with the one name used instead. Read in
    /// the app's string literals; identifiers and keys ("settings.sport.spoilerFree", "Retry-After") do not match.
    static let bannedWords: [(pattern: String, rule: String)] = [
        (#"\bRetry(?!-After)\b|\b[Rr]etrying\b|\bTry now\b"#, "the retry action is \"Try again\""),
        (#"[Ss]poiler-free|\bSpoiler"#, "hiding scores is \"Hide scores\" (Settings' name), its state \"Scores hidden\""),
        (#"Back to (channels|guide)|\b[Rr]eturn to (channels|your library)"#, "leaving a player is \"Close player\""),
        (#"^Your sports\b"#, "the Settings section is \"Your sport\", as on the web"),
        (#"[Ll]ive scores|[Ss]ports feed"#, "the scores source is \"the scores feed\", as on the web"),
        (#"[Tt]ailscale|[Pp]rovider stream"#, "a network product or a stream is not a household word: say what to do"),
        (#"HTTP \\\(|\\\(status\)|\bOSStatus|Keychain|[Ee]rror code|credentials"#, "no status, code or system name on screen"),
        (#"Settings → Sports|\bFavorite|\bfavorite\b"#, "Settings › Sport and favourite, as on the web"),
        (#"[A-Za-z]!(\s|$)"#, "no exclamation marks"),
    ]

    /// The string literals on a line of code (an interpolation's own quotes split it, which only shortens what is read).
    static func stringLiterals(in code: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        return regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    // Brand 1.8 §14 (maroge1990/PigTV#280): one name per thing on every platform, sentence case, no exclamation marks, and
    // no status, code or system text on screen. Before Apple 206 the app said Retry, Try now and Try again; Spoiler-free
    // beside Hide scores; Back to channels, Back to guide, Back and Cancel to leave a player; "Live scores" and "sports
    // feed"; Tailscale and "the provider stream"; "HTTP 500", Keychain statuses, and the system's description of any error.
    func testOneNamePerThingAndNoCodesOnScreen() throws {
        let lines = try sourceLines()
        var found: [Line] = []
        for line in lines {
            for literal in Self.stringLiterals(in: line.text) {
                for banned in Self.bannedWords where matches(banned.pattern, literal) {
                    found.append(Line(file: line.file, number: line.number, text: "\(banned.rule): \"\(literal)\""))
                }
            }
        }
        report(found, "a banned word in the app's text")
        report(lines.filter { matches(#"\.localizedDescription\b"#, $0.text) },
               "the system's description of an error reaches the screen (use UserMessage.text(for:otherwise:))")
    }

    /// Review of 206 (M1): the helpers that return the words for an error give an optional (nil: a cancelled request);
    /// put straight into a sentence, Swift draws "Optional(\"…\")" on screen ("The stream ended. Optional(…)", Settings ›
    /// Sport's "Not saved: Optional(…)"). Each such call, or a name bound to one, is unwrapped (`??`) before it is put in a
    /// sentence.
    func testNoOptionalWordsAreInterpolatedIntoASentence() throws {
        var found: [Line] = []
        for file in try sourceFiles() {
            for hit in Self.optionalInterpolations(in: file.code) {
                let number = file.code.prefix(hit).filter { $0 == "\n" }.count + 1
                found.append(Line(file: file.file, number: number, text: file.code.components(separatedBy: "\n")[number - 1]))
            }
        }
        report(found, "an optional error text put into a sentence (it draws “Optional(…)”; unwrap it with ??)")
    }

    func testOptionalInterpolationParser() {
        for bad in [#"x = "Not saved: \(UserMessage.text(for: error))""#,
                    #"let words = UserMessage.text(for: error, otherwise: plain)\nself.error = "The stream ended. \(words)""#,
                    #"t = "\(BrowseModel.actionText(PageWords.actionFailed, error))""#,
                    #"let w = Self.actionText(a, e)\nlet s = "Oh: \(w)""#] {
            XCTAssertFalse(Self.optionalInterpolations(in: bad).isEmpty, bad)
        }
        for fine in [#"x = "Not saved: \(UserMessage.text(for: error) ?? "the change was cancelled.")""#,
                     #"let words = UserMessage.text(for: error, otherwise: plain)\nself.error = "The stream ended. \(words ?? plain)""#,
                     #"let words = UserMessage.text(for: error) ?? plain\nself.error = "Oh. \(words)""#,
                     #"message = UserMessage.text(for: error)"#, #"Text("\(count) items")"#] {
            XCTAssertEqual(Self.optionalInterpolations(in: fine), [], fine)
        }
    }

    /// The helpers whose result is optional words for an error.
    private static let optionalWordCalls = #"(UserMessage\.text\(for:|actionText\()"#

    /// The offsets of `\( … )` interpolations whose content is one of `optionalWordCalls`, or a name bound to one
    /// (`let x = UserMessage.text(…)` with no `??`), with no `??` of its own.
    static func optionalInterpolations(in text: String) -> [Int] {
        let chars = Array(text)
        var names: Set<String> = []
        let binding = try! NSRegularExpression(pattern: #"\b(?:let|var)\s+([A-Za-z_][A-Za-z_0-9]*)\s*=\s*([^\n]*)"#)
        for m in binding.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let name = Range(m.range(at: 1), in: text), let value = Range(m.range(at: 2), in: text) else { continue }
            let rhs = String(text[value])
            if rhs.range(of: optionalWordCalls, options: .regularExpression) != nil, !rhs.contains("??") {
                names.insert(String(text[name]))
            }
        }
        var found: [Int] = []
        var index = 0
        while index + 1 < chars.count {
            guard chars[index] == "\\", chars[index + 1] == "(" else { index += 1; continue }
            var depth = 0, end = index + 1
            while end < chars.count {
                if chars[end] == "(" { depth += 1 } else if chars[end] == ")" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard end < chars.count else { break }
            let inside = String(chars[(index + 2)..<end]).trimmingCharacters(in: .whitespaces)
            let unwrapped = inside.contains("??")
            let call = inside.range(of: optionalWordCalls, options: .regularExpression) != nil
            if !unwrapped && (call || names.contains(inside)) { found.append(index) }
            index = end + 1
        }
        return found
    }

    func testBannedWordsParser() {
        XCTAssertEqual(Self.stringLiterals(in: #"Button("Retry") { f("a \"b\" c") }"#), ["Retry", #"a \"b\" c"#])
        let hits = { (text: String) in Self.bannedWords.filter { self.matches($0.pattern, text) }.count }
        for bad in ["Retry", "Try now", "Spoiler-free on", "Scores hidden · spoiler-free is on", "Back to channels",
                    "Your sports", "Live scores are not available", "the sports feed", "Tailscale is connected",
                    "the provider stream", "The server returned HTTP \\(status).", "from Keychain (\\(status))", "Done!"] {
            XCTAssertGreaterThan(hits(bad), 0, bad)
        }
        for fine in ["Try again", "Retry-After", "settings.sport.spoilerFree", "Close player", "Hide scores", "Scores hidden",
                     "Your sport", "the scores feed", "Also in your sports", "a != b", "Back to Sport"] {
            XCTAssertEqual(hits(fine), 0, fine)
        }
    }

    /// Figures a person reads (brand §14, #190, #280): each place one is drawn, with how many lines after it may carry
    /// `.pigFigures()` (a modifier on the stack around it counts).
    static let figureSites: [(file: String, needle: String, within: Int)] = [
        ("CustomPlayer.swift", "Text(now.formatted(", 1), ("CustomPlayer.swift", "Text(programme?.start.formatted(", 1),
        ("CustomPlayer.swift", "behind live\")", 1), ("PlayerExtras.swift", "Text(now.formatted(", 2),
        ("RecordingPlayer.swift", "Text(RecordingTimeline.clock(", 7), ("RecordingTouchChrome.swift", "Text(RecordingTimeline.clock(", 2),
        ("RecordingTouchChrome.swift", "Text(\"−\" + RecordingTimeline.clock(", 2),
        ("SportGameCard.swift", "Text(scores[index])", 1), ("SportGameCard.swift", "Text(SportFrontText.cardClock(", 1),
        ("SportFrontPhonePage.swift", "Text(score)", 1), ("SportPhonePage.swift", "Text(score)", 1),
        ("CricketPageView.swift", "Text(score)", 1), ("SportFixtureView.swift", "Text(score)", 1),
        ("SportEventsViews.swift", "Text(games)", 1), ("SportEventsViews.swift", "Text(toPar)", 1),
        ("SportMotorViews.swift", "Text(points)", 1), ("SportMotorViews.swift", "Text(String(row.pos))", 1),
        ("DetailComponents.swift", "Text(verbatim: number)", 1), ("OnNowList.swift", "Text(programme.timeRange)", 1),
        ("ContentView.swift", "RetryCountdown.text(", 2), ("PageStateViews.swift", "Text(countdown(", 2),
        ("RecordPage.swift", "Text(RecordPlan.chipTitle(selection", 1), ("RecordPage.swift", "chipTitle(minutes)).lineLimit", 1),
        ("GuideChrome.swift", "Text(times)", 1), ("SportFollowSettingsView.swift", "Text(seconds.map(ScoreDelay.text)", 1),
        ("ScheduledPage.swift", "Text(item.start.formatted(", 4), ("DetailScreens.swift", "Text(programme.durationText)", 1),
        ("SignInView.swift", "Text(\"\\(number)\")", 1),
    ]

    // Brand §5 and §14 (maroge1990/PigTV#190, #280): every figure is set in rounded tabular numerals through one helper
    // (`pigFigures()`, PigBrandRoles.swift). Before Apple 206, 37 of 71 figure sites had tabular digits without the
    // rounded design, and the live player's clock had neither.
    func testFiguresUseRoundedTabularNumeralsThroughOneHelper() throws {
        let lines = try sourceLines()
        report(lines.filter { $0.file != Self.rolesFile && matches(#"\.monospacedDigit\(\)|fontDesign\(\.rounded\)"#, $0.text) },
               "a figure styled by hand (use .pigFigures())")
        var missing: [Line] = []
        for site in Self.figureSites {
            let file = lines.filter { $0.file == site.file }
            let hits = file.indices.filter { file[$0].text.contains(site.needle) }
            if hits.isEmpty { missing.append(Line(file: site.file, number: 0, text: "not found: \(site.needle)")) }
            for index in hits where !file[index..<min(file.count, index + site.within)].contains(where: { $0.text.contains(".pigFigures()") }) {
                missing.append(file[index])
            }
        }
        report(missing, "a figure without rounded tabular numerals (add .pigFigures())")
    }

    // Apple's design checklist and brand 1.8 §16 (maroge1990/PigTV#280): two named animations (`PigMotion.standard`,
    // `PigMotion.momentum`, PigMotion.swift) instead of hand-picked durations, and a slide becomes a fade under Reduce
    // Motion (`pigSlide(from:)`). A line marked `// motion: <reason>` keeps its own timing (the splash's brand cycle, the
    // television's focus lift, a countdown's clock, the placeholders' pulse). Before Apple 206 the views used ten
    // durations from 0.12 to 0.25 s, three bare `withAnimation {}` and six slides that ignored Reduce Motion.
    func testAnimationsComeFromTheTwoNamedOnes() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        var found: [Line] = []
        for name in names where name != "PigMotion.swift" {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
            for (index, raw) in text.components(separatedBy: "\n").enumerated() where !raw.contains("// motion:") {
                let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                if Self.handPickedAnimation(code) { found.append(Line(file: name, number: index + 1, text: code)) }
            }
        }
        report(found, "a hand-picked animation (use PigMotion.standard or .momentum, .pigAnimation(value:), .pigSlide(from:))")
    }

    static func handPickedAnimation(_ code: String) -> Bool {
        let patterns = [#"\.(easeIn|easeOut|easeInOut|linear|spring|smooth|snappy|bouncy|interactiveSpring)\b"#,
                        #"\bwithAnimation\s*\{"#, #"\.animation\(\s*\.default\b"#, #"\.move\(edge:"#,
                        #"\banimate\([^)]*duration:\s*[0-9]"#, #"\bduration:\s*[0-9]"#]
        return patterns.contains { code.range(of: $0, options: .regularExpression) != nil }
    }

    func testAnimationParser() {
        for bad in [".animation(.easeOut(duration: 0.15), value: x)", "withAnimation { a = b }", ".transition(.move(edge: .top))",
                    "animator.animate(to: x, duration: 0.2)", "withAnimation(.spring(duration: 0.3)) {}"] {
            XCTAssertTrue(Self.handPickedAnimation(bad), bad)
        }
        for fine in [".pigAnimation(value: x)", "withAnimation(PigMotion.standard) { a = b }", ".pigSlide(from: .top)",
                     "animator.animate(to: x, duration: PigMotion.standardDuration)", ".transition(.opacity)"] {
            XCTAssertFalse(Self.handPickedAnimation(fine), fine)
        }
    }

    // #243: font sizes come from PigType's roles; the weight and design stay at the call site.
    func testFontSizesComeFromTheTypeScale() throws {
        report(try sourceFiles().filter { $0.file != Self.rolesFile }.flatMap { file in
            Self.literals(in: file.code, kind: .fontSize).map { file.line($0.offset) }
        }, "a literal font size (use PigType.caption/kicker/secondary/body/cardTitle/sectionTitle/display/pageTitle/hero)")
    }

    /// A source file with its `//` comments removed (line breaks kept, so offsets map back to lines).
    private struct SourceFile {
        let file: String
        let code: String
        func line(_ offset: Int) -> Line {
            let number = code.prefix(offset).filter { $0 == "\n" }.count + 1
            let text = code.components(separatedBy: "\n")[number - 1]
            return Line(file: file, number: number, text: text)
        }
    }

    private func sourceFiles() throws -> [SourceFile] {
        Dictionary(grouping: try sourceLines(), by: \.file).map { file, lines in
            SourceFile(file: file, code: lines.sorted { $0.number < $1.number }.map(\.text).joined(separator: "\n"))
        }.sorted { $0.file < $1.file }
    }

    enum LiteralKind { case padding, spacing, fontSize }

    /// The bare, non-zero numbers in `.padding(...)`'s arguments, a `spacing:` expression or a `.system(size:` expression
    /// (every arm of a ternary), with their character offsets in `text`. Expressions may span lines.
    static func literals(in text: String, kind: LiteralKind) -> [(literal: String, offset: Int)] {
        let chars = Array(text)
        var found: [(String, Int)] = []
        let number = try! NSRegularExpression(pattern: #"(?<![A-Za-z_0-9.])-?[0-9]+(\.[0-9]+)?(?![A-Za-z_0-9.])"#)
        func scan(_ from: Int, _ to: Int) {
            let inside = String(chars[from..<to])
            for m in number.matches(in: inside, range: NSRange(inside.startIndex..., in: inside)) {
                guard let r = Range(m.range, in: inside) else { continue }
                let before = inside[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if before.hasSuffix("*") || before.hasSuffix("/") { continue }
                if Double(inside[r]) == 0 { continue }
                found.append((String(inside[r]), from + inside.distance(from: inside.startIndex, to: r.lowerBound)))
            }
        }
        let pattern: String
        switch kind {
        case .padding: pattern = #"\.padding\("#
        case .spacing: pattern = #"\bspacing:"#
        case .fontSize: pattern = #"\.system\(\s*size:"#
        }
        let opener = try! NSRegularExpression(pattern: pattern)
        for m in opener.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: r.upperBound)
            var depth = 0, end = start, content = false
            // .padding( runs to its closing parenthesis; spacing: and size: to the next top-level comma or closer, or
            // the end of the line once the value has begun (a value may start on the next line)
            while end < chars.count {
                let c = chars[end]
                if c == "(" || c == "[" { depth += 1 }
                else if c == ")" || c == "]" { if depth == 0 { break }; depth -= 1 }
                else if c == ",", depth == 0, kind != .padding { break }
                else if c == "\n", depth == 0, kind != .padding, content { break }
                if !c.isWhitespace { content = true }
                end += 1
            }
            // (a declaration `static let spacing: CGFloat = PigSpacing.l` ends at its line, and its value is checked too)
            scan(start, end)
        }
        return found
    }

    /// The offsets of `.buttonStyle(.bordered)` calls, however they are spaced over lines.
    static func borderedStyles(in text: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"\.buttonStyle\(\s*\.bordered\s*\)"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }
    }

    /// The code compiled for tvOS: lines in an `#if os(iOS)` (or `!os(tvOS)`) branch, or in the `#else` of an
    /// `#if os(tvOS)`, are blanked, and so are the directives; line breaks are kept, so offsets map back to lines. Other
    /// conditions (DEBUG, canImport) count as compiled.
    static func tvOSCode(_ text: String) -> String {
        // Per open #if: is this branch compiled for tvOS; was an earlier branch an os(tvOS) one; are the branches os checks.
        var stack: [(active: Bool, tvTaken: Bool, osGroup: Bool)] = []
        func tvCondition(_ condition: String) -> (active: Bool, isOS: Bool, tv: Bool) {
            let c = condition.replacingOccurrences(of: " ", with: "")
            if c == "os(tvOS)" { return (true, true, true) }
            if c == "!os(tvOS)" || c == "os(iOS)" || (c.contains("os(iOS)") && !c.contains("tvOS")) { return (false, true, false) }
            return (true, false, false)
        }
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") || line == "#if" {
                let t = tvCondition(String(line.dropFirst(3)))
                stack.append((t.active, t.tv, t.isOS)); out.append(""); continue
            }
            if line.hasPrefix("#elseif"), let top = stack.popLast() {
                let t = tvCondition(String(line.dropFirst(7)))
                stack.append((!top.tvTaken && t.active, top.tvTaken || t.tv, top.osGroup || t.isOS)); out.append(""); continue
            }
            if line.hasPrefix("#else"), let top = stack.popLast() {
                stack.append((top.osGroup ? !top.tvTaken : true, top.tvTaken, top.osGroup)); out.append(""); continue
            }
            if line.hasPrefix("#endif") { _ = stack.popLast(); out.append(""); continue }
            out.append(stack.allSatisfy(\.active) ? raw : "")
        }
        return out.joined(separator: "\n")
    }

    /// Each `struct …: ButtonStyle` (or PrimitiveButtonStyle) with its body (to the matching brace) and offset.
    static func buttonStyles(in text: String) -> [(name: String, body: String, offset: Int)] {
        let regex = try! NSRegularExpression(pattern: #"struct\s+(\w+)[^{]*:\s*[^{]*\b(Primitive)?ButtonStyle\b[^{]*\{"#)
        let chars = Array(text)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text) else { return nil }
            let start = text.distance(from: text.startIndex, to: whole.upperBound)
            var depth = 1, end = start
            while end < chars.count, depth > 0 {
                if chars[end] == "{" { depth += 1 } else if chars[end] == "}" { depth -= 1 }
                end += 1
            }
            return (String(text[name]), String(chars[start..<end]), text.distance(from: text.startIndex, to: whole.lowerBound))
        }
    }

    /// Offsets of a focus look drawn by hand: the accent chosen on focus (a ring or a fill), or a scale or shadow that
    /// follows focus.
    static func handDrawnFocus(in text: String) -> [Int] {
        let patterns = [#"\b(focused|isFocused|lit)\s*\?\s*Color\.pigAccent\b"#, #"\.scaleEffect\([^)\n]*\b(focused|isFocused)\b"#,
                        #"\.shadow\([^\n]*\b(focused|isFocused)\b"#,
                        // a ring shown by fading it in on focus (PigFocusModifier's own way, allowed only in PigFocus.swift)
                        #"\.opacity\(\s*(focused|isFocused)\s*\?"#]
        return patterns.flatMap { pattern in
            try! NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
            }
        }.sorted()
    }

    func testFocusParsers() {
        let tv = Self.tvOSCode("a\n#if os(tvOS)\nb\n#else\nc\n#endif\n#if os(iOS)\nd\n#elseif os(tvOS)\ne\n#endif\n#if DEBUG\nf\n#else\ng\n#endif")
        XCTAssertEqual(tv.components(separatedBy: "\n").filter { !$0.isEmpty }, ["a", "b", "e", "f", "g"])
        XCTAssertEqual(tv.components(separatedBy: "\n").count, 16, "line breaks are kept")
        let styles = Self.buttonStyles(in: "private struct X: ButtonStyle {\n  var a = { 1 }\n  func f() {}\n}\nstruct Y: View {}")
        XCTAssertEqual(styles.map(\.name), ["X"])
        XCTAssertTrue(styles[0].body.contains("func f()"))
        XCTAssertFalse(styles[0].body.contains("struct Y"))
        XCTAssertEqual(Self.handDrawnFocus(in: ".overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }").count, 1)
        XCTAssertEqual(Self.handDrawnFocus(in: ".scaleEffect(focused ? 1.03 : 1)").count, 1)
        XCTAssertEqual(Self.handDrawnFocus(in: ".background(focused ? PigFocus.fill : Color.pigRaised)").count, 0)
        XCTAssertEqual(Self.handDrawnFocus(in: "shape.strokeBorder(Color.pigAccent, lineWidth: 3).opacity(focused ? 1 : 0)").count, 1)
    }

    static func spacingLiterals(in text: String) -> [String] {
        (literals(in: text, kind: .padding) + literals(in: text, kind: .spacing)).sorted { $0.offset < $1.offset }.map(\.literal)
    }

    func testSpacingParser() {
        XCTAssertEqual(Self.spacingLiterals(in: "VStack(spacing: 12) {"), ["12"])
        XCTAssertEqual(Self.spacingLiterals(in: ".padding(.horizontal, wide ? 24 : PigSpacing.m)"), ["24"])
        XCTAssertEqual(Self.spacingLiterals(in: ".padding(-6)"), ["-6"])
        XCTAssertEqual(Self.spacingLiterals(in: "HStack(spacing: 0) { }.padding(PigSpacing.l * 2)"), [])
        XCTAssertEqual(Self.spacingLiterals(in: ".padding(EdgeInsets(top: 26, leading: PigSpacing.m, bottom: 0, trailing: 0))"), ["26"])
        XCTAssertEqual(Self.spacingLiterals(in: "GridItem(.flexible(minimum: 0), spacing: PigSpacing.xl, alignment: .top)"), [])
        XCTAssertEqual(Self.spacingLiterals(in: "Text(\"x\").lineSpacing(4).padding(.top, PigSpacing.empty)"), [])
        // over several lines (Codex round 1)
        XCTAssertEqual(Self.spacingLiterals(in: ".padding(\n    19\n)"), ["19"])
        XCTAssertEqual(Self.spacingLiterals(in: "VStack(alignment: .leading,\n       spacing:\n       14) {"), ["14"])
        XCTAssertEqual(Self.spacingLiterals(in: "static let spacing: CGFloat = PigSpacing.l\nstatic let width: CGFloat = 1100"), [])
        XCTAssertEqual(Self.spacingLiterals(in: "static let spacing: CGFloat = 14\nstatic let width: CGFloat = 1100"), ["14"])
    }

    func testFontAndBorderedParsers() {
        let font = { (text: String) in Self.literals(in: text, kind: .fontSize).map(\.literal) }
        XCTAssertEqual(font(".font(.system(size: 19))"), ["19"])
        XCTAssertEqual(font(".font(.system(size: wide ? PigType.body : 19, weight: .bold))"), ["19"])
        XCTAssertEqual(font(".font(.system(\n    size: 22,\n    weight: .bold))"), ["22"])
        XCTAssertEqual(font(".font(.system(size: PigType.body, weight: .semibold))"), [])
        XCTAssertEqual(font(".font(.system(size: badge * 0.4, weight: .heavy))"), [])
        XCTAssertEqual(Self.borderedStyles(in: "Button(\"x\") {}\n    .buttonStyle(\n        .bordered\n    )").count, 1)
        XCTAssertEqual(Self.borderedStyles(in: ".buttonStyle(.borderedProminent)").count, 0)
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
