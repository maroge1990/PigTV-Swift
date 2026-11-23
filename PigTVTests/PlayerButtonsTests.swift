import XCTest
import SwiftUI
@testable import PigTV

// #58, #308, #369 (option B, Mark, 23 Nov 2026): the players' buttons. Time moves on the progress bar (Start over at its
// start, Skip break and Go to live at its end), the rest in one row in a fixed order; on the Apple TV the remote moves
// through the two lines (`PlayerCursor`). Before: one row per player in its own order (the recording player's Skip break
// first, Go to live last; the live player's Go to live in the middle), no Start over on live TV, no Pause in the TV's live
// row, no Auto-skip breaks on iPad and iPhone, and the TV's hidden button names keeping their width. (`PlayerButtons`,
// `PlayerCursor`, `startOverRecording` fail to compile on the commit before; the row's widths and names fail at run time.)
final class PlayerButtonsTests: XCTestCase {

    // MARK: Which buttons, where

    func testLiveTVEveryButtonAndFewest() {
        let every = PlayerButtons.live(startOver: true, goLive: true, tracks: true, lastChannel: true, syncMarker: true)
        XCTAssertEqual(every.row, [.playPause, .tracks, .favourite, .record, .lastChannel, .syncMarker])
        XCTAssertEqual(every.bar, [.startOver, .goLive], "Start over at the bar's start, Go to live at its end")
        let fewest = PlayerButtons.live(startOver: false, goLive: false, tracks: false, lastChannel: false, syncMarker: false)
        XCTAssertEqual(fewest.row, [.playPause, .favourite, .record])
        XCTAssertEqual(fewest.bar, [])
        // iPad and iPhone: Pause is the big centre button, not a row button.
        XCTAssertEqual(PlayerButtons.live(startOver: true, goLive: false, tracks: false, lastChannel: true, syncMarker: false,
                                          pause: false).row, [.favourite, .record, .lastChannel])
    }

