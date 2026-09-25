import XCTest
@testable import PigTV

// A4.1: the Top Shelf snapshot (built by the app, read by the extension)
// and the pigtv://play deep link.
@MainActor
final class TopShelfTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func browse() throws -> BrowseModel {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"channelNumbers":true}}"#.utf8))
        return BrowseModel(client: APIClient(address: try ServerAddress("http://tv.local:3000"), token: "secret-token", info: info))
    }

    private func programme(_ title: String, from start: TimeInterval, to end: TimeInterval) -> GuideProgramme {
        GuideProgramme(title: title, description: nil, startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000)
    }

    func testLineupSnapshotWithNowNextAndAbsoluteLogos() throws {
        let model = try browse()
        model.guide = (0..<20).map { index in
            GuideChannel(rawID: "c\(index)", sourceId: 1, name: "Channel \(index)", logo: "/api/logo/\(index)", category: nil,
                         programmes: [programme("Earlier", from: -7200, to: -1800), programme("Now \(index)", from: -1800, to: 1800),
                                      programme("Next \(index)", from: 1800, to: 3600), programme("Later", from: 3600, to: 7200)],
                         number: 500 + index)
        }
        let snapshot = try XCTUnwrap(model.topShelfSnapshot(now: now))
        XCTAssertEqual(snapshot.kind, "channels")
        XCTAssertEqual(snapshot.sectionTitle, "Channels")
        XCTAssertEqual(snapshot.channels.count, TopShelfSnapshot.limit)
        let first = snapshot.channels[0]
        XCTAssertEqual(first.title, "Channel 0", "build 29: no channel number in the title")
        XCTAssertEqual(first.logo?.absoluteString, "http://tv.local:3000/api/logo/0")
        XCTAssertEqual(first.programmes.map(\.title), ["Now 0", "Next 0"])
        XCTAssertEqual(first.programme(at: now)?.title, "Now 0")
        XCTAssertEqual(first.programme(at: now.addingTimeInterval(2000))?.title, "Next 0")
        XCTAssertNil(first.programme(at: now.addingTimeInterval(4000)))
        XCTAssertEqual(PigTVLink.parse(first.playURL), PigTVLink.Play(sourceId: 1, id: "c0", name: "Channel 0", number: 500))
        // Nothing secret is written.
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"))
    }

    func testFavouritesComeFirstAndFallBackToTheirOwnNowNext() throws {
        let model = try browse()
        model.guide = [GuideChannel(rawID: "g", sourceId: 1, name: "Guide row", logo: nil, category: nil,
                                    programmes: [programme("On now", from: -60, to: 60)], number: 7)]
        let outside = Channel(rawID: "x", sourceId: 2, name: "Fox Footy", logo: "https://cdn.example/fox.png", category: nil,
                              now: Programme(title: "AFL Live", startTime: (now.timeIntervalSince1970 - 60) * 1000,
                                             endTime: (now.timeIntervalSince1970 + 60) * 1000),
                              next: nil, number: 503)
        let inGuide = Channel(rawID: "g", sourceId: 1, name: "Guide row", logo: nil, category: nil, now: nil, next: nil)
        model.favourites = [outside, inGuide]
        let snapshot = try XCTUnwrap(model.topShelfSnapshot(now: now))
        XCTAssertEqual(snapshot.kind, "favourites")
        XCTAssertEqual(snapshot.sectionTitle, "Favourites")
        XCTAssertEqual(snapshot.channels.map(\.title), ["Fox Footy", "Guide row"])
        XCTAssertEqual(snapshot.channels.map(\.number), [503, 7], "the number is kept for the play link")
        XCTAssertEqual(snapshot.channels[0].logo?.absoluteString, "https://cdn.example/fox.png")
        XCTAssertEqual(snapshot.channels[0].programme(at: now)?.title, "AFL Live")
        XCTAssertEqual(snapshot.channels[1].programme(at: now)?.title, "On now")
        XCTAssertNil(try browse().topShelfSnapshot(now: now), "nothing loaded: no snapshot")
    }

    func testSnapshotRoundTripsAndComparesWithoutSavedAt() throws {
        let entry = TopShelfSnapshot.Entry(id: "a b", sourceId: 3, name: "Name", number: nil, logo: URL(string: "http://h/l.png"),
                                           programmes: [.init(title: "T", start: now, end: now.addingTimeInterval(60))])
        let snapshot = TopShelfSnapshot(kind: "channels", channels: [entry], savedAt: now)
        let decoded = try XCTUnwrap(TopShelfSnapshot.decode(try snapshot.encoded()))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.channels[0].title, "Name")
        var later = snapshot
        later.savedAt = now.addingTimeInterval(600)
        XCTAssertTrue(later.sameContent(as: snapshot))
        later.channels[0].name = "Other"
        XCTAssertFalse(later.sameContent(as: snapshot))
        XCTAssertFalse(snapshot.sameContent(as: nil))
        XCTAssertNil(TopShelfSnapshot.decode(Data("{}".utf8)))
    }

    // Build 27: the write/read path the app and the extension share, through
    // the container path helper (a temporary directory stands in for the
    // App Group).
    func testSnapshotFileRoundTripThroughTheSharedPath() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        // Build 29: under Library/Caches, not the container's root (tvOS
        // refuses writes there with Cocoa 513 / POSIX 1).
        let file = try XCTUnwrap(TopShelfSnapshot.fileURL(in: container))
        XCTAssertEqual(file.lastPathComponent, "topshelf-snapshot.json")
        XCTAssertEqual(file.deletingLastPathComponent().path, container.appendingPathComponent("Library/Caches").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Library").path),
                       "the writer creates Library/Caches itself")
        XCTAssertNil(TopShelfSnapshot.read(container: container), "nothing written yet")
        let entry = TopShelfSnapshot.Entry(id: "c1", sourceId: 1, name: "Fox Footy", number: 503,
                                           logo: URL(string: "http://192.168.1.20:3000/api/logo/abc"),
                                           programmes: [.init(title: "AFL Live", start: now, end: now.addingTimeInterval(3600))])
        let snapshot = TopShelfSnapshot(kind: "favourites", channels: [entry], savedAt: now)
        XCTAssertTrue(snapshot.write(container: container))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("topshelf-snapshot.json").path))
        XCTAssertEqual(TopShelfSnapshot.read(container: container), snapshot)
        // No container (an unentitled process): nothing written, nothing read.
        XCTAssertFalse(snapshot.write(container: nil))
        XCTAssertNil(TopShelfSnapshot.read(container: nil))
        // A corrupt file reads as no snapshot rather than crashing.
        try Data("not json".utf8).write(to: XCTUnwrap(TopShelfSnapshot.fileURL(in: container)))
        XCTAssertNil(TopShelfSnapshot.read(container: container))
    }

    // Build 29: the shared path helper and the Siri channel directory use
    // the same writable place.
    func testAppGroupPathsEndInLibraryCaches() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        XCTAssertNil(AppGroupStorage.directory(in: nil))
        XCTAssertEqual(Array(try XCTUnwrap(AppGroupStorage.directory(in: container)).pathComponents.suffix(2)), ["Library", "Caches"])
        let directoryFile = try XCTUnwrap(ChannelDirectory.fileURL(in: container))
        XCTAssertEqual(Array(directoryFile.pathComponents.suffix(3)), ["Library", "Caches", "channel-directory.json"])
        XCTAssertNil(ChannelDirectory.read(container: container))
        let directory = ChannelDirectory(channels: [.init(id: "c1", sourceId: 1, name: "Fox Footy", number: 503)])
        XCTAssertTrue(directory.write(container: container))
        XCTAssertEqual(ChannelDirectory.read(container: container), directory)
        XCTAssertFalse(directory.write(container: nil))
        #if os(tvOS)
        // The real App Group: its Library/Caches accepts a write (the root
        // is what a device refuses).
        let real = try XCTUnwrap(AppGroupStorage.containerURL)
        let probe = try XCTUnwrap(AppGroupStorage.fileURL("write-probe-\(UUID().uuidString)", in: real))
        try AppGroupStorage.createDirectory(for: probe)
        try Data("ok".utf8).write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        #endif
    }

    #if os(tvOS)
    // The app is entitled to the App Group (the extension uses the same file),
    // and the embedded extension may load plain-http logos from the LAN
    // server: its own ATS exception, the app's does not apply to it.
    func testAppGroupAndExtensionConfiguration() throws {
        XCTAssertNotNil(TopShelfSnapshot.containerURL, "App Group container unavailable to the app")
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("PigTVTopShelf.appex"))
        let info = try XCTUnwrap(Bundle(url: appex)?.infoDictionary)
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any], "the Top Shelf extension has no ATS exception")
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.tv-top-shelf")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "PigTVTopShelf.ContentProvider")
    }

    // Build 31: the tv-app-extension product type links `_TVExtensionMain`,
    // which the current tvOS runtime implements as an empty function, so the
    // extension exited at launch and the Top Shelf only ever showed the
    // static image. The extension must enter through `_NSExtensionMain`.
    func testTopShelfExtensionEntryPoint() throws {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("PigTVTopShelf.appex"))
        let executable = try XCTUnwrap(Bundle(url: appex)?.executableURL)
        let binary = try Data(contentsOf: executable)
        XCTAssertNotNil(binary.range(of: Data("_NSExtensionMain".utf8)), "the extension does not enter through NSExtensionMain")
        XCTAssertNil(binary.range(of: Data("_TVExtensionMain".utf8)), "the extension still links the empty TVExtensionMain")
    }
    #endif

    func testDiagnosticsLines() throws {
        let noGroup = TopShelfDiagnostics.lines(container: nil)
        XCTAssertTrue(noGroup.snapshot.contains("no App Group"), noGroup.snapshot)
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let format: (Date) -> String = { "T\(Int($0.timeIntervalSince1970))" }
        let empty = TopShelfDiagnostics.lines(container: container, format: format)
        XCTAssertEqual(empty.snapshot, "Not written yet · App Group OK")
        XCTAssertTrue(empty.extensionStatus.hasPrefix("Not asked yet"), empty.extensionStatus)
        let entry = TopShelfSnapshot.Entry(id: "a", sourceId: 1, name: "A", number: nil, logo: nil, programmes: [])
        XCTAssertTrue(TopShelfSnapshot(kind: "channels", channels: [entry, entry], savedAt: now).write(container: container))
        XCTAssertTrue(TopShelfExtensionStatus(askedAt: now.addingTimeInterval(60), items: 2, note: "returned 2 items").write(container: container))
        let written = TopShelfDiagnostics.lines(container: container, format: format)
        XCTAssertEqual(written.snapshot, "Written T1800000000, 2 items · App Group OK")
        XCTAssertEqual(written.extensionStatus, "Last asked T1800000060: returned 2 items")
        XCTAssertEqual(TopShelfExtensionStatus.read(container: container)?.items, 2)
    }

    func testPlayLinks() throws {
        let url = PigTVLink.playURL(sourceId: 4, id: "12&3+4 5", name: "Sky Sports+ & More", number: 503)
        XCTAssertEqual(url.scheme, "pigtv")
        XCTAssertEqual(PigTVLink.parse(url), PigTVLink.Play(sourceId: 4, id: "12&3+4 5", name: "Sky Sports+ & More", number: 503))
        XCTAssertEqual(PigTVLink.parse(try XCTUnwrap(URL(string: "pigtv://play?sourceId=2&id=77"))),
                       PigTVLink.Play(sourceId: 2, id: "77", name: nil, number: nil))
        XCTAssertEqual(PigTVLink.parse(try XCTUnwrap(URL(string: "pigtv://play?sourceId=2&id=77")))?.channelKey, "2:77")
        for bad in ["pigtv://play?id=77", "pigtv://play?sourceId=x&id=77", "pigtv://play?sourceId=2&id=",
                    "pigtv://guide?sourceId=2&id=77", "https://play?sourceId=2&id=77"] {
            XCTAssertNil(PigTVLink.parse(try XCTUnwrap(URL(string: bad))), bad)
        }
        XCTAssertNil(PigTVLink.parse(try XCTUnwrap(URL(string: "pigtv://play?sourceId=2&id=7&number=-4")))?.number)
    }

    func testLinkChannelPrefersTheGuide() throws {
        let model = try browse()
        model.guide = [GuideChannel(rawID: "g", sourceId: 1, name: "Guide name", logo: "/api/logo/g", category: nil,
                                    programmes: [], number: 9)]
        let app = AppModel()
        app.configureClientForTesting(model.client, browse: model)
        let known = app.channel(for: PigTVLink.Play(sourceId: 1, id: "g", name: "Stale", number: 1))
        XCTAssertEqual(known.name, "Guide name")
        XCTAssertEqual(known.number, 9)
        XCTAssertEqual(known.logo, "/api/logo/g")
        let built = app.channel(for: PigTVLink.Play(sourceId: 2, id: "z", name: "Fox Footy", number: 503))
        XCTAssertEqual(built.id, "2:z")
        XCTAssertEqual(built.name, "Fox Footy")
        XCTAssertEqual(built.number, 503)
    }
}

// A4.5: the intent's entity turns into the same deep link as the Top Shelf.
@MainActor
final class PlayChannelIntentTests: XCTestCase {
    func testEntityPlayURLAndInbox() {
        let entity = ChannelEntity(ChannelDirectory.Entry(id: "x y", sourceId: 3, name: "Fox Footy", number: 503))
        XCTAssertEqual(entity.id, "3:x y")
        XCTAssertEqual(PigTVLink.parse(entity.playURL), PigTVLink.Play(sourceId: 3, id: "x y", name: "Fox Footy", number: 503))
        let inbox = PlayLinkInbox()
        XCTAssertNil(inbox.take())
        inbox.submit(entity.playURL)
        XCTAssertEqual(inbox.take(), entity.playURL)
        XCTAssertNil(inbox.pending, "a request is consumed once")
    }
}
