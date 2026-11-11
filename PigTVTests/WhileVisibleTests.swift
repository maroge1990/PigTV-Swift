import XCTest
import SwiftUI
import Combine
@testable import PigTV

// Audit F4: nothing under the full-screen player keeps polling.
final class WhileVisibleTests: XCTestCase {
    func testTheRuleRunsOnlyWhenVisibleAllowedAndNotCovered() {
        for visible in [false, true] {
            for condition in [false, true] {
                for covered in [false, true] {
                    XCTAssertEqual(WhileVisibleRule.runs(visible: visible, condition: condition, covered: covered),
                                   visible && condition && !covered,
                                   "visible \(visible), condition \(condition), covered \(covered)")
                }
            }
        }
        XCTAssertFalse(WhileVisibleRule.runs(visible: true, condition: true, covered: true), "a cover stops the work")
        XCTAssertTrue(WhileVisibleRule.runs(visible: true, condition: true, covered: false))
    }

    @MainActor func testTheEnvironmentValueDefaultsToFalse() {
        XCTAssertFalse(EnvironmentValues().pigCoveredByPlayer)
    }

    // The modifier hosted in a window: covered turns the work off, uncovered starts it again.
    @MainActor
    func testTheWorkStopsWhenCoveredAndRestartsWhenUncovered() async throws {
        final class Probe: ObservableObject {
            @Published var covered = false
            var active = 0
            var running: Bool { active > 0 }
            var starts = 0
        }
        struct Inner: View {
            let probe: Probe
            var body: some View {
                Color.clear
                    .whileVisible {
                        probe.active += 1; probe.starts += 1
                        defer { probe.active -= 1 }
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                    }
            }
        }
        struct Page: View {
            @ObservedObject var probe: Probe
            var body: some View { Inner(probe: probe).environment(\.pigCoveredByPlayer, probe.covered) }
        }
        let probe = Probe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "no window scene in the test host")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let host = UIHostingController(rootView: Page(probe: probe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func wait(_ what: String, _ ok: @MainActor () -> Bool) async throws {
            let end = Date().addingTimeInterval(5)
            while !ok() && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(ok(), what)
        }
        try await wait("starts when visible") { probe.running }
        probe.covered = true
        try await wait("stops when covered") { !probe.running }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(probe.running, "and stays stopped while covered")
        let before = probe.starts
        probe.covered = false
        try await wait("restarts when uncovered") { probe.running && probe.starts > before }
        window.isHidden = true
    }
}
