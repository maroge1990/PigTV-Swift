import SwiftUI
import UIKit
import XCTest
@testable import PigTV

// maroge1990/PigTV#280, the last package of batch L (Apple 206): words, the launch, Increase Contrast and Reduce
// Transparency, the league colours, the guide's status marks, motion, haptics, the timers that stood in for events (#49)
// and Settings › Sport's order. The source scans for figures, sizes, banned words and animations are in BrandRulesTests.
// Before 206 none of these types existed (each test fails to compile on 205).
@MainActor
final class PolishTests: XCTestCase {
    private static let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PigTV/Assets.xcassets")

    // MARK: 1. Words: no system text, status or code on screen

    func testAnErrorIsShownInPlainWordsNeverTheSystemsTextOrACode() {
        let keychain = NSError(domain: NSOSStatusErrorDomain, code: -25300,
                               userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (OSStatus error -25300.)"])
        let other = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                            userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed (AVFoundationErrorDomain -11800)"])
        for error in [keychain, other] {
            let text = UserMessage.text(for: error) ?? ""
            XCTAssertEqual(text, UserMessage.somethingFailed)
            XCTAssertFalse(text.contains("-"), text)
        }
        XCTAssertEqual(UserMessage.text(for: other, otherwise: "This recording couldn’t be loaded."), "This recording couldn’t be loaded.")
        XCTAssertEqual(UserMessage.text(for: URLError(.notConnectedToInternet)), UserMessage.unreachable)
        XCTAssertFalse(UserMessage.unreachable.contains("Tailscale"))
        XCTAssertNil(UserMessage.text(for: URLError(.cancelled)), "a cancelled request is not a failure")
        // A sentence the server wrote for people is shown as sent.
        XCTAssertEqual(UserMessage.text(for: PigTVError.serverMessage("That channel is offline.", status: 502)), "That channel is offline.")
        let cases: [PigTVError] = [.invalidServerURL, .unauthorised, .forbidden, .http(500), .http(404), .decoding,
                                   .recordingConflict(RecordingConflict(type: "recording", scheduleId: 1, title: "A", channelName: "B", endsAt: 0)),
                                   .recordingPreparationFailed(reason: nil)]
        for error in cases {
            let text = UserMessage.text(for: error) ?? ""
            XCTAssertFalse(text.isEmpty)
            for word in ["HTTP", "500", "404", "credentials", "provider stream", "API", "Please", "!"] {
                XCTAssertFalse(text.contains(word), "\(error): \(text)")
            }
        }
        XCTAssertEqual(PageWords.closePlayer, "Close player", "one name for leaving a player, as the web's")
    }

    // MARK: 2. Splash only while loading

    func testTheSplashShowsOnlyWhileASavedSignInIsRestored() {
        XCTAssertEqual(LaunchStep.opening(hasServerAddress: false, savedSignIn: false), .firstScreen, "first run: sign-in at once")
        XCTAssertEqual(LaunchStep.opening(hasServerAddress: true, savedSignIn: false), .firstScreen,
                       "an address but no saved sign-in: sign-in at once")
        XCTAssertEqual(LaunchStep.opening(hasServerAddress: true, savedSignIn: true), .splash, "a sign-in to restore")
        XCTAssertEqual(LaunchStep.opening(hasServerAddress: true, savedSignIn: nil), .splash,
                       "a sign-in that could not be read: the restore says why, behind the splash")
        let empty = UserDefaults(suiteName: "pigtv.launch.\(UUID().uuidString)")!
        XCTAssertEqual(LaunchStep.current(defaults: empty), .firstScreen, "nothing saved")
        empty.set("not an address", forKey: "pigtv.server")
        XCTAssertEqual(LaunchStep.current(defaults: empty), .firstScreen, "an address that cannot be used")
    }

    // MARK: 5. Increase Contrast and Reduce Transparency

    private func resolved(_ name: String, dark: Bool, high: Bool) throws -> UIColor {
        let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                                                    UITraitCollection(accessibilityContrast: high ? .high : .normal)])
        return try XCTUnwrap(UIColor(named: name, in: Bundle(for: AppModel.self), compatibleWith: nil), name).resolvedColor(with: traits)
    }

    private func components(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { ($0 * 255).rounded() }
    }

    func testIncreasedContrastGivesTheStrongerRoles() throws {
        for dark in [false, true] {
            for (role, takes) in PigContrast.strongerRoles {
                XCTAssertEqual(components(try resolved(role, dark: dark, high: true)), components(try resolved(takes, dark: dark, high: false)),
                               "\(role) under Increase Contrast (\(dark ? "dark" : "light"))")
                XCTAssertNotEqual(components(try resolved(role, dark: dark, high: false)), components(try resolved(takes, dark: dark, high: false)),
                                  "\(role) keeps its own value normally")
            }
            let normal = components(try resolved("PigSelection", dark: dark, high: false))[3]
            let strong = components(try resolved("PigSelection", dark: dark, high: true))[3]
            XCTAssertEqual(normal, (PigContrast.selectionOpacity.normal * 255).rounded())
            XCTAssertEqual(strong, (PigContrast.selectionOpacity.increased * 255).rounded(), "the selection tint is stronger")
        }
        XCTAssertNil(PigContrast.cardBorder(increased: false), "no card border normally")
        XCTAssertEqual(PigContrast.cardBorder(increased: true), Color.pigControlBoundary, "the Control boundary under Increase Contrast")
        XCTAssertEqual(PigContrast.translucentFill(reduceTransparency: false).opacity, 0.85)
        XCTAssertEqual(PigContrast.translucentFill(reduceTransparency: true).opacity, 1, "solid under Reduce Transparency")
        XCTAssertTrue(PigContrast.translucentFill(reduceTransparency: true).border)
    }

    // MARK: 6. League colours and status marks

    private static func luminance(_ c: [Double]) -> Double {
        let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
    }

    static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Every appearance's colour in a colorset, read from the catalogue's source.
    private func appearances(_ name: String) throws -> [[Double]] {
        let url = Self.catalog.appendingPathComponent("\(name).colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], name)
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        return try colors.map { entry in
            let parts = try XCTUnwrap((entry["color"] as? [String: Any])?["components"] as? [String: String])
            return try ["red", "green", "blue"].map { try XCTUnwrap(Double(parts[$0] ?? "")) }
        }
    }

    func testEveryLeagueColourKeepsItsWhiteLettersAtFourAndAHalfToOne() throws {
        let white = try XCTUnwrap(appearances("PigMediaText").first) // pigOnStatus, the letters on a disc
        let leagues = ["NFL", "F1", "NBA", "AFL", "AFLW", "Cricket", "EPL", "MLB", "NRL", "a league with no colour"]
        for league in leagues {
            let name = SportFrontText.leagueColorName(league)
            let values = try appearances(name)
            XCTAssertEqual(values.count, 2, "\(name): a light and a dark value")
            for value in values {
                XCTAssertGreaterThanOrEqual(Self.contrast(value, white), 4.5, "\(league) (\(name))")
            }
        }
        XCTAssertEqual(SportFrontText.leagueColorName("a league with no colour"), "LeagueOther")
    }

    func testGuideStatusIsAShapeAndWordsNotColourAlone() {
        let marks = GuideStatusMark.allCases
        XCTAssertEqual(Set(marks.map(\.symbol)).count, marks.count, "each mark has its own shape")
        XCTAssertEqual(Set(marks.map(\.words)).count, marks.count)
        XCTAssertFalse(marks.contains { $0.symbol == "circle.fill" }, "not a plain dot")
    }

    // MARK: 7. Motion and haptics

    func testTwoNamedAnimationsAndReduceMotion() {
        XCTAssertNil(PigMotion.animation(moves: true, reduceMotion: true), "a change that moves has none under Reduce Motion")
        XCTAssertNotNil(PigMotion.animation(moves: false, reduceMotion: true), "a fade keeps the standard one")
        XCTAssertEqual(PigMotion.animation(moves: true, reduceMotion: false), PigMotion.standard)
        XCTAssertEqual(PigMotion.animation(moves: true, momentum: true, reduceMotion: false), PigMotion.momentum)
        XCTAssertNotEqual(PigMotion.standard, PigMotion.momentum)
        XCTAssertEqual(PigPress.opacity(pressed: true), 0.6, "a pressed card dims")
        XCTAssertEqual(PigPress.scale(pressed: true, reduceMotion: false), 0.98)
        XCTAssertEqual(PigPress.scale(pressed: true, reduceMotion: true), 1, "and does not move under Reduce Motion")
    }

    func testRecordFollowAndDeleteAreFeltOnTouchOnly() async throws {
        XCTAssertEqual(PigHaptic.feedback(for: .record, television: false), .success)
        XCTAssertEqual(PigHaptic.feedback(for: .follow, television: false), .success)
        XCTAssertEqual(PigHaptic.feedback(for: .delete, television: false), .lightImpact)
        for event in [PigHaptic.record, .follow, .delete] { XCTAssertNil(PigHaptic.feedback(for: event, television: true)) }
        // Deleting a recording plays the delete feedback (where the action is taken, before its Undo).
        var played: [PigHaptic] = []
        PigHaptic.observer = { played.append($0) }
        defer { PigHaptic.observer = nil }
        let http = try LocalHTTPServer { _ in .json("[]") }
        defer { http.stop() }
        let model = BrowseModel(client: APIClient(address: try ServerAddress(http.baseURL), token: "fixture", accountID: 1), accountID: 1)
        model.removalLog = PendingRemovalLog(defaults: UserDefaults(suiteName: "pigtv.haptic.\(UUID().uuidString)")!)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        model.recordings = [recording]
        let presenter = AppPresenter()
        presenter.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        model.deleteWithUndo(recording, presenter: presenter)
        XCTAssertEqual(played, [.delete])
        presenter.undoPending()
    }

    // MARK: 8. Timers that stood in for events (#49)

    func testAPendingStepWaitsForItsEventNotATimer() {
        // Settings › Sport: the new sport's page opens when Add a sport's page has closed (its onDismiss), once.
        var afterClose = PendingUntil<String>()
        XCTAssertNil(afterClose.take(), "nothing asked: the page closing opens nothing")
        afterClose.request("Tennis")
        XCTAssertEqual(afterClose.take(), "Tennis", "the dismissal opens it")
        XCTAssertNil(afterClose.take(), "once")
        // Sign in: the field is focused when its step appears, only the step that was asked for.
        var field = PendingUntil<SignInStep>()
        field.request(.password)
        XCTAssertFalse(field.take(when: .method), "another step appearing is not the event")
        XCTAssertTrue(field.take(when: .password))
        XCTAssertFalse(field.take(when: .password), "once")
    }

    // MARK: 9. Settings › Sport: common choices first

    func testSettingsSportPutsWhatYouFollowAndHideScoresFirst() {
        let parts = SettingsSportOrder.parts(empty: false, suggestions: true, canAdd: true, scoreDelay: true)
        XCTAssertEqual(Array(parts.prefix(2)), [.hideScores, .yourSport])
        XCTAssertEqual(parts.last, .scoreDelay, "Score delay is one level down, last")
        XCTAssertEqual(SettingsSportOrder.parts(empty: true, suggestions: true, canAdd: true, scoreDelay: false),
                       [.hideScores, .yourSport, .empty], "nothing followed: E1 and its Add a sport")
        XCTAssertFalse(SettingsSportOrder.parts(empty: false, suggestions: false, canAdd: false, scoreDelay: false).contains(.scoreDelay),
                       "no row on a server that keeps no score delay")
    }
}
