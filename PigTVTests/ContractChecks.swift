import Foundation
#if canImport(PigTV)
@testable import PigTV
#endif

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseStatus = 200
    nonisolated(unsafe) static var responseHeaders = [String: String]()
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        Self.capturedRequest = request
        Self.capturedBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let length = stream.read(&buffer, maxLength: buffer.count)
                if length <= 0 { break }
                Self.capturedBody.append(contentsOf: buffer.prefix(length))
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1", headerFields: Self.responseHeaders.merging(["Content-Type": "application/json"]) { current, _ in current })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
enum ContractChecks {
    static func run() async throws -> Int {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw CheckFailure(description: message) }
            count += 1
        }
        func rejects(_ text: String) throws {
            do {
                _ = try ServerAddress(text)
                throw CheckFailure(description: "Accepted invalid server: \(text)")
            } catch PigTVError.invalidServerURL { count += 1 }
        }

        let address = try ServerAddress(" HTTPS://EXAMPLE.invalid:443/ ")
        try expect(address.url.absoluteString == "https://example.invalid/", "Origin must canonicalize default port and case")
        for invalid in ["file:///etc/passwd", "https://user:pass@example.invalid", "https://example.invalid/pigtv",
                        "https://example.invalid?token=x", "https://example.invalid/#fragment", "http://example.invalid:0"] {
            try rejects(invalid)
        }
        let api = APIClient(address: address, token: "secret & value")
        let query = try api.requestURL("library/channels", query: [URLQueryItem(name: "search", value: "News & Sport + 100%")])
        try expect(query.path == "/api/library/channels", "Query must not become part of path")
        try expect(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "News & Sport + 100%", "Search must preserve reserved characters")
        try expect(query.absoluteString.contains("%2B"), "Express must receive a literal plus rather than a space")
        let playback = try api.playbackURL("/api/transcode/session/stream.m3u8?token=old&part=1")
        let items = URLComponents(url: playback, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(items.filter { $0.name == "token" }.map(\.value) == ["secret & value"], "Only one correct token should be sent")
        try expect(items.contains(URLQueryItem(name: "part", value: "1")), "Existing query should survive")
        for bad in ["https://other.invalid/api/remux", "https://example.invalid:8443/api/remux",
                    "http://example.invalid/api/remux", "https://user@example.invalid/api/remux", "/api/auth/me",
                    "https://example.invalid:443/api/remux", "/api/remux?token=x"] {
            do { _ = try api.playbackURL(bad); throw CheckFailure(description: "Unsafe playback URL accepted") }
            catch PigTVError.message { count += 1 }
        }

        let pageData = Data(#"{"total":2,"limit":50,"offset":0,"channels":[{"id":"42","sourceId":3,"name":"News","logo":null,"category":"general","now":null,"next":null},{"id":"42","sourceId":4,"name":"Other News","logo":null,"category":"general","now":{"title":"Bulletin","startTime":1000,"endTime":5000},"next":null}]}"#.utf8)
        let page = try JSONDecoder().decode(ChannelPage.self, from: pageData)
        try expect(page.channels.map(\.id) == ["3:42", "4:42"], "Channel identity must include source")
        try expect(page.channels[0].rawID == "42" && page.channels[0].now == nil, "Resolve needs raw ID; missing EPG is allowed")
        try expect(page.channels[1].now?.progress(at: Date(timeIntervalSince1970: 3)) == 0.5, "EPG uses milliseconds")
        let pair = try JSONDecoder().decode(PairPoll.self, from: Data(#"{"status":"approved","token":"fixture","deviceId":"test"}"#.utf8))
        try expect(pair.token == "fixture", "Pairing does not return a user object")
        let start = try JSONDecoder().decode(PairStart.self, from: Data(#"{"code":"BCDF23","expiresAt":600000,"expiresInSec":600}"#.utf8))
        try expect(start.expiry.timeIntervalSince1970 == 600, "Pair expiry uses milliseconds")
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.4.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"devicePairing":true}}"#.utf8))
        try info.validate()
        count += 1
        let old = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"old","apiVersion":1,"features":{"library":true}}"#.utf8))
        do { try old.validate(); throw CheckFailure(description: "Missing resolver must fail") }
        catch PigTVError.message { count += 1 }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let fixtureAPI = APIClient(address: address, token: "fixture-token", session: URLSession(configuration: configuration))
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseData = pageData
        let result: ChannelPage = try await fixtureAPI.request("library/channels", query: [URLQueryItem(name: "search", value: "A&B")])
        try expect(result.total == 2, "Real request must decode fixture")
        try expect(FixtureProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "API must send bearer header")
        try expect(FixtureProtocol.capturedRequest?.url?.path == "/api/library/channels", "Request must target correct endpoint")
        FixtureProtocol.responseStatus = 401
        do { let _: User = try await fixtureAPI.request("auth/me"); throw CheckFailure(description: "401 must fail") }
        catch PigTVError.unauthorised { count += 1 }
        FixtureProtocol.responseStatus = 403
        do { let _: User = try await fixtureAPI.request("auth/me"); throw CheckFailure(description: "403 must fail") }
        catch PigTVError.forbidden { count += 1 }
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseData = Data("not-json".utf8)
        do { let _: User = try await fixtureAPI.request("auth/me"); throw CheckFailure(description: "Bad JSON must fail") }
        catch PigTVError.decoding { count += 1 }
        let capable = PlaybackCapabilities.current(supports: { _ in true })
        try expect(capable["hevc"] == true && capable["ac3"] == true, "Supported native codecs must not be forced off")
        let baseline = PlaybackCapabilities.current(supports: { _ in false })
        try expect(baseline["hevc"] == false && baseline["hls"] == true, "Unsupported codecs remain conservative")
        let main8Only = PlaybackCapabilities.current(supports: { !$0.contains("hvc1.2") })
        try expect(main8Only["hevc"] == false, "HEVC flag requires both common profiles")
        // C-C: HE-AAC passthrough is always advertised since build 27 (no Labs switch).
        try expect(capable["heaac"] == true && baseline["heaac"] == true, "HE-AAC passthrough must always be advertised")
        let labsDefaults = UserDefaults(suiteName: "pigtv.contract.labs")!
        labsDefaults.removePersistentDomain(forName: "pigtv.contract.labs")
        try expect(Labs.toggles.allSatisfy { !Labs.isOn($0.key, in: labsDefaults) }, "Every Labs switch defaults to off")
        labsDefaults.set(true, forKey: Labs.streamInfo)
        try expect(Labs.isOn(Labs.streamInfo, in: labsDefaults), "Labs switches persist")
        labsDefaults.removePersistentDomain(forName: "pigtv.contract.labs")
        try expect(Labs.toggles.map(\.key) == ["pigtv.labs.streamInfo"], "Labs keys match contract C-F")
        let request = ResolveBody(sourceId: 3, channelId: "42", capabilities: capable)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        try expect(json["force"] as? Bool == false, "Normal playback must never stop a recording implicitly")
        FixtureProtocol.responseStatus = 409
        FixtureProtocol.responseData = Data(#"{"error":"Provider stream is in use","conflict":{"type":"recording-in-progress","scheduleId":7,"title":"News","channelName":"Channel","endsAt":600000}}"#.utf8)
        do {
            let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
            throw CheckFailure(description: "A recording conflict must not be treated as playable")
        } catch PigTVError.recordingConflict(let conflict) {
            try expect(conflict.scheduleId == 7 && conflict.title == "News", "Conflict details must reach confirmation UI")
        }
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseData = Data("null".utf8)
        let noPrompt: RecordingPrompt? = try await fixtureAPI.request("playback/conflict")
        try expect(noPrompt == nil, "No pending prompt is JSON null")
        FixtureProtocol.responseData = Data(#"{"scheduleId":7,"title":"News","channelName":"Channel","startsAt":1000,"programEnd":600000,"startsInSec":0}"#.utf8)
        let prompt: RecordingPrompt? = try await fixtureAPI.request("playback/conflict")
        try expect(prompt?.id == 7, "Polling prompt must decode without relying on server message text")
        FixtureProtocol.responseStatus = 500
        FixtureProtocol.responseData = Data(#"{"error":"Transcode failed to produce a playlist in time","info":{"video":"hevc"}}"#.utf8)
        do {
            let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
            throw CheckFailure(description: "Startup timeout must fail")
        } catch PigTVError.message(let message) {
            try expect(message.contains("startup deadline"), "Known startup timeout needs an actionable message")
        }
        FixtureProtocol.responseData = Data(#"{"error":"Failed https://provider.invalid/private/password/stream"}"#.utf8)
        do {
            let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
            throw CheckFailure(description: "Unknown server failure must fail")
        } catch PigTVError.http(let status) {
            try expect(status == 500, "Unknown server error must not expose upstream credentials")
        }
        // C-B: allow-listed resolve failures are shown verbatim (trimmed to 300 characters).
        let refused = "The provider refused this channel (HTTP 403). It may be offline, or still releasing the previous stream; try again in a few seconds."
        FixtureProtocol.responseData = try JSONSerialization.data(withJSONObject: ["error": refused, "info": [String: String]()])
        do {
            let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
            throw CheckFailure(description: "An allow-listed resolve failure must fail")
        } catch PigTVError.message(let message) {
            try expect(message == refused, "An allow-listed resolve error (including its HTTP status text) must be shown as sent")
        }
        let long = "This channel is not available " + String(repeating: "x", count: 400)
        FixtureProtocol.responseData = try JSONSerialization.data(withJSONObject: ["error": long])
        do {
            let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
            throw CheckFailure(description: "A long allow-listed resolve failure must fail")
        } catch PigTVError.message(let message) {
            try expect(message.count == 300 && long.hasPrefix(message), "An allow-listed resolve error is trimmed to 300 characters")
        }
        for disallowed in ["The provider could not find this channel (HTTP 404). A playlist sync may help.",
                           "The provider did not respond at https://provider.invalid/user/password/1.ts",
                           "Failed: The provider refused this channel"] {
            FixtureProtocol.responseData = try JSONSerialization.data(withJSONObject: ["error": disallowed])
            do {
                let _: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
                throw CheckFailure(description: "A disallowed resolve failure must fail")
            } catch PigTVError.http(let status) {
                try expect(status == 500, "A resolve error outside the allow-list (or carrying a URL) keeps the generic mapping")
            }
        }
        try expect(APIClient.displayableResolveError("The provider did not respond in time.") == "The provider did not respond in time.", "Every allow-listed prefix is shown")
        try expect(APIClient.displayableResolveError(nil) == nil, "A missing error keeps the generic mapping")
        FixtureProtocol.responseData = try JSONSerialization.data(withJSONObject: ["error": refused])
        do {
            let _: ActionResult = try await fixtureAPI.request("favorites", method: "POST", body: FavouriteBody(sourceId: 2, itemId: "x"))
            throw CheckFailure(description: "A non-resolve failure must fail")
        } catch PigTVError.http(let status) {
            try expect(status == 500, "Only resolve responses may surface server error text")
        }

        let guideFixture = Data(#"""
        {"total":2,"channels":[{"id":"same","sourceId":1,"name":"One","programmes":[{"title":"Show","description":null,"startTime":1000,"endTime":3000}]},{"id":"same","sourceId":2,"name":"Two","programmes":[]}]}
        """#.utf8)
        let guide = try JSONDecoder().decode(GuidePage.self, from: guideFixture)
        try expect(guide.channels[0].id != guide.channels[1].id, "Guide channels need source-qualified identity")
        try expect(guide.channels[1].programmes.isEmpty, "An empty EPG must remain empty")
        let show = guide.channels[0].programmes[0]
        try expect(show.isLive(at: Date(timeIntervalSince1970: 1)), "Programme starts inclusively")
        try expect(!show.isLive(at: Date(timeIntervalSince1970: 3)), "Programme ends exclusively")
        let clipped = GuideGeometry.interval(start: 0, end: 2000, window: 1000, duration: 2000)
        try expect(clipped?.offset == 0 && clipped?.width == 0.5, "Guide must clip programmes at the window edge")
        try expect(GuideGeometry.interval(start: 3000, end: 4000, window: 1000, duration: 2000) == nil, "Outside programmes must not occupy the timeline")
        try expect(GuideGeometry.interval(start: 2000, end: 1000, window: 0, duration: 3000) == nil, "Invalid EPG intervals must be omitted")
        try expect(GuideGeometry.interval(start: .nan, end: 1000, window: 0, duration: 3000) == nil, "Invalid EPG numbers must not reach layout")
        let placed = GuideGeometry.placement(start: 0, end: 2000, window: 1000, duration: 2000)
        try expect(placed?.offset == -0.5 && placed?.width == 1, "Sliding guide cells keep their full width and true position")
        try expect(GuideGeometry.placement(start: 2000, end: 1000, window: 0, duration: 3000) == nil, "Invalid EPG intervals must not be placed")
        let scheduled = try JSONDecoder().decode(ScheduledRecording.self, from: Data(#"{"id":1,"title":"Show","program_start":1000,"program_end":3000,"status":"waiting"}"#.utf8))
        try expect(scheduled.canCancel, "Waiting schedules must be cancellable")
        try expect(scheduled.start == Date(timeIntervalSince1970: 1), "Recording dates use milliseconds")
        let rec = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":1,"title":"Show","status":"completed","is_partial":1}"#.utf8))
        try expect(rec.is_partial == 1 && rec.ad_detect_status == nil, "Older recording responses must decode without analysis fields")
        let markers = try JSONDecoder().decode(RecordingMarkers.self, from: Data(#"{"status":"done","markers":[{"id":1,"startMs":0,"endMs":1000,"type":"ad"},{"id":2,"startMs":2000,"endMs":1000,"type":"ad"}]}"#.utf8))
        try expect(markers.markers.filter(\.valid).count == 1, "Malformed ad intervals must not be offered")
        FixtureProtocol.responseStatus = 201
        FixtureProtocol.responseData = Data(#"{"id":1,"title":"Show","program_start":1000,"program_end":3000,"status":"scheduled"}"#.utf8)
        let scheduleBody = ScheduleBody(sourceId: 2, channelItemId: "a+b&c", channelName: "Channel",
            channelLogo: nil, title: "Show", description: nil, programStart: 1000,
            programEnd: 3000, preBufferMin: 2, postBufferMin: 5)
        let _: ScheduledRecording = try await fixtureAPI.request("recordings/schedule", method: "POST", body: scheduleBody)
        let scheduleJSON = try JSONSerialization.jsonObject(with: FixtureProtocol.capturedBody) as! [String: Any]
        try expect(scheduleJSON["channelItemId"] as? String == "a+b&c", "Scheduling must preserve raw channel identity")
        try expect(scheduleJSON["programStart"] as? Int == 1000 && scheduleJSON["postBufferMin"] as? Int == 5, "Schedule timestamps and padding must use server units")
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseData = Data(#"{"success":true}"#.utf8)
        let _: ActionResult = try await fixtureAPI.request("favorites", method: "DELETE", body: FavouriteBody(sourceId: 2, itemId: "a+b&c"))
        let favouriteJSON = try JSONSerialization.jsonObject(with: FixtureProtocol.capturedBody) as! [String: Any]
        try expect(FixtureProtocol.capturedRequest?.httpMethod == "DELETE" && favouriteJSON["itemType"] as? String == "channel", "Favourite removal must use the verified DELETE body contract")
        try expect(capable["segmentedDelivery"] == true, "Native playback must request segmented delivery")
        try expect(PlaybackCapabilities.current(supports: { _ in false })["segmentedDelivery"] == true, "Segmented delivery must not depend on codec support")
        FixtureProtocol.responseData = Data(#"{"strategy":"transcode","container":"hls","url":"/api/transcode/session123/stream.m3u8","sessionId":"session123","videoMode":"copy","audioMode":"copy"}"#.utf8)
        let hls: PlaybackDecision = try await fixtureAPI.request("playback/resolve", method: "POST", body: request)
        let resolveJSON = try JSONSerialization.jsonObject(with: FixtureProtocol.capturedBody) as! [String: Any]
        try expect((resolveJSON["capabilities"] as? [String: Bool])?["segmentedDelivery"] == true, "Resolve request must carry segmentedDelivery inside capabilities")
        try expect(hls.sessionId == "session123" && hls.container == "hls", "Stream-copy HLS must use the existing session response")
        let media = try fixtureAPI.playbackURL(hls.url)
        try expect(URLComponents(url: media, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value == "fixture-token", "HLS playlist must receive the device token")
        FixtureProtocol.responseData = Data(#"{"success":true}"#.utf8)
        try await fixtureAPI.release("session123")
        try expect(FixtureProtocol.capturedRequest?.httpMethod == "DELETE" &&
            FixtureProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
            "HLS cleanup must retain bearer authentication")
        FixtureProtocol.responseData = Data(#"{"id":7,"title":"Show","program_start":1000,"program_end":3000,"status":"cancelled"}"#.utf8)
        let cancelled: ScheduledRecording = try await fixtureAPI.request("recordings/scheduled/7", method: "DELETE")
        try expect(!cancelled.canCancel && cancelled.status == "cancelled", "Cancellation returns a schedule, not a success wrapper")
        try expect(FixtureProtocol.capturedRequest?.url?.path == "/api/recordings/scheduled/7", "Cancel only the selected schedule")
        try expect(fixtureAPI.artworkRequest("/logos/channel.png")?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Relative artwork uses server authentication")
        try expect(fixtureAPI.artworkRequest("https://images.example.org/logo.png")?.value(forHTTPHeaderField: "Authorization") == nil, "External artwork must never receive bearer credentials")
        try expect(fixtureAPI.artworkRequest("//images.example.org/logo.png")?.value(forHTTPHeaderField: "Authorization") == nil, "Protocol-relative external artwork must not receive credentials")
        try expect(fixtureAPI.artworkRequest("file:///tmp/logo.png") == nil, "Artwork must use HTTP or HTTPS")
        try expect(fixtureAPI.artworkRequest("https://user:password@example.org/logo.png") == nil, "Reject embedded artwork credentials")
        let guideStart = Date(timeIntervalSince1970: 0)
        let shortShow = GuideProgramme(title: "Short", description: nil, startTime: 0, endTime: 1_800_000)
        let longShow = GuideProgramme(title: "Long", description: nil, startTime: 1_800_000, endTime: 7_200_000)
        try expect(GuideNavigation.programme(in: [shortShow, longShow], at: Date(timeIntervalSince1970: 1800)) == longShow, "Vertical navigation must select the programme covering the time anchor at an exact boundary")
        try expect(GuideNavigation.programme(in: [shortShow], at: Date(timeIntervalSince1970: 1900)) == nil, "Guide gaps must not select expired programmes")
        try expect(GuideNavigation.visibleDuration == 7200 && GuideNavigation.step == 1800, "The guide shows two hours in four half-hour columns")
        let twoHours = guideStart.addingTimeInterval(7200)
        let later = GuideProgramme(title: "Later", description: nil, startTime: 9_000_000, endTime: 10_800_000)
        let overlap = GuideProgramme(title: "Overlap", description: nil, startTime: 5_400_000, endTime: 9_000_000)
        let duplicate = GuideProgramme(title: "Duplicate", description: nil, startTime: 1_800_000, endTime: 3_600_000)
        let visible = GuideNavigation.visible([later, overlap, longShow, duplicate, shortShow], viewport: guideStart)
        try expect(visible == [shortShow, longShow, overlap], "Only programmes overlapping the two-hour window are built, in start order, without duplicate starts")
        try expect(GuideNavigation.visible([shortShow], viewport: twoHours).isEmpty, "Programmes ending before the window are not built")
        // R19: duplicate starts and overlaps must not trap Left/Right.
        let row = [longShow, duplicate, shortShow, overlap, later]
        try expect(GuideNavigation.ordered(row).map(\.startTime) == [0, 1_800_000, 5_400_000, 9_000_000], "Navigation uses one programme per start, in order")
        try expect(GuideNavigation.neighbour(of: 1_800_000, in: row, forward: true) == overlap, "Right skips a duplicate start and reaches an overlapping programme that runs on")
        let inside = GuideProgramme(title: "Inside", description: nil, startTime: 3_600_000, endTime: 5_400_000)
        try expect(GuideNavigation.neighbour(of: 1_800_000, in: [longShow, inside, later], forward: true) == later, "Right skips a programme hidden inside the current one")
        try expect(GuideNavigation.ordered([longShow, duplicate]) == [longShow], "The first listed of duplicate starts is kept, as the grid draws it")
        try expect(GuideNavigation.neighbour(of: 0, in: row, forward: true)?.startTime == 1_800_000, "Right moves to the following programme")
        try expect(GuideNavigation.neighbour(of: 9_000_000, in: row, forward: false) == overlap, "Left moves to the adjoining earlier programme")
        try expect(GuideNavigation.neighbour(of: 1_800_000, in: row, forward: false) == shortShow, "Left moves past a duplicate start")
        try expect(GuideNavigation.neighbour(of: 9_000_000, in: row, forward: true) == nil, "Right from the last programme has no neighbour")
        try expect(!GuideNavigation.needsReload(viewport: guideStart.addingTimeInterval(3600), loadedFrom: guideStart), "Viewports inside the loaded day reuse data")
        try expect(GuideNavigation.needsReload(viewport: guideStart.addingTimeInterval(-1), loadedFrom: guideStart), "Viewports before the loaded day reload")
        try expect(GuideNavigation.needsReload(viewport: guideStart.addingTimeInterval(86400 - 7199), loadedFrom: guideStart), "A viewport that runs past the loaded day reloads")
        try expect(GuideNavigation.rounded(Date(timeIntervalSince1970: 3599)) == Date(timeIntervalSince1970: 1800), "Viewports snap to half hours")

        // Build 33 ("the guide hits a wall moving forward in time"): once
        // the loaded window has been extended past a single day, reload
        // must compare against how far data actually reaches, not always
        // `start + 24 h`; and extension itself is offered well before the
        // grid could run out of columns to move into.
        let extendedUntil = guideStart.addingTimeInterval(2 * 86400)
        try expect(!GuideNavigation.needsReload(viewport: guideStart.addingTimeInterval(86400 - 7199), loadedFrom: guideStart, until: extendedUntil),
                  "A viewport that would have run past the original day no longer reloads once the guide has been extended")
        try expect(GuideNavigation.needsReload(viewport: extendedUntil, loadedFrom: guideStart, until: extendedUntil),
                  "A viewport past even the extended data still reloads")
        let loadedUntil = guideStart.addingTimeInterval(86400)
        try expect(!GuideNavigation.needsExtension(viewport: guideStart, loadedUntil: loadedUntil), "Freshly loaded: nowhere near the edge yet")
        try expect(GuideNavigation.needsExtension(viewport: loadedUntil.addingTimeInterval(-3600), loadedUntil: loadedUntil),
                  "An hour from the loaded edge: time to fetch the next slice in the background")
        try expect(!GuideNavigation.needsExtension(viewport: loadedUntil.addingTimeInterval(-10 * 3600), loadedUntil: loadedUntil),
                  "Ten hours out: still well inside the buffer, no fetch yet")
        let mergeA = GuideProgramme(title: "A", description: nil, startTime: 0, endTime: 1_800_000)
        let mergeB = GuideProgramme(title: "B", description: nil, startTime: 1_800_000, endTime: 3_600_000)
        let mergeBRepeat = GuideProgramme(title: "B (repeat)", description: nil, startTime: 1_800_000, endTime: 3_600_000)
        let mergeC = GuideProgramme(title: "C", description: nil, startTime: 3_600_000, endTime: 5_400_000)
        try expect(GuideNavigation.mergeProgrammes([mergeA, mergeB], adding: [mergeBRepeat, mergeC]).map(\.title) == ["A", "B", "C"],
                  "A repeated start keeps the already-known programme; only the genuinely new one is appended, deduped by start time")
        try expect(GuideNavigation.mergeProgrammes([mergeA], adding: []) == [mergeA], "Nothing to add leaves the list untouched")
        let trimOld = GuideProgramme(title: "Old", description: nil, startTime: -7_200_000, endTime: -3_600_000)
        let trimRecent = GuideProgramme(title: "Recent", description: nil, startTime: -1_800_000, endTime: 1_800_000)
        try expect(GuideNavigation.trimmed([trimOld, trimRecent], keepFrom: Date(timeIntervalSince1970: -3600)).map(\.title) == ["Recent"],
                  "A programme that ended at or before the trim margin is dropped; everything after it is kept")
        try expect(GuideNavigation.guidePageRetryDelays.count == 2 && GuideNavigation.guidePageRetryDelays.reduce(0, +) == 20,
                  "Three attempts (the original plus these two backoff waits) across roughly 20 s")
        let mergeChannel = GuideChannel(rawID: "7", sourceId: 3, name: "Extend Me", logo: "logo.png", category: "News",
                                        programmes: [mergeA], stableId: "s7", number: 12, health: "ok")
        let extendedChannel = mergeChannel.withProgrammes([mergeA, mergeC])
        try expect(extendedChannel.programmes.map(\.title) == ["A", "C"] && extendedChannel.id == mergeChannel.id
                  && extendedChannel.stableId == "s7" && extendedChannel.number == 12,
                  "withProgrammes swaps only the programme list, keeping every other field")

        let categoryFixture = Data(#"{"total":1,"channels":[{"id":"7","sourceId":2,"name":"Sky News HD","logo":"  ","category":"News","programmes":[],"tvgId":"sky.news"}]}"#.utf8)
        let categorised = try JSONDecoder().decode(GuidePage.self, from: categoryFixture).channels[0]
        try expect(categorised.tvgId == "sky.news", "Guide rows carry the EPG channel ID when the server supplies it")
        try expect(categorised.matches(Category(rawID: "news-id", sourceId: 2, name: "News", channelCount: 1)), "Category filter accepts the display name")
        try expect(categorised.matches(Category(rawID: "News", sourceId: 2, name: "News & Sport", channelCount: 1)), "Category filter accepts the raw ID")
        try expect(!categorised.matches(Category(rawID: "News", sourceId: 3, name: "News", channelCount: 1)), "Category filter is source-qualified")

        // A1.1: additive guide-refresh flags, and their absence on an older server.
        let a11Info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"guideCursor":true,"guideVersion":true,"logoCache":true}}"#.utf8))
        try expect(a11Info.features.guideCursor == true && a11Info.features.guideVersion == true && a11Info.features.logoCache == true, "A1.1 flags must decode when present")
        try expect(old.features.guideCursor == nil && old.features.guideVersion == nil && old.features.logoCache == nil, "An older server without these flags must decode as absent, not false")

        let cursoredPage = try JSONDecoder().decode(GuidePage.self, from: Data(#"{"total":1,"channels":[],"nextCursor":"page-2"}"#.utf8))
        try expect(cursoredPage.nextCursor == "page-2", "A cursor page must decode nextCursor")
        let lastPage = try JSONDecoder().decode(GuidePage.self, from: Data(#"{"total":1,"channels":[]}"#.utf8))
        try expect(lastPage.nextCursor == nil, "A page without nextCursor (older server, or the last page) must decode as nil")

        let versionedCache = try JSONDecoder().decode(GuideCache.self, from: Data(#"{"savedAt":0,"window":0,"channels":[],"version":"v7"}"#.utf8))
        try expect(versionedCache.version == "v7", "A cache snapshot must decode its saved guide version")
        let oldCache = try JSONDecoder().decode(GuideCache.self, from: Data(#"{"savedAt":0,"window":0,"channels":[]}"#.utf8))
        try expect(oldCache.version == nil, "A cache file saved before A1.1 must still decode, without a version")

        // A1.1: the pure should-skip-reload decision (version equal/different/nil × coverage enough/not enough).
        let refDate = Date(timeIntervalSince1970: 1_000_000)
        let coveredWindow = refDate.addingTimeInterval(-1000) // window + loadedDuration (86400) comfortably clears now + 12h
        let barelyShortWindow = refDate.addingTimeInterval(12 * 3600 - 86400 - 1) // window + loadedDuration == now + 12h - 1s
        try expect(GuideNavigation.guideStillCovers(cachedVersion: "v1", serverVersion: "v1", window: coveredWindow, now: refDate), "Matching version with ample coverage must skip the download")
        try expect(!GuideNavigation.guideStillCovers(cachedVersion: "v1", serverVersion: "v2", window: coveredWindow, now: refDate), "A changed version must always reload")
        try expect(!GuideNavigation.guideStillCovers(cachedVersion: nil, serverVersion: "v1", window: coveredWindow, now: refDate), "No cached version must always reload")
        try expect(!GuideNavigation.guideStillCovers(cachedVersion: "v1", serverVersion: "v1", window: barelyShortWindow, now: refDate), "A matching version with insufficient coverage must still reload")

        var index = EPGArtworkIndex()
        index.append(try JSONDecoder().decode(EPGArtworkPage.self, from: Data(#"{"channels":[{"id":"sky.news","name":"Sky News","icon":"https://cdn.example.org/sky.png"},{"id":"abc","name":"ABC TV (AU)","icon":" "},{"id":"seven","name":"Seven | HD","icon":"/img/seven.png"},{"id":"bad","name":"Bad","icon":"javascript:alert(1)"}]}"#.utf8)).channels)
        try expect(index.logo(tvgID: "sky.news", name: "Something else") == "https://cdn.example.org/sky.png", "EPG ID lookup wins")
        try expect(index.logo(tvgID: nil, name: "SKY  NEWS") == "https://cdn.example.org/sky.png", "Name lookup ignores case and spacing")
        try expect(index.logo(tvgID: nil, name: "Sky News HD") == "https://cdn.example.org/sky.png", "Quality suffixes do not hide an icon")
        try expect(index.logo(tvgID: nil, name: "Seven") == "/img/seven.png", "Decorated EPG names still match")
        try expect(index.logo(tvgID: "abc", name: "ABC TV (AU)") == nil, "Blank icons are ignored")
        try expect(index.logo(tvgID: "bad", name: "Bad") == nil, "Only web URLs are accepted as icons")
        try expect(fixtureAPI.artworkRequest("javascript:alert(1)") == nil, "Non-HTTP icons never become requests")
        // Server features are optional; behaviour is capability-gated.
        let modernInfo = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.7.0","build":"0094","display":"v3.7.0 · build 0094","apiVersion":1,"features":{"library":true,"playbackResolve":true,"viewerConflict":true,"epgLogoFallback":true,"clientEvents":true,"scheduledWaiting":true,"recordingPlaybackPolling":true,"playbackTerminalStatus":true}}"#.utf8))
        try expect(modernInfo.identity == "v3.7.0 · build 0094", "Settings must retain server display/build")
        try expect(info.features.recordingPlaybackPolling == nil && info.build == nil, "Legacy info must remain compatible")
        // C-E: tuner flags are optional; absent means today's behaviour.
        try expect(modernInfo.features.timeshift == nil && modernInfo.features.recordingHls == nil, "Tuner flags are absent without PIGTV_TUNER")
        let tunerInfo = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.8.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"timeshift":true,"recordingHls":true}}"#.utf8))
        try expect(tunerInfo.features.timeshift == true && tunerInfo.features.recordingHls == true, "Tuner flags decode")
        let modern = APIClient(address: address, token: "fixture-token", session: URLSession(configuration: configuration), info: modernInfo)
        try expect(modern.info?.features.epgLogoFallback == true, "Authenticated client retains capabilities")
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseData = Data(#"{"status":"taken-over"}"#.utf8)
        let takenOver = await modern.sessionWasTakenOver("session123")
        try expect(takenOver, "Terminal status must identify a displaced session")
        try expect(FixtureProtocol.capturedRequest?.url?.path == "/api/playback/session123/terminal-status", "Terminal status uses the documented endpoint")
        try expect(FixtureProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Terminal status retains bearer authentication")
        FixtureProtocol.responseData = Data(#"{"status":"none"}"#.utf8)
        let ordinaryExpiry = await modern.sessionWasTakenOver("session123")
        try expect(!ordinaryExpiry, "Ordinary expiry keeps C2 recovery available")
        FixtureProtocol.responseStatus = 404
        let missingRoute = await modern.sessionWasTakenOver("session123")
        try expect(!missingRoute, "A missing terminal-status route keeps legacy recovery available")
        FixtureProtocol.responseStatus = 200
        let legacyRequests = FixtureProtocol.requestCount
        let legacyStatus = await fixtureAPI.sessionWasTakenOver("session123")
        try expect(!legacyStatus, "A missing feature flag must not call terminal status")
        try expect(FixtureProtocol.requestCount == legacyRequests, "Legacy terminal status is fully feature-gated")
        FixtureProtocol.responseStatus = 409
        FixtureProtocol.responseData = Data(#"{"error":"Provider stream is in use","conflict":{"type":"viewer-in-progress","streamId":"abc123","lastActiveSec":4,"message":"Another device is watching."}}"#.utf8)
        do { let _: PlaybackDecision = try await modern.request("playback/resolve", method: "POST", body: request); throw CheckFailure(description: "Viewer conflict must throw") }
        catch PigTVError.viewerConflict(let message) { try expect(message == "Another device is watching.", "Viewer message must survive decoding") }
        for payload in [#"{"conflict":{"type":"recording-in-progress","title":"Incomplete"}}"#, #"{"conflict":{"type":"future-type"}}"#] {
            FixtureProtocol.responseData = Data(payload.utf8)
            do { let _: PlaybackDecision = try await modern.request("playback/resolve"); throw CheckFailure(description: "Unknown/malformed conflict must fail safely") }
            catch PigTVError.http(409) { count += 1 }
        }
        FixtureProtocol.responseData = Data(#"{"conflict":{"type":"viewer-in-progress"}}"#.utf8)
        do { let _: PlaybackDecision = try await modern.request("playback/resolve"); throw CheckFailure(description: "Minimal viewer conflict must throw") }
        catch PigTVError.viewerConflict(let message) { try expect(!message.isEmpty, "Missing message gets a useful fallback") }
        FixtureProtocol.responseStatus = 429
        FixtureProtocol.responseData = Data(#"{"error":"Too many attempts","retryAfterSec":840}"#.utf8)
        do { let _: User = try await modern.request("auth/login"); throw CheckFailure(description: "429 must throw") }
        catch PigTVError.rateLimited(let seconds) { try expect(seconds == 840, "Read body retry delay") }
        FixtureProtocol.responseData = Data(#"{"retryAfterSec":"invalid"}"#.utf8)
        FixtureProtocol.responseHeaders = ["Retry-After": "120"]
        do { let _: User = try await modern.request("auth/login"); throw CheckFailure(description: "429 must throw") }
        catch PigTVError.rateLimited(let seconds) { try expect(seconds == 120, "Read header when body delay is malformed") }
        FixtureProtocol.responseHeaders = [:]
        do { let _: User = try await modern.request("auth/login"); throw CheckFailure(description: "429 must throw") }
        catch PigTVError.rateLimited(let seconds) { try expect(seconds == 60, "429 missing delay gets safe fallback") }

        let readyRecording = Data(#"{"url":"/api/recordings/12/media.mp4","container":"mp4","durationSec":3600}"#.utf8)
        FixtureProtocol.responseStatus = 202
        FixtureProtocol.responseData = Data(#"{"status":"preparing","retryAfterSec":3}"#.utf8)
        let beforePoll = FixtureProtocol.requestCount
        var delays: [Double] = []
        var preparingCount = 0
        let prepared = try await modern.recordingPlayback(id: 12, sleep: { seconds in
            delays.append(seconds)
            FixtureProtocol.responseStatus = 200
            FixtureProtocol.responseData = readyRecording
        }, preparing: { preparingCount += 1 })
        try expect(prepared.container == "mp4" && delays == [3] && preparingCount == 1, "202 waits then returns ready MP4")
        try expect(FixtureProtocol.requestCount == beforePoll + 2, "Preparation polls exactly as needed")
        try expect(FixtureProtocol.capturedRequest?.url?.query == "async=1", "Async query must be encoded separately")
        let _: RecordingPlayback = try await fixtureAPI.recordingPlayback(id: 12)
        try expect(FixtureProtocol.capturedRequest?.url?.query == nil, "Older servers retain the blocking request")

        FixtureProtocol.responseStatus = 202
        FixtureProtocol.responseData = Data(#"{"status":"preparing"}"#.utf8)
        FixtureProtocol.responseHeaders = ["Retry-After": "7"]
        let _: RecordingPlayback = try await modern.recordingPlayback(id: 12, sleep: { seconds in
            try expect(seconds == 7, "Preparation falls back to Retry-After header")
            FixtureProtocol.responseStatus = 200
            FixtureProtocol.responseData = readyRecording
        })
        FixtureProtocol.responseHeaders = [:]
        FixtureProtocol.responseStatus = 202
        FixtureProtocol.responseData = Data(#"{"status":"preparing","retryAfterSec":0}"#.utf8)
        let _: RecordingPlayback = try await modern.recordingPlayback(id: 12, sleep: { seconds in
            try expect(seconds == 3, "Invalid delay cannot create a tight polling loop")
            FixtureProtocol.responseStatus = 200
            FixtureProtocol.responseData = readyRecording
        })
        FixtureProtocol.responseStatus = 202
        FixtureProtocol.responseData = Data(#"{"status":"preparing","retryAfterSec":3}"#.utf8)
        var simulatedNow = Date()
        let beforeTimeout = FixtureProtocol.requestCount
        do {
            let _ = try await modern.recordingPlayback(id: 12, timeout: 2, now: { simulatedNow }, sleep: { seconds in simulatedNow += seconds })
            throw CheckFailure(description: "Preparation must time out")
        } catch PigTVError.message { try expect(FixtureProtocol.requestCount == beforeTimeout + 1, "Deadline stops polling") }
        let beforeCancel = FixtureProtocol.requestCount
        do {
            let _ = try await modern.recordingPlayback(id: 12, sleep: { _ in throw CancellationError() })
            throw CheckFailure(description: "Preparation cancellation must propagate")
        } catch is CancellationError { try expect(FixtureProtocol.requestCount == beforeCancel + 1, "Cancellation stops polling") }
        FixtureProtocol.responseStatus = 500
        for reason in ["file-missing", "remux-failed"] {
            FixtureProtocol.responseData = Data("{\"status\":\"failed\",\"reason\":\"\(reason)\"}".utf8)
            let beforeFailure = FixtureProtocol.requestCount
            do { let _ = try await modern.recordingPlayback(id: 12); throw CheckFailure(description: "Preparation failure must stop") }
            catch PigTVError.recordingPreparationFailed(let actual) {
                try expect(actual == reason && FixtureProtocol.requestCount == beforeFailure + 1, "Terminal failure cannot restart remux automatically")
            }
        }
        for status in [401, 404, 409] {
            FixtureProtocol.responseStatus = status
            FixtureProtocol.responseData = Data(#"{"error":"Unavailable"}"#.utf8)
            let beforeFailure = FixtureProtocol.requestCount
            do { let _ = try await modern.recordingPlayback(id: 12); throw CheckFailure(description: "Recording error must stop") }
            catch is PigTVError { try expect(FixtureProtocol.requestCount == beforeFailure + 1, "Recording auth/not-found/conflict cannot poll") }
        }
        // C-E (`recordingHls`): an HLS answer is returned at once (no
        // preparation polling), keeps the token, and carries `inProgress`.
        FixtureProtocol.responseStatus = 200
        FixtureProtocol.responseHeaders = [:]
        FixtureProtocol.responseData = Data(#"{"url":"/api/recordings/12/index.m3u8","container":"hls","durationSec":1800,"inProgress":true}"#.utf8)
        let beforeHLS = FixtureProtocol.requestCount
        let hlsRecording = try await modern.recordingPlayback(id: 12, sleep: { _ in throw CheckFailure(description: "HLS must not poll") })
        try expect(FixtureProtocol.requestCount == beforeHLS + 1, "HLS recording playback is one request")
        try expect(hlsRecording.isHLS && hlsRecording.isGrowing && hlsRecording.inProgress == true, "In-progress HLS recording decodes")
        let hlsURL = try modern.playbackURL(hlsRecording.url)
        try expect(hlsURL.path == "/api/recordings/12/index.m3u8" && hlsURL.query == "token=fixture-token", "HLS recording playlist carries the media token")
        FixtureProtocol.responseData = Data(#"{"url":"/api/recordings/12/index.m3u8","container":"hls","durationSec":1800,"inProgress":false}"#.utf8)
        let finishedHLS = try await modern.recordingPlayback(id: 12)
        try expect(finishedHLS.isHLS && !finishedHLS.isGrowing, "A finished HLS recording is not growing")
        FixtureProtocol.responseData = readyRecording
        let mp4 = try await modern.recordingPlayback(id: 12)
        try expect(!mp4.isHLS && !mp4.isGrowing && mp4.inProgress == nil, "MP4 answers keep working without inProgress")
        let inProgressRecording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":3,"title":"Live","status":"recording"}"#.utf8))
        let doneRecording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":4,"title":"Done","status":"completed"}"#.utf8))
        try expect(inProgressRecording.playLabel(recordingHls: false) == nil, "Without recordingHls an in-progress recording cannot play")
        try expect(inProgressRecording.playLabel(recordingHls: true) == "Watch from start (still recording)", "recordingHls offers watching from the start")
        try expect(doneRecording.playLabel(recordingHls: false) == "Play recording" && doneRecording.playLabel(recordingHls: true) == "Play recording", "Completed recordings always play")
        let edge = RecordingTimeline(current: 590, end: 600, growing: true)
        try expect(edge?.atLiveEdge == true && edge?.remaining == 10, "A growing recording near its end is live")
        try expect(RecordingTimeline(current: 590, end: 600, growing: false)?.atLiveEdge == false, "A finished recording is never live")
        try expect(RecordingTimeline(current: 30, end: 600, growing: true)?.atLiveEdge == false, "Watching from the start is not live")
        try expect(RecordingTimeline(current: .nan, end: 600, growing: false) == nil, "No timeline before a position exists")
        try expect(RecordingTimeline.skipTarget(current: 5, by: -15, end: 600) == 0 && RecordingTimeline.skipTarget(current: 595, by: 15, end: 600) == 600, "Skips stay inside the recording")
        try expect(RecordingTimeline.clock(3723) == "1:02:03" && RecordingTimeline.clock(125) == "2:05", "Recording clock")
        let waiting = try JSONDecoder().decode(ScheduledRecording.self, from: Data(#"{"id":7,"title":"Show","program_start":1000,"program_end":3000,"status":"waiting"}"#.utf8))
        try expect(waiting.canCancel && waiting.statusLabel == "Waiting — someone is watching", "Waiting schedule is explained and cancellable")
        FixtureProtocol.responseStatus = 204
        FixtureProtocol.responseData = Data()
        let beforeEvent = FixtureProtocol.requestCount
        await fixtureAPI.reportPlaybackEvent(PlaybackEvent(event: "play-start"))
        try expect(FixtureProtocol.requestCount == beforeEvent, "Missing clientEvents flag disables diagnostics")
        await modern.reportPlaybackEvent(PlaybackEvent(event: "play-start"))
        try expect(FixtureProtocol.capturedRequest?.url?.path == "/api/playback/client-event", "Diagnostics use the documented endpoint")
        try expect(FixtureProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Diagnostics retain device authentication")
        var diagnostic = PlaybackEvent(event: "media-error")
        diagnostic.path = "/api/transcode/test/stream.m3u8?token=must-not-leak&url=provider-secret"
        await modern.reportPlaybackEvent(diagnostic)
        let eventJSON = try JSONSerialization.jsonObject(with: FixtureProtocol.capturedBody) as! [String: Any]
        try expect(eventJSON["path"] as? String == "/api/transcode/test/stream.m3u8", "Diagnostics strip all query parameters")
        try expect(!String(decoding: FixtureProtocol.capturedBody, as: UTF8.self).contains("must-not-leak"), "Diagnostic body cannot carry playback token")
        FixtureProtocol.responseStatus = 500
        await modern.reportPlaybackEvent(PlaybackEvent(event: "media-error"))
        count += 1 // best effort: a server failure never throws into playback

        let now = Date(timeIntervalSince1970: 3600)
        let live = GuideProgramme(title: "Live", description: nil, startTime: 1_800_000, endTime: 7_200_000)
        try expect(GuideNavigation.revealMovingLeft(live, from: Date(timeIntervalSince1970: 5400), now: now) == GuideNavigation.rounded(now), "Partially visible live show returns to initial half-hour baseline")
        let future = GuideProgramme(title: "Future", description: nil, startTime: 7_200_000, endTime: 10_800_000)
        try expect(GuideNavigation.revealMovingLeft(future, from: Date(timeIntervalSince1970: 9000), now: now) == future.start, "Left reveals start even when programme tail remains visible")
        try expect(GuideNavigation.revealMovingLeft(future, from: now, now: now) == now, "Visible future show does not unnecessarily move viewport")

        // C-J: the resolve answer's optional `provider` (flag `providers`).
        let withProvider = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"transcode","url":"/api/transcode/s/master.m3u8","sessionId":"s","provider":{"id":2,"name":"Trex","role":"backup","via":"backup","failover":true}}"#.utf8))
        try expect(withProvider.provider == ResolveProvider(id: 2, name: "Trex", role: "backup", via: "backup", failover: true), "C-J: provider decodes")
        try expect(withProvider.provider?.label == "Trex (backup)", "C-J: a backup is labelled as one")
        let primaryOnly = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"direct","url":"/api/proxy/stream?x=1","provider":{"id":1,"name":"Strong8K","role":"primary","via":"primary","failover":false}}"#.utf8))
        try expect(primaryOnly.provider?.label == "Strong8K" && primaryOnly.provider?.failover == false, "C-J: the primary is the bare name")
        let oldServer = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"direct","url":"/api/proxy/stream?x=1"}"#.utf8))
        try expect(oldServer.provider == nil, "C-J: no provider on an older server")
        let oddProvider = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"direct","url":"/api/proxy/stream?x=1","provider":{"id":"x","role":5}}"#.utf8))
        try expect(oddProvider.provider == nil, "C-J: a malformed provider never fails the resolve")
        let flags = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"providers":true,"providerReminders":true}}"#.utf8))
        try expect(flags.features.providers == true && flags.features.providerReminders == true, "C-J/C-K flags decode")
        try expect(old.features.providers == nil && old.features.providerReminders == nil, "C-J/C-K flags are absent on an older server")

        // C-K: reminders (flag `providerReminders`).
        let reminders = try ProviderReminder.list(from: Data(#"[{"id":2,"name":"Trex","expiresAt":1774829300000,"daysLeft":3},{"id":3,"name":"","expiresAt":1},{"name":"Dream4K","expiresAt":1774000000000,"daysLeft":-4},{"id":9}]"#.utf8))
        try expect(reminders.map(\.name) == ["Trex", "Dream4K"], "C-K: reminders decode, malformed items are dropped")
        let none = try ProviderReminder.list(from: Data("[]".utf8))
        try expect(none.isEmpty, "C-K: an empty array means nothing is due")
        let utc = TimeZone(identifier: "UTC")!, au = Locale(identifier: "en_AU")
        let trex = ProviderReminder(name: "Trex", expiresAt: 1_774_828_800_000) // Mon 30 Mar 2026 00:00 UTC
        try expect(ProviderReminderText.day(trex.expiry, timeZone: utc, locale: au) == "Mon 30 Mar", "C-K: the date reads weekday day month")
        let before = Date(timeIntervalSince1970: 1_774_000_000)
        try expect(ProviderReminderText.message(for: [trex], now: before, timeZone: utc, locale: au) == "Trex expires Mon 30 Mar. Renew it with the provider; PigTV picks up the new date by itself.", "C-K: the popup wording")
        let gone = ProviderReminder(name: "Dream4K", expiresAt: 1_774_000_000_000 - 86_400_000 * 3)
        try expect(ProviderReminderText.message(for: [gone], now: before, timeZone: utc, locale: au)?.hasPrefix("Dream4K expired on ") == true, "C-K: past expiry says expired on")
        let both = ProviderReminderText.message(for: [trex, gone], now: before, timeZone: utc, locale: au) ?? ""
        try expect(both.hasPrefix("Dream4K expired on ") && both.contains(" and Trex expires Mon 30 Mar. Renew them with the provider;"), "C-K: several providers are listed together")
        try expect(ProviderReminderText.message(for: [], timeZone: utc) == nil, "C-K: nothing due, no text")
        let reminderDefaults = UserDefaults(suiteName: "pigtv.contract.reminders")!
        reminderDefaults.removePersistentDomain(forName: "pigtv.contract.reminders")
        let schedule = ProviderReminderSchedule(defaults: reminderDefaults)
        let noon = Date(timeIntervalSince1970: 1_774_000_000)
        try expect(!schedule.shownToday(now: noon, timeZone: utc), "C-K: nothing shown yet")
        schedule.markShown(now: noon, timeZone: utc)
        try expect(schedule.shownToday(now: noon.addingTimeInterval(3600), timeZone: utc), "C-K: once shown, not again the same local day")
        try expect(!schedule.shownToday(now: noon.addingTimeInterval(86_400), timeZone: utc), "C-K: back the next local day")
        reminderDefaults.removePersistentDomain(forName: "pigtv.contract.reminders")

        return count
    }
}
