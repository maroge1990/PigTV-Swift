import XCTest
@testable import PigTV

/// An account's sport follows and the sport pages' view of them, one stored value as on the server (0391 on: both routes
/// read and write the account's `sport_follows` row). Every request is recorded with its body; GETs of the follows, PUTs
/// (either route) and GETs of the preferences can be failed or held until the test releases them.
private final class HideScoresRoutes: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let method: String; let path: String; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) static var spoilerFree = false
    nonisolated(unsafe) static var followsStatus = 200
    nonisolated(unsafe) static var putStatus = 200
    nonisolated(unsafe) static var holdPuts = false
    nonisolated(unsafe) static var holdPreferences = false
    nonisolated(unsafe) static var holdFollowsReads = false
    nonisolated(unsafe) static var rulesStatus = 200
    nonisolated(unsafe) private static var seen: [Seen] = []
    nonisolated(unsafe) private static var held: [HideScoresRoutes] = []
    private var stopped = false
    private var pending: (() -> Void)?

    static let sports = #"[{"sport":"Football","leagues":["Premier League","Champions League"],"teams":["Arsenal","Liverpool"]},{"sport":"Cricket","leagues":["Cricket","BBL"],"teams":["Australia"]}]"#

    static func reset(spoilerFree: Bool) {
        lock.withLock {
            self.spoilerFree = spoilerFree
            followsStatus = 200
            putStatus = 200
            holdPuts = false
            holdPreferences = false
            holdFollowsReads = false
            rulesStatus = 200
            seen = []
            held = []
        }
    }
    static func set(_ change: () -> Void) { lock.withLock(change) }
    static var requests: [Seen] { lock.withLock { seen } }
    static func requests(_ method: String, _ suffix: String) -> [Seen] {
        requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }
    }
    static var heldCount: Int { lock.withLock { held.count } }
    static func heldPaths() -> [String] { lock.withLock { held.map { $0.request.url?.path ?? "" } } }

    /// Answers the oldest held request; false when none is held.
    @discardableResult
    static func releaseOldest() -> Bool {
        let next: HideScoresRoutes? = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        guard let next else { return false }
        let send: (() -> Void)? = lock.withLock { next.stopped ? nil : next.pending }
        send?()
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func follows() -> Data { Data(#"{"spoilerFree":\#(spoilerFree),"sports":\#(sports)}"#.utf8) }
    private static func preferences() -> Data {
        Data(#"{"spoilerFree":\#(spoilerFree),"sports":["Premier League"],"teams":{},"following":{"F1":null,"NFL":null}}"#.utf8)
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 1024); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
        var status = 200
        var hold = false
        // Decided when the answer is sent, so a held PUT changes the stored value only once it is released.
        var answer: () -> Data = { Data(#"{"error":"Not found"}"#.utf8) }
        Self.lock.lock()
        Self.seen.append(Seen(method: method, path: path, body: body))
        switch (method, path) {
        case ("GET", "/api/sports/follows"):
            status = Self.followsStatus
            hold = Self.holdFollowsReads
            answer = { Self.follows() }
        case ("PUT", "/api/sports/follows"):
            status = Self.putStatus
            hold = Self.holdPuts
            answer = {
                Self.lock.withLock {
                    if status == 200, let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let on = sent["spoilerFree"] as? Bool { Self.spoilerFree = on }
                    return Self.follows()
                }
            }
        case ("PUT", "/api/sports/pages/preferences"):
            // The old route, as the server still answers it (the same stored value), so the old writer is seen as it ran.
            status = Self.putStatus
            hold = Self.holdPuts
            answer = {
                Self.lock.withLock {
                    if status == 200, let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let on = sent["spoilerFree"] as? Bool { Self.spoilerFree = on }
                    return Self.preferences()
                }
            }
        case ("GET", "/api/sports/pages/preferences"):
            hold = Self.holdPreferences
            answer = { Self.lock.withLock { Self.preferences() } }
        case ("GET", "/api/sports/catalog"):
            answer = { Data(#"{"sports":[]}"#.utf8) }
        case ("GET", "/api/sports/suggestions"):
            answer = { Data(#"{"suggestions":[]}"#.utf8) }
        case ("GET", "/api/recordings/rules"):
            status = Self.rulesStatus
            answer = { Data("[]".utf8) }
        default:
            status = 404
        }
        Self.lock.unlock()
        let send = { [self] in
            let data = status == 200 ? answer() : Data(#"{"error":"down"}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if hold {
            Self.lock.withLock { pending = send; Self.held.append(self) }
        } else {
            send()
        }
    }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
}

// #278 (audit D5): "Hide scores" had two writers: Settings › Sport (a whole-list `PUT sports/follows`) and the cricket
// page's chip (`PUT sports/pages/preferences`, with its own save queue and a device copy). The chip now saves through
// Settings › Sport's model, the one writer, and fails closed around it: the sport pages hide the scores from the press
// until the server's value has been read again.
@MainActor
final class SportHideScoresWriterTests: XCTestCase {
    private static let oldDeviceCopyKey = "sportPagePreferences.local"

    private func makeBrowse(spoilerFree: Bool) throws -> BrowseModel {
        HideScoresRoutes.reset(spoilerFree: spoilerFree)
        UserDefaults.standard.removeObject(forKey: Self.oldDeviceCopyKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HideScoresRoutes.self]
        // A new account each time: no last copy of the follows from another test.
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration), accountID: Int.random(in: 100_000...999_999_999))
        return BrowseModel(client: client)
    }

    private func waitFor(_ seconds: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func sentFollows(_ seen: HideScoresRoutes.Seen) throws -> SportFollows {
        try JSONDecoder().decode(SportFollows.self, from: seen.body)
    }

    private var loadedFollows: SportFollows {
        get throws { try JSONDecoder().decode(SportFollows.self, from: Data(#"{"spoilerFree":false,"sports":\#(HideScoresRoutes.sports)}"#.utf8)) }
    }

    /// The chip sends one whole-list PUT of the follows, as loaded, with only Hide scores changed; never the old route.
    func testTheChipSavesThroughTheFollowsWithTheWholeListAsLoaded() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        await browse.sportFollows.load()
        await browse.hideScores.set(true)
        let puts = HideScoresRoutes.requests("PUT", "/api/sports/follows")
        XCTAssertEqual(puts.count, 1, "one PUT of the follows")
        var expected = try loadedFollows
        expected.spoilerFree = true
        XCTAssertEqual(try sentFollows(try XCTUnwrap(puts.first)), expected, "every sport, league and team as loaded; only Hide scores changed")
        XCTAssertTrue(HideScoresRoutes.requests("PUT", "/api/sports/pages/preferences").isEmpty, "the sport pages' route is never written")
        XCTAssertTrue(browse.f1Page.preferencesKnown)
        XCTAssertTrue(browse.f1Page.hidesSpoilers)
        XCTAssertFalse(browse.hideScores.notSaved)
        XCTAssertEqual(browse.sportFollows.follows?.spoilerFree, true, "Settings › Sport shows the same choice")
    }

    /// Turning it on hides the scores from the press, before any answer.
    func testTurningItOnHidesTheScoresFromThePress() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        XCTAssertFalse(browse.f1Page.hidesSpoilers, "control: the scores are shown")
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = true }
        let press = Task { @MainActor in await browse.hideScores.set(true) }
        let sent = await waitFor { HideScoresRoutes.heldCount == 1 }
        XCTAssertTrue(sent, "the PUT reached the server")
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "hidden while the PUT is on its way")
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = false }
        HideScoresRoutes.releaseOldest()
        await press.value
        XCTAssertTrue(browse.f1Page.preferencesKnown)
        XCTAssertTrue(browse.f1Page.hidesSpoilers)
    }

    /// Turning it off shows the scores only once the server has saved it and the preferences have been read again.
    func testTurningItOffShowsTheScoresOnlyAfterTheServerHasConfirmed() async throws {
        let browse = try makeBrowse(spoilerFree: true)
        await browse.f1Page.revalidatePreferences()
        XCTAssertTrue(browse.f1Page.preferencesKnown)
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = true; HideScoresRoutes.holdPreferences = true }
        let press = Task { @MainActor in await browse.hideScores.set(false) }
        let sent = await waitFor { HideScoresRoutes.heldPaths().contains("/api/sports/follows") }
        XCTAssertTrue(sent)
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "still hidden while the PUT is on its way")
        HideScoresRoutes.releaseOldest()
        let asked = await waitFor { HideScoresRoutes.heldPaths().contains("/api/sports/pages/preferences") }
        XCTAssertTrue(asked, "the preferences are asked again after the save")
        XCTAssertFalse(HideScoresRoutes.spoilerFree, "the server has it off now")
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "saved, but not read again yet: still hidden")
        let done = await waitFor {
            HideScoresRoutes.releaseOldest()
            return !browse.hideScores.saving
        }
        XCTAssertTrue(done)
        await press.value
        XCTAssertTrue(browse.f1Page.preferencesKnown)
        XCTAssertFalse(browse.f1Page.hidesSpoilers, "shown once the server's value has been read")
        XCTAssertFalse(browse.hideScores.notSaved)
    }

    /// A refused save ends with the server's value, read again; the page says it was not saved; no device copy is kept.
    func testARefusedSaveEndsWithTheServersValue() async throws {
        let browse = try makeBrowse(spoilerFree: true)
        await browse.f1Page.revalidatePreferences()
        HideScoresRoutes.set { HideScoresRoutes.putStatus = 500; HideScoresRoutes.holdPuts = true }
        let press = Task { @MainActor in await browse.hideScores.set(false) }
        let sent = await waitFor { HideScoresRoutes.heldCount == 1 }
        XCTAssertTrue(sent)
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "hidden while it is on its way")
        HideScoresRoutes.releaseOldest()
        await press.value
        XCTAssertTrue(browse.hideScores.notSaved, "the page says the change was not saved")
        XCTAssertTrue(browse.f1Page.preferencesKnown, "read again")
        XCTAssertTrue(browse.f1Page.preferences.spoilerFree, "the server's value, not the one asked for")
        XCTAssertTrue(browse.f1Page.hidesSpoilers)
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.oldDeviceCopyKey), "nothing kept on the device")
        XCTAssertFalse(browse.hideScores.saving, "the chip can be pressed again")
    }

    /// Pressed before Settings › Sport has read the follows: they are read first, and the PUT carries that list.
    func testFollowsNotLoadedAreReadBeforeThePut() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        XCTAssertNil(browse.sportFollows.follows, "control: Settings › Sport has not read them")
        await browse.hideScores.set(true)
        let order = HideScoresRoutes.requests.filter { $0.path == "/api/sports/follows" }.map(\.method)
        XCTAssertEqual(order.first, "GET", "the follows are read before anything is sent")
        let puts = HideScoresRoutes.requests("PUT", "/api/sports/follows")
        XCTAssertEqual(puts.count, 1)
        var expected = try loadedFollows
        expected.spoilerFree = true
        XCTAssertEqual(try sentFollows(try XCTUnwrap(puts.first)), expected, "the list read, not an empty one")
        XCTAssertTrue(HideScoresRoutes.requests("PUT", "/api/sports/pages/preferences").isEmpty)
    }

    /// The follows cannot be read: nothing is sent, the page says so, and the scores end as the server has them.
    func testFollowsThatCannotBeReadSendNothing() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        HideScoresRoutes.set { HideScoresRoutes.followsStatus = 500 }
        await browse.hideScores.set(true)
        XCTAssertTrue(HideScoresRoutes.requests("PUT", "/api/sports/follows").isEmpty, "no whole-list PUT without a list")
        XCTAssertTrue(HideScoresRoutes.requests("PUT", "/api/sports/pages/preferences").isEmpty)
        XCTAssertTrue(browse.hideScores.notSaved)
        XCTAssertTrue(browse.f1Page.preferencesKnown, "read again")
        XCTAssertFalse(browse.f1Page.hidesSpoilers, "the server's value: shown")
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.oldDeviceCopyKey))
    }

    /// Two quick presses send one PUT: the second, made while the first is on its way, does nothing.
    func testTwoQuickPressesSendOnePut() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        await browse.sportFollows.load()
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = true }
        let first = Task { @MainActor in await browse.hideScores.set(true) }
        let second = Task { @MainActor in await browse.hideScores.set(true) }
        let sent = await waitFor { HideScoresRoutes.heldCount == 1 }
        XCTAssertTrue(sent)
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = false }
        let done = await waitFor {
            HideScoresRoutes.releaseOldest()
            return HideScoresRoutes.heldCount == 0 && !browse.hideScores.saving
        }
        XCTAssertTrue(done)
        await first.value
        await second.value
        let puts = HideScoresRoutes.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.count, 1, "one PUT on any route: the second press did nothing (\(puts.map(\.path)))")
        XCTAssertEqual(puts.first?.path, "/api/sports/follows")
        XCTAssertTrue(browse.f1Page.hidesSpoilers)
    }

    /// Review M1: the chip reads only what its save needs before the PUT (the follows, and the catalogue that is kept with
    /// them on this device): not the recording rules, the suggestions or each league's names, all awaited while every
    /// sport screen hid its scores and the chip could not be pressed.
    func testTheChipReadsOnlyTheFollowsBeforeItsPut() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        await browse.hideScores.set(true)
        let seen = HideScoresRoutes.requests
        let put = try XCTUnwrap(seen.firstIndex { $0.method == "PUT" && $0.path == "/api/sports/follows" }, "control: the PUT was sent")
        let before = seen[..<put].map { "\($0.method) \($0.path)" }
        XCTAssertEqual(before.filter { $0 == "GET /api/sports/follows" }.count, 1, "one read of the follows: \(before)")
        for path in ["/api/recordings/rules", "/api/sports/suggestions", "/api/sports/names"] {
            XCTAssertFalse(before.contains { $0.hasSuffix(path) }, "\(path) is not read before the PUT: \(before)")
        }
        XCTAssertEqual(HideScoresRoutes.requests("PUT", "/api/sports/follows").count, 1)
    }

    /// Review L1: a chip press whose read of the follows a later load overtook builds no whole-list PUT from the list
    /// held before (it could be hours old): nothing is sent.
    func testAChipPressWhoseFollowsReadIsSupersededSendsNoPut() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        await browse.sportFollows.load()
        XCTAssertNotNil(browse.sportFollows.follows, "control: an older list is held")
        HideScoresRoutes.set { HideScoresRoutes.holdFollowsReads = true }
        let press = Task { @MainActor in await browse.hideScores.set(true) }
        let chipRead = await waitFor { HideScoresRoutes.heldCount == 1 }
        XCTAssertTrue(chipRead, "control: the chip's read of the follows is held")
        let later = Task { @MainActor in await browse.sportFollows.load() }
        let laterRead = await waitFor { HideScoresRoutes.heldCount == 2 }
        XCTAssertTrue(laterRead, "control: a later load's read is held too")
        HideScoresRoutes.set { HideScoresRoutes.holdFollowsReads = false }
        HideScoresRoutes.releaseOldest() // the chip's read answers first, overtaken
        let pressDone = await waitFor { !browse.hideScores.saving }
        HideScoresRoutes.releaseOldest()
        await press.value
        await later.value
        XCTAssertTrue(pressDone)
        XCTAssertTrue(HideScoresRoutes.requests("PUT", "/api/sports/follows").isEmpty, "no PUT from a superseded read")
        XCTAssertTrue(browse.hideScores.notSaved, "the page says it was not saved")
    }

    /// Review M1: a chip press whose rules read would fail leaves Scheduled's rules state alone (it reads no rules).
    func testAChipPressLeavesTheRecordingRulesAlone() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        await browse.f1Page.revalidatePreferences()
        HideScoresRoutes.set { HideScoresRoutes.rulesStatus = 500 }
        XCTAssertNil(browse.recordingStore.rulesError, "control")
        await browse.hideScores.set(true)
        XCTAssertEqual(HideScoresRoutes.requests("PUT", "/api/sports/follows").count, 1, "control: it saved")
        XCTAssertNil(browse.recordingStore.rulesError, "Scheduled shows no rules error because a chip was pressed")
        XCTAssertTrue(HideScoresRoutes.requests("GET", "/api/recordings/rules").isEmpty)
    }

    /// Review L7: the cricket chip says what the screens do: hidden while the choice is unknown or being saved, never
    /// the last known value.
    func testTheChipSaysHiddenWhileTheChoiceIsUnknown() async throws {
        let browse = try makeBrowse(spoilerFree: false)
        XCTAssertFalse(browse.f1Page.preferencesKnown, "control: not read yet")
        XCTAssertFalse(browse.f1Page.preferences.spoilerFree, "control: the last known value is off")
        XCTAssertTrue(CricketPageView.scoresChipHidden(browse.f1Page), "unknown: the chip says hidden")
        await browse.f1Page.revalidatePreferences()
        XCTAssertFalse(CricketPageView.scoresChipHidden(browse.f1Page), "control: known off, shown")
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = true }
        let press = Task { @MainActor in await browse.hideScores.set(true) }
        let sent = await waitFor { HideScoresRoutes.heldCount == 1 }
        XCTAssertTrue(sent)
        XCTAssertFalse(browse.f1Page.preferences.spoilerFree, "control: the last known value is still off")
        XCTAssertTrue(CricketPageView.scoresChipHidden(browse.f1Page), "while it saves: hidden, as the screens are")
        HideScoresRoutes.set { HideScoresRoutes.holdPuts = false }
        HideScoresRoutes.releaseOldest()
        await press.value
    }

    /// The sport pages' model only reads: no write path is left in it.
    func testTheSportPagesModelHasNoWritePath() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTV/F1PageModel.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(#"method: "PUT""#), "F1PageModel sends no PUT")
        XCTAssertFalse(text.contains("UserDefaults"), "and keeps no device copy")
    }
}