    func testRecordingsEveryButtonAndFewest() {
        let making = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        XCTAssertEqual(making.row, [.playPause, .autoSkip])
        XCTAssertEqual(making.bar, [.skipBreak, .goLive], "Skip break before Go to live, at the bar's end")
        let finished = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: false)
        XCTAssertEqual(finished.row, [.playPause, .autoSkip])
        XCTAssertEqual(finished.bar, [.skipBreak])
        let fewest = PlayerButtons.recording(inBreak: false, hasBreaks: false, canGoLive: false)
        XCTAssertEqual(fewest.row, [.playPause])
        XCTAssertEqual(fewest.bar, [])
        // #369: Auto-skip breaks for any recording with breaks found, on iPad and iPhone too (no Pause in their row).
        XCTAssertEqual(PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: false, pause: false).row, [.autoSkip])
        XCTAssertEqual(PlayerButtonText.autoSkip(on: false), "Auto-skip breaks: Off")
        XCTAssertEqual(PlayerButtonText.autoSkip(on: true, short: true), "Auto-skip: On", "the iPhone's shorter name")
    }

    // MARK: The Apple TV remote

    private let live = PlayerButtons.live(startOver: true, goLive: true, tracks: true, lastChannel: true, syncMarker: false)

    func testTheChromeOpensOnTheRowsFirstButtonAndLeftRightStayInTheLine() {
        var cursor = PlayerCursor()
        cursor.open(in: live)
        XCTAssertEqual(cursor.line, .row)
        XCTAssertEqual(cursor.current(in: live), .playPause, "#335: never Go to live first")
        XCTAssertTrue(cursor.move(.left, in: live))
        XCTAssertEqual(cursor.current(in: live), .playPause, "stops at the row's start")
        for _ in 0..<10 { XCTAssertTrue(cursor.move(.right, in: live)) }
        XCTAssertEqual(cursor.current(in: live), .lastChannel, "stops at the row's end")
        XCTAssertEqual(cursor.line, .row)
    }

    func testDownGoesToTheBarsRightEndAndUpComesBackWhereItLeft() {
        var cursor = PlayerCursor()
        cursor.open(in: live)
        _ = cursor.move(.right, in: live)
        _ = cursor.move(.right, in: live) // Favourite
        XCTAssertTrue(cursor.move(.down, in: live))
        XCTAssertEqual(cursor.line, .bar)
        XCTAssertEqual(cursor.current(in: live), .goLive, "the right end")
        XCTAssertTrue(cursor.move(.left, in: live))
        XCTAssertEqual(cursor.current(in: live), .startOver)
        XCTAssertTrue(cursor.move(.up, in: live))
        XCTAssertEqual(cursor.line, .row)
        XCTAssertEqual(cursor.current(in: live), .favourite, "back where it left the row")
        // Skip break before Go to live; Start over when it is all the bar has.
        let recording = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        cursor.open(in: recording)
        XCTAssertTrue(cursor.move(.down, in: recording))
        XCTAssertEqual(cursor.current(in: recording), .skipBreak)
        let startOver = PlayerButtons.live(startOver: true, goLive: false, tracks: false, lastChannel: false, syncMarker: false)
        cursor.open(in: startOver)
        XCTAssertTrue(cursor.move(.down, in: startOver))
        XCTAssertEqual(cursor.current(in: startOver), .startOver)
    }

    func testUpFromTheRowAndDownFromTheBarOrAnEmptyBarHide() {
        var cursor = PlayerCursor()
        cursor.open(in: live)
        XCTAssertFalse(cursor.move(.up, in: live), "Up from the row hides")
        XCTAssertTrue(cursor.move(.down, in: live))
        XCTAssertFalse(cursor.move(.down, in: live), "Down from the bar hides")
        let fewest = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: false)
        cursor.open(in: fewest)
        XCTAssertFalse(cursor.move(.down, in: fewest), "nothing on the bar: Down hides")
        XCTAssertEqual(cursor.line, .row)
    }

    func testABreakStartingSelectsSkipBreak() {
        var cursor = PlayerCursor()
        let before = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: false)
        cursor.open(in: before)
        _ = cursor.move(.right, in: before) // Auto-skip
        let inBreak = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: false)
        cursor.select(.skipBreak, in: inBreak)
        XCTAssertEqual(cursor.current(in: inBreak), .skipBreak)
        XCTAssertTrue(cursor.move(.up, in: inBreak))
        XCTAssertEqual(cursor.current(in: inBreak), .autoSkip, "Up returns to the button it came from")
    }

    /// A row button going moves the selection to the nearest one left in the row; a button arriving elsewhere never
    /// moves it. Codex review of 406 (reversing 406): a bar button going (Go to live reached, Skip break pressed or its
    /// break over) returns the selection to the row button it came from, never onto another bar button.
    func testADisappearingButtonMovesTheSelection() {
        var cursor = PlayerCursor()
        cursor.open(in: live)
        _ = cursor.move(.right, in: live) // Audio & subtitles
        _ = cursor.move(.down, in: live) // Go to live
        let atLive = PlayerButtons.live(startOver: true, goLive: false, tracks: true, lastChannel: true, syncMarker: false)
        XCTAssertEqual(cursor.current(in: atLive), .tracks, "back to the row button it came from, not Start over")
        cursor.settle(in: atLive)
        XCTAssertEqual(cursor.line, .row)
        XCTAssertEqual(cursor.index, 1)

        // Skip break, then Go to live: the break ends, and the selection goes back to the row, not onto Go to live.
        let making = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        cursor.open(in: making)
        _ = cursor.move(.right, in: making) // Auto-skip
        _ = cursor.move(.down, in: making) // Skip break
        let afterBreak = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: true)
        cursor.settle(in: afterBreak)
        XCTAssertEqual(cursor.current(in: afterBreak), .autoSkip)
        XCTAssertEqual(cursor.line, .row)
        XCTAssertTrue(cursor.move(.down, in: afterBreak), "Go to live is still reached by a press")
        XCTAssertEqual(cursor.current(in: afterBreak), .goLive)

        // The row's last button goes: never an index past the end.
        cursor.open(in: live)
        for _ in 0..<4 { _ = cursor.move(.right, in: live) } // Last channel
        let noLast = PlayerButtons.live(startOver: true, goLive: true, tracks: true, lastChannel: false, syncMarker: false)
        cursor.settle(in: noLast)
        XCTAssertEqual(cursor.current(in: noLast), .record)
        XCTAssertEqual(cursor.index, noLast.row.count - 1)

        // A button arriving before it (the sound tracks load) keeps it on the same button.
        let noTracks = PlayerButtons.live(startOver: false, goLive: false, tracks: false, lastChannel: true, syncMarker: false)
        cursor.open(in: noTracks)
        _ = cursor.move(.right, in: noTracks) // Favourite
        let tracks = PlayerButtons.live(startOver: false, goLive: false, tracks: true, lastChannel: true, syncMarker: false)
        cursor.settle(in: tracks)
        XCTAssertEqual(cursor.current(in: tracks), .favourite)
        XCTAssertEqual(cursor.index, 2)
    }

    /// Codex review of 406: Select on Skip break, then Select again at once, never jumps to live (it lands on the row
    /// button the remote came from).
    func testRepeatedSelectOnSkipBreakNeverGoesLive() {
        let making = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        var cursor = PlayerCursor()
        cursor.open(in: making)
        cursor.select(.skipBreak, in: making) // the break began with the info up
        XCTAssertEqual(cursor.current(in: making), .skipBreak)
        // First Select: the break is skipped (it leaves the bar); the player settles.
        let skipped = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: true)
        cursor.settle(in: skipped)
        XCTAssertEqual(cursor.current(in: skipped), .playPause, "the second Select is Pause, not Go to live")
    }

    /// Codex review of 406: the break ends just before a Select meant for Skip break: that Select never reaches Go to live.
    func testABreakEndingJustBeforeSelectNeverGoesLive() {
        let making = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        var cursor = PlayerCursor()
        cursor.open(in: making)
        _ = cursor.move(.down, in: making)
        XCTAssertEqual(cursor.current(in: making), .skipBreak)
        // No settle between the break ending and the press: what Select runs is read from the buttons now.
        let ended = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: true)
        XCTAssertEqual(cursor.current(in: ended), .playPause)
        XCTAssertNotEqual(cursor.current(in: ended), .goLive)
    }

    // MARK: Start over's eligibility while the live player is open (Codex review of 406)

    func testStartOverIsAskedAgainWhenTheInfoOpensAndAtABoundaryAtMostOnceAMinute() {
        var refresh = StartOverRefresh()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        XCTAssertNil(refresh.due(now: t0, programmeStart: 1, infoOpened: false), "the first look only notes the programme")
        XCTAssertEqual(refresh.due(now: t0, programmeStart: 1, infoOpened: true), .stale, "the info opened")
        XCTAssertNil(refresh.due(now: at(30), programmeStart: 1, infoOpened: true), "not twice a minute")
        XCTAssertNil(refresh.due(now: at(90), programmeStart: 1, infoOpened: false), "no timer: nothing changed")
        XCTAssertEqual(refresh.due(now: at(90), programmeStart: 2, infoOpened: false), .since(at(90)), "a programme boundary")
        XCTAssertNil(refresh.due(now: at(100), programmeStart: 3, infoOpened: false, loadBegan: at(90)),
                     "a load began at the boundary: done; a new boundary within the minute waits")
        XCTAssertEqual(refresh.due(now: at(151), programmeStart: 3, infoOpened: true, loadBegan: at(90)), .since(at(100)))
    }

    /// Codex sign-off of 407 and 408: a boundary inside the cooldown is kept, and stays until a recordings load that
    /// began after it is known; a load the shared cache made before it (an in-player Record, say) does not count.
    func testABoundaryInsideTheCooldownIsKeptUntilALoadAfterItBegins() {
        var refresh = StartOverRefresh()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        _ = refresh.due(now: t0, programmeStart: 1, infoOpened: false)
        XCTAssertEqual(refresh.due(now: t0, programmeStart: 1, infoOpened: true), .stale, "the info opened")
        XCTAssertNil(refresh.due(now: at(10), programmeStart: 2, infoOpened: false, loadBegan: at(5)), "a boundary in the cooldown")
        XCTAssertNil(refresh.due(now: at(30), programmeStart: 2, infoOpened: false, loadBegan: at(5)))
        XCTAssertEqual(refresh.due(now: at(61), programmeStart: 2, infoOpened: false, loadBegan: at(5)), .since(at(10)),
                       "the kept boundary: a load from after it, not the cache's age")
        XCTAssertNil(refresh.due(now: at(62), programmeStart: 2, infoOpened: false, loadBegan: at(61)), "once")
        XCTAssertNil(refresh.due(now: at(130), programmeStart: 2, infoOpened: false, loadBegan: at(61)), "consumed: no polling")
    }

    /// The shared cache refreshed (a Record in the player) between the opening ask and the boundary: the boundary still
    /// brings a read of its own once the minute is up.
    @MainActor
    func testACacheRefreshBeforeTheBoundaryDoesNotConsumeIt() async throws {
        let t0 = Date()
        let ms = t0.timeIntervalSince1970 * 1000
        let first = GuideProgramme(title: "News", description: nil, startTime: ms - 600_000, endTime: ms + 20_000)
        let second = GuideProgramme(title: "Saturday Night Football", description: nil, startTime: ms + 20_000, endTime: ms + 3_600_000)
        let row = GuideChannel(rawID: "s1", sourceId: 1, name: "Sport 1", logo: nil, category: nil, programmes: [first, second])
        let server = try FakePigTVServer(routes: .init { request in
            guard request.method == "GET" else { return nil }
            if request.path.hasPrefix("/api/recordings/scheduled") { return .json("[]") }
            if request.path == "/api/recordings" || request.path.hasPrefix("/api/recordings?") { return .json("[]") }
            return nil
        })
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client(), accountID: 1)
        browse.guide = [row]
        let playback = PlaybackModel(channel: browse.asChannel(row), client: try server.client(), programmes: row.programmes)
        func reads() -> Int { server.http.requests(path: "/api/recordings", method: "GET").count }
        await playback.refreshStartOverIfDue(browse: browse, at: t0, infoOpened: true)?.value
        XCTAssertEqual(reads(), 1, "the info opened")
        await browse.loadRecordings() // the shared cache refreshed (a Record pressed in the player)
        XCTAssertEqual(reads(), 2)
        XCTAssertNil(playback.refreshStartOverIfDue(browse: browse, at: t0.addingTimeInterval(30), infoOpened: false),
                     "the boundary, inside the minute")
        let ask = try XCTUnwrap(playback.refreshStartOverIfDue(browse: browse, at: t0.addingTimeInterval(61), infoOpened: false))
        await ask.value
        XCTAssertEqual(reads(), 3, "the boundary's own read, though the cache is under a minute old")
    }

    /// A recording that starts after tune-in: the live player's ask (the info opening) reads the schedules again, and
    /// Start over shows; before, the cached schedule stayed "scheduled" for the whole viewing.
    @MainActor
    func testARecordingStartingDuringLiveViewingBringsStartOver() async throws {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        let onNow = GuideProgramme(title: "Saturday Night Football", description: nil, startTime: ms - 600_000, endTime: ms + 3_000_000)
        let row = GuideChannel(rawID: "s1", sourceId: 1, name: "Sport 1", logo: nil, category: nil, programmes: [onNow])
        let schedule = { (status: String) in
            #"[{"id":2,"title":"Saturday Night Football","channel_name":"Sport 1","program_start":\#(Int64(onNow.startTime)),"program_end":\#(Int64(onNow.endTime)),"status":"\#(status)","recording_id":9,"source_id":1,"channel_item_id":"s1"}]"#
        }
        let recording = #"[{"id":9,"title":"Saturday Night Football","channel_name":"Sport 1","started_at":\#(onNow.startTime),"status":"recording","watch_live":true}]"#
        let nowRecording = schedule("recording")
        let server = try FakePigTVServer(routes: .init { request in
            guard request.method == "GET" else { return nil }
            if request.path.hasPrefix("/api/recordings/scheduled") { return .json(nowRecording) }
            if request.path == "/api/recordings" || request.path.hasPrefix("/api/recordings?") { return .json(recording) }
            return nil
        })
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client(), accountID: 1)
        browse.guide = [row]
        browse.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(schedule("scheduled").utf8))
        let channel = browse.asChannel(row)
        XCTAssertNil(browse.startOverRecording(channel: channel, at: now), "tuned in before the recording began")
        let playback = PlaybackModel(channel: channel, client: try server.client(), programmes: row.programmes)
        let ask = try XCTUnwrap(playback.refreshStartOverIfDue(browse: browse, at: now, infoOpened: true))
        await ask.value
        XCTAssertEqual(browse.startOverRecording(channel: channel, at: now)?.id, 9)
        XCTAssertNil(playback.refreshStartOverIfDue(browse: browse, at: now.addingTimeInterval(10), infoOpened: true),
                     "not again within the minute")
    }

    /// Codex check of 409: a boundary refresh that waits out an older recordings load sends nothing after it if its
    /// play was torn down (closed, zapped, handed off) or the session was retired meanwhile.
    @MainActor
    func testABoundaryRefreshWaitingOnAnOlderLoadSendsNothingAfterTeardownOrRetirement() async throws {
        for retire in [false, true] {
            let t0 = Date()
            let ms = t0.timeIntervalSince1970 * 1000
            let first = GuideProgramme(title: "News", description: nil, startTime: ms - 600_000, endTime: ms + 20_000)
            let second = GuideProgramme(title: "Football", description: nil, startTime: ms + 20_000, endTime: ms + 3_600_000)
            let row = GuideChannel(rawID: "s1", sourceId: 1, name: "Sport 1", logo: nil, category: nil, programmes: [first, second])
            let server = try FakePigTVServer(routes: .init { request in
                guard request.method == "GET" else { return nil }
                if request.path.hasPrefix("/api/recordings/scheduled") { return .json("[]") }
                if request.path == "/api/recordings" || request.path.hasPrefix("/api/recordings?") {
                    var answer = LocalHTTPServer.Response.json("[]")
                    answer.delay = 0.6
                    return answer
                }
                return nil
            })
            defer { server.http.stop() }
            let browse = BrowseModel(client: try server.client(), accountID: 1)
            browse.guide = [row]
            let playback = PlaybackModel(channel: browse.asChannel(row), client: try server.client(), programmes: row.programmes)
            func reads() -> Int { server.http.requests(path: "/api/recordings", method: "GET").count }
            _ = playback.refreshStartOverIfDue(browse: browse, at: t0, infoOpened: false) // notes the first programme
            let older = Task { await browse.loadRecordings() } // an older load, slow to answer
            try await Task.sleep(for: .milliseconds(100))
            let ask = try XCTUnwrap(playback.refreshStartOverIfDue(browse: browse, at: t0.addingTimeInterval(61), infoOpened: false),
                                    "the boundary asks, waiting on the older load")
            if retire { browse.retirePrivateCaches() } else { _ = await playback.stop() }
            await older.value
            await ask.value
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(reads(), 1, retire ? "nothing on a retired session's token" : "nothing for a play that has stopped")
        }
    }

    // MARK: Touch: a finger on a control keeps the controls (Codex review of 406)

    func testAHeldControlKeepsTheControlsPastTheIdleDeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let late = now.addingTimeInterval(PlayerChromeTimer.idle + 2)
        XCTAssertTrue(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: late, paused: false, panelOpen: false))
        XCTAssertFalse(PlayerChromeTimer.shouldHide(visible: true, lastInput: now, now: late, paused: false, panelOpen: false,
                                                    held: true), "a finger is down on Skip break")
    }

    // MARK: Start over on live TV (#308)

    @MainActor
    func testStartOverIsTheRecordingOfTheProgrammeOnNow() throws {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        let onNow = GuideProgramme(title: "Saturday Night Football", description: nil, startTime: ms - 1_800_000, endTime: ms + 1_800_000)
        let later = GuideProgramme(title: "Late News", description: nil, startTime: ms + 1_800_000, endTime: ms + 3_600_000)
        let row = GuideChannel(rawID: "s1", sourceId: 1, name: "Sport 1", logo: nil, category: nil, programmes: [onNow, later])
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        browse.guide = [row]
        let channel = browse.asChannel(row)
        XCTAssertNil(browse.startOverRecording(channel: channel, at: now), "nothing recorded")

        func schedule(status: String, start: Double) throws -> ScheduledRecording {
            try JSONDecoder().decode(ScheduledRecording.self, from: Data(#"{"id":2,"title":"Saturday Night Football","channel_name":"Sport 1","program_start":\#(Int64(start)),"program_end":\#(Int64(start + 3_600_000)),"status":"\#(status)","recording_id":9,"source_id":1,"channel_item_id":"s1"}"#.utf8))
        }
        func recording(watchLive: Bool) throws -> Recording {
            try JSONDecoder().decode(Recording.self, from: Data(#"{"id":9,"title":"Saturday Night Football","channel_name":"Sport 1","started_at":\#(onNow.startTime),"status":"recording","watch_live":\#(watchLive)}"#.utf8))
        }
        browse.schedules = [try schedule(status: "recording", start: onNow.startTime)]
        browse.recordings = [try recording(watchLive: true)]
        XCTAssertEqual(browse.startOverRecording(channel: channel, at: now)?.id, 9)
        XCTAssertNil(browse.startOverRecording(channel: channel, at: now.addingTimeInterval(1_900)), "the next programme is not recorded")
        browse.recordings = [try recording(watchLive: false)]
        XCTAssertNil(browse.startOverRecording(channel: channel, at: now), "the server cannot play it from its start")
        browse.recordings = [try recording(watchLive: true)]
        browse.schedules = [try schedule(status: "scheduled", start: onNow.startTime)]
        XCTAssertNil(browse.startOverRecording(channel: channel, at: now), "scheduled, not recording")
    }

    // MARK: The Apple TV's row (#369)

    #if os(tvOS)
    /// Every button has the same width whatever its name, and every name is drawn (not only the selected one's).
    @MainActor
    func testEveryRowButtonHasTheSameWidthAndShowsItsName() throws {
        func image(_ labels: [String]) throws -> CGImage {
            let renderer = ImageRenderer(content: PlayerActionRow(items: labels.map { ("circle", $0) }, selected: 0)
                .environment(\.colorScheme, .dark))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage)
        }
        let long = try image(["Pause", "Auto-skip breaks: Off"])
        let short = try image(["A", "B"])
        XCTAssertEqual(long.width, short.width, "a long name used to widen its button")
        // The second (unselected) button's name: something drawn under its circle.
        let drawn = try opaquePixels(long, in: CGRect(x: long.width / 2, y: Int(Double(long.height) * 0.7),
                                                      width: long.width / 2, height: long.height - Int(Double(long.height) * 0.7)))
        XCTAssertGreaterThan(drawn, 20, "the unselected button's name is not drawn")
    }

    private func opaquePixels(_ image: CGImage, in rect: CGRect) throws -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drew = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        var count = 0
        // Rows in `data` run top to bottom (the context draws the image upright).
        for y in Int(rect.minY)..<min(height, Int(rect.maxY)) {
            for x in Int(rect.minX)..<min(width, Int(rect.maxX)) where data[(y * width + x) * 4 + 3] > 128 { count += 1 }
        }
        return count
    }
    #endif
}

/// Codex review of 406 (high): Start over's hand-off. Before, it joined the cancellable hand-off only after the live play's
/// release had returned, so a newer play or the background during a slow release was overridden by the old recording,
/// and a second press started a second hand-off. Each test fails on 406.
@MainActor
final class StartOverHandoffTests: XCTestCase {
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
    }

    /// A live play on the fake server whose release takes `releaseDelay`, running; the recording of its programme.
    private func playing(releaseDelay: TimeInterval) async throws -> (AppModel, BrowseModel, PlaybackModel, Recording) {
        guard HLSFixture.isComplete else { throw XCTSkip("no fixture") }
        let server = try FakePigTVServer(routes: .init { request in
            guard request.method == "DELETE", request.path.hasPrefix("/api/playback/") else { return nil }
            var answer = LocalHTTPServer.Response.json(#"{"success":true}"#)
            answer.delay = releaseDelay
            return answer
        })
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let delay = AppModel.coverCloseDelay
        AppModel.coverCloseDelay = .milliseconds(50)
        cleanups.append {
            AppModel.coverCloseDelay = delay
            if let playback = app.playback { await app.endPlayback(playback) }
            server.http.stop()
        }
        app.beginPlayback(browse.asChannel(browse.guide[2]))
        let playback = try XCTUnwrap(app.playback)
        app.playerAppeared(playback)
        playback.start()
        let end = Date().addingTimeInterval(10)
        while !playback.ready && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(playback.ready, "the play is resolved")
        let recording = try XCTUnwrap(PlayerButtonsFixture.recordNow(playback.channel, in: browse))
        return (app, browse, playback, recording)
    }

    private func link(_ row: GuideChannel) throws -> URL {
        try XCTUnwrap(URL(string: "pigtv://play?sourceId=\(row.sourceId)&id=\(row.rawID)"))
    }

    func testANewerChannelDuringTheReleaseWins() async throws {
        let (app, browse, playback, recording) = try await playing(releaseDelay: 0.6)
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(150)) // the release is waiting on the server
        app.open(try link(browse.guide[1])) // a Top Shelf channel
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(app.presenter.presented, "the old Start over did not open its recording over the newer play")
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[1]).id)
    }

    /// Codex sign-off of 407 (high): the live play being torn down is not an existing play: a newer request for the same
    /// channel cancels Start over and tunes once the release is done.
    func testANewerPlayOfTheSameChannelDuringTheReleaseWins() async throws {
        let (app, browse, playback, recording) = try await playing(releaseDelay: 0.6)
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(150))
        app.open(try link(browse.guide[2])) // the channel being torn down, from the Top Shelf
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(app.presenter.presented, "Start over did not open its recording over the newer request")
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[2]).id, "the channel plays live again")
        XCTAssertFalse(app.playback === playback, "as a new play, after the old one's release")
    }

    /// The same through "Watch when it starts" on a Sport event on that channel (starting now).
    func testASportWatchOfTheSameChannelDuringTheReleaseWins() async throws {
        let (app, browse, playback, recording) = try await playing(releaseDelay: 0.6)
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(150))
        let row = browse.guide[2]
        let now = Date().timeIntervalSince1970 * 1000
        let event = SportEvent(id: "e", title: "Event", league: "AFL", startTime: now - 60_000, endTime: now + 3_600_000,
                               channels: [SportEventChannel(sourceId: row.sourceId, rawID: row.rawID, name: row.name)])
        app.watchWhenStarts(event)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(app.presenter.presented, "Start over did not open its recording over the Sport watch")
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(row).id)
        XCTAssertFalse(app.playback === playback)
    }

    /// Codex sign-off of 408: Start over, a newer play link, then Start over again for the play still being released:
    /// the repeat does nothing, and the newer play is not cancelled.
    func testARepeatedStartOverAfterANewerPlayDoesNotCancelIt() async throws {
        let (app, browse, playback, recording) = try await playing(releaseDelay: 0.6)
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(100))
        app.open(try link(browse.guide[1]))
        app.startOver(playback, recording: recording) // a repeated press, the old play still current
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(app.presenter.presented, "the recording did not open over the newer play")
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[1]).id)
    }

    /// Codex sign-off of 408: a zap waiting for the release keeps what a switch keeps: Last channel returns to the
    /// channel left, and a Sport play keeps its channels and its event.
    func testAZapDuringTheReleaseKeepsLastChannelAndTheSportPlay() async throws {
        let (app, browse, playback, recording) = try await playing(releaseDelay: 0.6)
        let rows = [browse.guide[2], browse.guide[3], browse.guide[4]]
        let now = Date().timeIntervalSince1970 * 1000
        let event = SportEvent(id: "e1", title: "Event", league: "AFL", startTime: now - 60_000, endTime: now + 3_600_000,
                               channels: rows.map { SportEventChannel(sourceId: $0.sourceId, rawID: $0.rawID, name: $0.name) })
        app.playSportEvent(event, channel: event.channels[0]) // already on that channel: the play becomes the event's
        XCTAssertEqual(app.sportPlay?.eventID, "e1")
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(100))
        app.zap(1) // channel up, during the release
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(app.presenter.presented)
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(rows[1]).id, "the next of the event's channels")
        XCTAssertEqual(app.previousChannel?.id, browse.asChannel(rows[0]).id, "Last channel returns to the channel left")
        XCTAssertEqual(app.sportPlay?.eventID, "e1", "the Sport play and its event")
        XCTAssertEqual(app.zapList.map(\.id), rows.map { browse.asChannel($0).id }, "the event's channels")
    }

    func testGoingToTheBackgroundDuringTheReleaseDropsIt() async throws {
        let (app, _, playback, recording) = try await playing(releaseDelay: 0.6)
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(150))
        await app.background()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNil(app.presenter.presented, "returning to the foreground never starts a play by itself")
    }

    func testASecondPressWhileItIsUnderWayDoesNothingAndTheRecordingOpensOnce() async throws {
        let (app, _, playback, recording) = try await playing(releaseDelay: 0.4)
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: .pigCloseCovers, object: nil, queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(100))
        app.startOver(playback, recording: recording)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(closed, 1, "one hand-off")
        XCTAssertNil(app.playback, "the live play ended")
        XCTAssertEqual(app.presenter.presented?.id, "player:\(recording.id)", "the recording opened, from its start")
    }
}
