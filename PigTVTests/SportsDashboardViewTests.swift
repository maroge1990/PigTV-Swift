import Combine
import SwiftUI
import XCTest

@testable import PigTV

/// The real SportsDashboardView in a window, on a real model against the local HTTP server, with the scene phase
/// and the selected tab under the test's control (review findings 4, 5, 7 and 8, build 61).
@MainActor
final class SportsDashboardViewTests: XCTestCase {
  private final class Controls: ObservableObject {
    @Published var phase: ScenePhase
    /// The page as a SwiftUI tab, as in LibraryView: a tab that is not selected still gets scene-phase changes
    /// (a UIKit tab bar or a detached view would get none, which would hide the bug).
    let tabbed: Bool
    @Published var tab = "sport"
    init(phase: ScenePhase, tabbed: Bool = false) {
      self.phase = phase
      self.tabbed = tabbed
    }
  }
  private struct Host: View {
    @ObservedObject var controls: Controls
    let app: AppModel
    let browse: BrowseModel
    let model: SportsDashboardModel
    let details: String?
    var body: some View {
      Group {
        if controls.tabbed {
          TabView(selection: $controls.tab) {
            page.tabItem { Text("Sport") }.tag("sport")
            Text("Elsewhere").tabItem { Text("Other") }.tag("other")
          }
        } else {
          page
        }
      }
      .environment(\.scenePhase, controls.phase)
    }
    private var page: some View {
      SportsDashboardView(app: app, browse: browse, model: model, details: details)
    }
  }
  private var windows: [UIWindow] = []
  override func tearDown() async throws {
    for window in windows {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
    }
    windows = []
    try await super.tearDown()
  }

