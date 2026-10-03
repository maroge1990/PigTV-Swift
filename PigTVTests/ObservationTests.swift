import XCTest
import Combine
@testable import PigTV

// Audit R05: what each screen observes. A screen's body is re-evaluated when
// an object it observes publishes, so the number of publishes of the objects
// a screen watches is the (upper bound of the) number of times that screen
// re-renders for an event. `observedBy` names those objects per screen; keep
// it in step with the views' initialisers.

private final class RoutedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (String) -> String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.routes.first { path.hasSuffix($0.key) }?.value(request.httpMethod ?? "GET") ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private extension BrowseModel {
    var observedBy: [String: [ObservableObjectPublisher]] {
        [
            "Home": [home.objectWillChange],
            "Guide": [guideStore.objectWillChange, library.objectWillChange, marks.objectWillChange],
            "Recordings": [recordingStore.objectWillChange, actions.objectWillChange],
            "ProgrammeDetails": [recordingStore.objectWillChange, actions.objectWillChange, artwork.objectWillChange],
            "SportCards": []
        ]
    }
}

@MainActor
final class ObservationTests: XCTestCase {
    private var guideCalls = 0
    private var recordingsJSON = #"[{"id":1,"title":"News","status":"completed","channel_name":"A"}]"#
    private var favouritesJSON = #"[{"id":"a","sourceId":1,"name":"A"}]"#

    private func makeBrowse() throws -> BrowseModel {
        guideCalls = 0
        RoutedProtocol.routes = [
            "library/guide": { [unowned self] _ in
                self.guideCalls += 1
                let n = self.guideCalls
                let next = n < 3 ? #","nextCursor":"p\#(n + 1)""# : ""
                return #"{"total":6,"channels":[{"id":"c\#(n)a","sourceId":1,"name":"A\#(n)","programmes":[]},{"id":"c\#(n)b","sourceId":1,"name":"B\#(n)","programmes":[]}]\#(next)}"#
            },
            "recordings": { [unowned self] _ in self.recordingsJSON },
            "recordings/scheduled": { _ in "[]" },
            "library/favourites": { [unowned self] _ in self.favouritesJSON },
            "library/recent": { _ in #"[{"id":"a","sourceId":1,"name":"A"}]"# },
            "favorites": { _ in #"{"success":true}"# }
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedProtocol.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"1","apiVersion":1,"features":{"library":true,"playbackResolve":true,"guideCursor":true}}"#.utf8))
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration), info: info)
        return BrowseModel(client: client, accountID: 1,
                           guideCacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("obs-\(UUID())"))
    }

    /// Publishes seen per screen while `event` runs.
    private func measure(_ browse: BrowseModel, _ event: () async -> Void) async -> [String: Int] {
        var counts: [String: Int] = [:]
        var bag: [AnyCancellable] = []
        for (screen, publishers) in browse.observedBy {
            counts[screen] = 0
            for publisher in publishers {
                bag.append(publisher.sink { counts[screen, default: 0] += 1 })
            }
        }
        await event()
        try? await Task.sleep(for: .milliseconds(50))
        withExtendedLifetime(bag) {}
        return counts
    }

