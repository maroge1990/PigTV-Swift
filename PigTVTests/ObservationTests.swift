import XCTest
@testable import PigTV

// Audit R05: what each screen observes. A screen's body is re-evaluated when a
// store it reads changes, so the number of changes to the stores a screen reads
// is the (upper bound of the) number of times that screen re-renders for an
// event. `observedBy` names those stores per screen; keep it in step with the
// views. #51: counted by `Invalidations`, which sees an ObservableObject's
// publishes and an @Observable store's property changes alike.

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
    /// Per screen, the stores it reads, and its reads of them (all of each: an upper bound).
    var observedBy: [String: (stores: [AnyObject], reads: @MainActor () -> Void)] {
        [
            "Guide": ([guideStore, library, marks], { [self] in
                guideStore.readEverything(); library.readEverything(); marks.readEverything() }),
            "Recordings": ([recordingStore, actions], { [self] in recordingStore.readEverything(); actions.readEverything() }),
            "ProgrammeDetails": ([recordingStore, actions], { [self] in recordingStore.readEverything(); actions.readEverything() }),
            "SportCards": ([], {})
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

    /// Invalidations seen per screen while `event` runs.
    private func measure(_ browse: BrowseModel, _ event: () async -> Void) async -> [String: Int] {
        let counters = browse.observedBy.mapValues { Invalidations(observing: $0.stores, reads: $0.reads) }
        await event()
        try? await Task.sleep(for: .milliseconds(50))
        counters.values.forEach { $0.stop() }
        return counters.mapValues(\.count)
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
        report("guide pages (3)", await measure(browse) { await browse.loadGuide(); try? await Task.sleep(for: .milliseconds(300)) })
        await browse.loadRecordings(); await browse.loadFavourites()
        report("recordings refresh (unchanged)", await measure(browse) { await browse.loadRecordings() })
        report("recordings refresh (unchanged, quiet)", await measure(browse) { await browse.loadRecordings(quietly: true) })
        recordingsJSON = #"[{"id":1,"title":"News","status":"recording","channel_name":"A"}]"#
        report("recordings refresh (status changed)", await measure(browse) { await browse.loadRecordings() })
        favouritesJSON = #"[{"id":"a","sourceId":1,"name":"A"},{"id":"b","sourceId":1,"name":"B"}]"#
        let channel = Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil)
        report("favourite toggle", await measure(browse) { _ = await browse.setFavourite(channel, true) })
    }

    // MARK: Assertions

    /// Changes to anything `store` holds while `event` runs (what re-rendered a view observing the whole store).
    private func publishes(_ store: AnyObject, _ readEverything: @escaping @MainActor () -> Void,
                           during event: () async -> Void) async -> Int {
        await Invalidations.during(observing: [store], reads: readEverything, event)
    }

    func testAGuidePageDoesNotPublishTheOtherStores() async throws {
        let browse = try makeBrowse()
        let others = Invalidations(observing: [browse.recordingStore, browse.library, browse.marks, browse.actions]) {
            browse.recordingStore.readEverything(); browse.library.readEverything(); browse.marks.readEverything()
            browse.actions.readEverything()
        }
        let guide = await publishes(browse.guideStore, browse.guideStore.readEverything) {
            await browse.loadGuide()
            // Until every page is in (not a fixed wait: a loaded simulator pages slower).
            try? await eventually { browse.guide.count == 6 }
        }
        XCTAssertGreaterThan(guide, 0)
        XCTAssertEqual(browse.guide.count, 6)
        others.stop()
        XCTAssertEqual(others.count, 0, "a guide page re-renders nothing that only draws recordings, favourites or actions")
    }

    func testRecordingsAndFavouritesLoadsDoNotPublishTheGuide() async throws {
        let browse = try makeBrowse()
        await browse.loadGuide()
        try await eventually { browse.guide.count == 6 }
        let guide = await publishes(browse.guideStore, browse.guideStore.readEverything) {
            await browse.loadRecordings()
            await browse.loadFavourites()
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
        let recordings = await publishes(browse.recordingStore, browse.recordingStore.readEverything) {
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
        let recordings = await publishes(browse.recordingStore, browse.recordingStore.readEverything) {
            await browse.loadRecordings(quietly: true)
        }
        let marks = await publishes(browse.marks, browse.marks.readEverything) { await browse.loadRecordings() }
        let library = await publishes(browse.library, browse.library.readEverything) { await browse.loadFavourites() }
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

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 { // up to 10 s: generous for a loaded simulator, instant when it holds
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}