  private func dashboardRequests(_ server: LocalHTTPServer) -> Int {
    server.requests.filter { $0.path == "/api/sports/dashboard" }.count
  }
  private func makeServer() throws -> LocalHTTPServer {
    try LocalHTTPServer { request in
      request.path == "/api/sports/dashboard" ? .json(SportsDashboardTests.payload()) : .notFound
    }
  }
  private func makeModel(_ server: LocalHTTPServer, poll: Duration) throws -> (BrowseModel, SportsDashboardModel) {
    let client = APIClient(
      address: try ServerAddress(server.baseURL), token: "a",
      info: try FakePigTVServer.info(extraFeatures: #""sportsDashboard":true"#), accountID: 1)
    return (BrowseModel(client: client), SportsDashboardModel(client: client, pollInterval: poll))
  }
  private func show(
    _ model: SportsDashboardModel, browse: BrowseModel, controls: Controls, details: String? = nil
  ) -> UIWindow {
    let app = AppModel()
    app.configureClientForTesting(browse.client, browse: browse)
    let root = UIHostingController(
      rootView: Host(controls: controls, app: app, browse: browse, model: model, details: details))
    let window =
      (UIApplication.shared.connectedScenes.first as? UIWindowScene).map { UIWindow(windowScene: $0) }
      ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    window.rootViewController = root
    window.makeKeyAndVisible()
    windows.append(window)
    return window
  }
  /// Polls; instant when the simulator is quick, patient when it is loaded (an iPad simulator just booted).
  private func wait(
    _ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(what)", file: file, line: line)
  }

  /// Finding 4 (and c): opening details and coming back to the page are not a scope change, a background or a
  /// failure, so neither may clear the shelves (tvOS rebuilt every card during focus restoration).
  func testOpeningAndClosingDetailsKeepsTheDashboard() async throws {
    let server = try makeServer()
    defer { server.stop() }
    let (browse, model) = try makeModel(server, poll: .seconds(60))
    _ = await model.load()
    XCTAssertNotNil(model.dashboard)
    var cleared = 0
    let watcher = model.$dashboard.dropFirst().sink { if $0 == nil { cleared += 1 } }
    defer { watcher.cancel() }
    let window = show(model, browse: browse, controls: Controls(phase: .active), details: "game")
    try await wait("details presented") { window.rootViewController?.presentedViewController != nil }
    try await wait("a refresh while details are open") { dashboardRequests(server) >= 2 }
    window.rootViewController?.dismiss(animated: false)
    try await wait("details closed") { window.rootViewController?.presentedViewController == nil }
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(cleared, 0, "Details and reappearance must not hide the shelves")
    XCTAssertNotNil(model.dashboard)
  }

  /// Finding 5: on iOS the details page is a sheet, so the page under it stays "visible"; only one 20 s loop
  /// may run (on tvOS the cover already hides the page, so this passes there either way).
  func testOnlyOnePollingLoopRunsWhileDetailsArePresented() async throws {
    let server = try makeServer()
    defer { server.stop() }
    let (browse, model) = try makeModel(server, poll: .milliseconds(250))
    let window = show(model, browse: browse, controls: Controls(phase: .active), details: "game")
    try await wait("details presented") { window.rootViewController?.presentedViewController != nil }
    try await Task.sleep(for: .milliseconds(600))
    let start = dashboardRequests(server)
    try await Task.sleep(for: .seconds(2.5))
    let made = dashboardRequests(server) - start
    // One loop: about 10 requests in 2.5 s at 250 ms; two loops about 20.
    XCTAssertLessThanOrEqual(made, 14, "Two polling loops ran under the details sheet (\(made) requests)")
    XCTAssertGreaterThanOrEqual(made, 4, "The details page keeps its own refresh")
  }

  /// Finding 7: .inactive (Control Center, a system alert) is not a background: it must not close details.
  func testInactiveSceneKeepsDetailsOpenAndBackgroundClosesThem() async throws {
    let server = try makeServer()
    defer { server.stop() }
    let (browse, model) = try makeModel(server, poll: .seconds(60))
    let controls = Controls(phase: .active)
    let window = show(model, browse: browse, controls: controls, details: "game")
    try await wait("details presented") { window.rootViewController?.presentedViewController != nil }
    try await wait("loaded") { model.dashboard != nil }
    controls.phase = .inactive
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertNotNil(window.rootViewController?.presentedViewController, ".inactive closed the details")
    XCTAssertNotNil(model.dashboard, ".inactive cleared the scores")
    controls.phase = .active
    try await Task.sleep(for: .milliseconds(300))
    controls.phase = .background
    try await wait("background closes details") { window.rootViewController?.presentedViewController == nil }
    try await wait("background clears scores") { model.dashboard == nil }
  }

  /// Finding 7: returning to the foreground while another tab is showing makes no dashboard request; the page
  /// loads when it is shown again.
  func testForegroundWhileHiddenDoesNotLoad() async throws {
    let server = try makeServer()
    defer { server.stop() }
    let (browse, model) = try makeModel(server, poll: .milliseconds(200))
    let controls = Controls(phase: .active, tabbed: true)
    _ = show(model, browse: browse, controls: controls)
    try await wait("first load") { model.dashboard != nil }
    controls.tab = "other"
    // Hidden for certain once its 200 ms polling has stopped (a loaded simulator can deliver the tab's
    // disappearance late).
    var before = dashboardRequests(server)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      try await Task.sleep(for: .seconds(1))
      let now = dashboardRequests(server)
      if now == before { break }
      before = now
    }
    controls.phase = .inactive
    try await Task.sleep(for: .milliseconds(100))
    controls.phase = .background
    try await wait("background clears scores") { model.dashboard == nil }
    controls.phase = .inactive
    try await Task.sleep(for: .milliseconds(100))
    controls.phase = .active
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertEqual(dashboardRequests(server), before, "A hidden tab must not fetch on foreground")
    XCTAssertNil(model.dashboard, "Nothing reloaded the hidden page's scores")
    controls.tab = "sport"
    try await wait("the page loads when shown") { model.dashboard != nil }
  }

  /// Finding 8: first shown while .inactive, the page must start polling once the scene is active.
  func testFirstShownWhileInactiveStartsPollingWhenActive() async throws {
    let server = try makeServer()
    defer { server.stop() }
    let (browse, model) = try makeModel(server, poll: .milliseconds(200))
    let controls = Controls(phase: .inactive)
    _ = show(model, browse: browse, controls: controls)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(dashboardRequests(server), 0, "No polling while inactive")
    controls.phase = .active
    try await wait("polling after becoming active") { dashboardRequests(server) >= 3 }
  }
}