    private func report(_ event: String, _ counts: [String: Int]) {
        let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        // xcodebuild hides test stdout; the simulator shares the host's /tmp.
        let text = "OBSERVATION | \(event) | \(line)\n"
        let path = "/tmp/pigtv-observation.txt"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        }
    }

    func testReport() async throws {
        let browse = try makeBrowse()
        browse.home.activate(lastWatched: nil)
        report("guide pages (3)", await measure(browse) { await browse.loadGuide(); try? await Task.sleep(for: .milliseconds(300)) })
        await browse.loadRecordings(); await browse.loadFavourites(); await browse.loadRecent()
        try await Task.sleep(for: .milliseconds(200)) // Home's rebuild for that first data
        report("recordings refresh (unchanged)", await measure(browse) { await browse.loadRecordings() })
        report("recordings refresh (unchanged, quiet)", await measure(browse) { await browse.loadRecordings(quietly: true) })
        recordingsJSON = #"[{"id":1,"title":"News","status":"recording","channel_name":"A"}]"#
        report("recordings refresh (status changed)", await measure(browse) { await browse.loadRecordings() })
        favouritesJSON = #"[{"id":"a","sourceId":1,"name":"A"},{"id":"b","sourceId":1,"name":"B"}]"#
        let channel = Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil)
        report("favourite toggle", await measure(browse) { _ = await browse.setFavourite(channel, true) })
        report("Home 60 s tick (unchanged)", await measure(browse) { await browse.loadRecent(); await browse.loadRecordings(quietly: true); browse.home.rebuild() })
    }

    // MARK: Assertions

    private func publishes(_ publisher: ObservableObjectPublisher, during event: () async -> Void) async -> Int {
        var count = 0
        let token = publisher.sink { count += 1 }
        await event()
        try? await Task.sleep(for: .milliseconds(50))
        withExtendedLifetime(token) {}
        return count
    }

    func testAGuidePageDoesNotPublishTheOtherStores() async throws {
        let browse = try makeBrowse()
        var others = 0
        let tokens = [browse.recordingStore.objectWillChange, browse.library.objectWillChange, browse.marks.objectWillChange,
                      browse.actions.objectWillChange, browse.artwork.objectWillChange].map { $0.sink { others += 1 } }
        let guide = await publishes(browse.guideStore.objectWillChange) {
            await browse.loadGuide()
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertGreaterThan(guide, 0)
        XCTAssertEqual(browse.guide.count, 6)
        XCTAssertEqual(others, 0, "a guide page re-renders nothing that only draws recordings, favourites or actions")
        withExtendedLifetime(tokens) {}
    }

    func testRecordingsAndFavouritesLoadsDoNotPublishTheGuide() async throws {
        let browse = try makeBrowse()
        await browse.loadGuide()
        try await Task.sleep(for: .milliseconds(300))
        let guide = await publishes(browse.guideStore.objectWillChange) {
            await browse.loadRecordings()
            await browse.loadFavourites()
            await browse.loadRecent()
            _ = await browse.setFavourite(Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil), true)
        }
        XCTAssertEqual(guide, 0)
        XCTAssertEqual(browse.recordings.count, 1)
        XCTAssertEqual(browse.favourites.count, 1)
    }

    func testAFavouriteChangeDoesNotPublishRecordings() async throws {
        let browse = try makeBrowse()
        await browse.loadRecordings()
        await browse.loadFavourites()
        let recordings = await publishes(browse.recordingStore.objectWillChange) {
            favouritesJSON = #"[{"id":"a","sourceId":1,"name":"A"},{"id":"b","sourceId":1,"name":"B"}]"#
            await browse.loadFavourites()
        }
        XCTAssertEqual(recordings, 0)
        XCTAssertEqual(browse.favourites.count, 2)
    }

    func testAQuietRefreshThatFindsNothingNewPublishesNothing() async throws {
        let browse = try makeBrowse()
        await browse.loadRecordings()
        await browse.loadFavourites()
        await browse.loadRecent()
        let recordings = await publishes(browse.recordingStore.objectWillChange) { await browse.loadRecordings(quietly: true) }
        let marks = await publishes(browse.marks.objectWillChange) { await browse.loadRecordings() }
        let library = await publishes(browse.library.objectWillChange) { await browse.loadFavourites(); await browse.loadRecent() }
        XCTAssertEqual(recordings, 0)
        XCTAssertEqual(marks, 0, "equal schedules leave the marks alone")
        XCTAssertEqual(library, 0, "the busy and error state of the favourites load is not drawn, so it is not published")
    }

    func testScheduleMarksFollowTheSchedules() async throws {
        let browse = try makeBrowse()
        let json = #"[{"id":1,"title":"T","channel_name":"A","program_start":1000,"program_end":2000,"status":"recording"},{"id":2,"title":"U","channel_name":"B","program_start":3000,"program_end":4000,"status":"scheduled"},{"id":3,"title":"V","channel_name":"C","program_start":5000,"program_end":6000,"status":"missed"}]"#
        browse.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(json.utf8))
        XCTAssertEqual(browse.scheduledKeys, ["A|1000", "B|3000"])
        XCTAssertEqual(browse.recordingChannels, ["A"])
    }

    // MARK: Home

    private func home(_ browse: BrowseModel) -> HomeModel {
        let home = HomeModel(browse: browse, guideDelay: .milliseconds(20))
        home.activate(lastWatched: nil)
        return home
    }

    func testHomePublishesNothingWhenItsInputsAreEqual() async throws {
        let browse = try makeBrowse()
        await browse.loadRecordings(); await browse.loadFavourites(); await browse.loadRecent()
        let home = home(browse)
        XCTAssertEqual(home.content.recordings.map(\.id), [1])
        let built = home.rebuilds
        let published = await publishes(home.objectWillChange) {
            // The same data again, however it arrives.
            await browse.loadRecordings(); await browse.loadFavourites(); await browse.loadRecent()
            browse.recordings = browse.recordings
            browse.favourites = browse.favourites
            browse.recent = browse.recent
            try? await Task.sleep(for: .milliseconds(100))
            home.rebuild() // the minute's tick
        }
        XCTAssertEqual(published, 0)
        XCTAssertEqual(home.rebuilds, built + 1, "only the explicit tick rebuilt; equal inputs scheduled nothing")
    }

    func testHomeContentChangesWhenARecordingsStatusChanges() async throws {
        let browse = try makeBrowse()
        await browse.loadRecordings()
        let home = home(browse)
        XCTAssertEqual(home.content.recordings.first?.status, "completed")
        recordingsJSON = #"[{"id":1,"title":"News","status":"recording","channel_name":"A"}]"#
        await browse.loadRecordings()
        try await eventually { home.content.recordings.first?.status == "recording" }
        XCTAssertEqual(home.content.recordings.map(\.id), [1], "same id, new status")
        // And a field the old id-and-status comparison ignored.
        recordingsJSON = #"[{"id":1,"title":"News","status":"recording","channel_name":"A","native_status":"preparing"}]"#
        await browse.loadRecordings()
        try await eventually { home.content.recordings.first?.native_status == "preparing" }
    }

    func testHomeKeepsItsContentWhileHiddenAndRebuildsOnlyWhatChanged() async throws {
        let browse = try makeBrowse()
        await browse.loadRecordings()
        let home = home(browse)
        let built = home.rebuilds
        home.deactivate()
        // Fresh and unchanged: coming back shows the retained content with no rebuild.
        home.activate(lastWatched: nil)
        XCTAssertEqual(home.rebuilds, built)
        home.deactivate()
        // A change while hidden is not worked on until Home is back.
        recordingsJSON = #"[{"id":1,"title":"News","status":"recording","channel_name":"A"}]"#
        await browse.loadRecordings()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(home.rebuilds, built, "nothing is rebuilt while Home is hidden")
        XCTAssertEqual(home.content.recordings.first?.status, "completed")
        home.activate(lastWatched: nil)
        XCTAssertEqual(home.rebuilds, built + 1)
        XCTAssertEqual(home.content.recordings.first?.status, "recording")
        // Old content is rebuilt (its countdowns move).
        home.deactivate()
        home.refreshIfNeeded(now: Date().addingTimeInterval(HomeModel.maxAge + 1))
        XCTAssertEqual(home.rebuilds, built + 2)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}
