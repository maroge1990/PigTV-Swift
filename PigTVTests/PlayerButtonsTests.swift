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

    /// A button going (Go to live at the live point, Skip break when the break ends) moves the selection to the nearest
    /// one left in its line, or back to the row; a button arriving elsewhere never moves it.
    func testADisappearingButtonMovesTheSelectionToTheNearestOne() {
        var cursor = PlayerCursor()
        cursor.open(in: live)
        _ = cursor.move(.right, in: live) // Audio & subtitles
        _ = cursor.move(.down, in: live) // Go to live
        let atLive = PlayerButtons.live(startOver: true, goLive: false, tracks: true, lastChannel: true, syncMarker: false)
        XCTAssertEqual(cursor.current(in: atLive), .startOver, "the nearest on the bar")
        cursor.settle(in: atLive)
        XCTAssertEqual(cursor.index, 0)
        let empty = PlayerButtons.live(startOver: false, goLive: false, tracks: true, lastChannel: true, syncMarker: false)
        cursor.settle(in: empty)
        XCTAssertEqual(cursor.line, .row, "the bar is empty: back to the row")
        XCTAssertEqual(cursor.current(in: empty), .tracks, "where it left the row")

        // Skip break, then Go to live: the break ends, Go to live stays.
        let making = PlayerButtons.recording(inBreak: true, hasBreaks: true, canGoLive: true)
        cursor.open(in: making)
        _ = cursor.move(.down, in: making)
        let afterBreak = PlayerButtons.recording(inBreak: false, hasBreaks: true, canGoLive: true)
        cursor.settle(in: afterBreak)
        XCTAssertEqual(cursor.current(in: afterBreak), .goLive)
        XCTAssertEqual(cursor.index, 0)

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
