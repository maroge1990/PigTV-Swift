import XCTest
import AVFoundation
import CoreMedia
@testable import PigTV

// Build 27: the display mode is built from the resolve decision, never by
// waiting for the asset's criteria.
@MainActor
final class DisplayModeTests: XCTestCase {
    func testFrameRateParsingMatchesTheServer() {
        XCTAssertEqual(DisplayMode.frameRate("25/1"), 25)
        XCTAssertEqual(DisplayMode.frameRate("50/1"), 50)
        XCTAssertEqual(DisplayMode.frameRate("30000/1001")!, 29.97, accuracy: 0.001)
        XCTAssertEqual(DisplayMode.frameRate("60000/1001")!, 59.94, accuracy: 0.001)
        XCTAssertEqual(DisplayMode.frameRate("50"), 50)
        XCTAssertNil(DisplayMode.frameRate(nil))
        XCTAssertNil(DisplayMode.frameRate(""))
        XCTAssertNil(DisplayMode.frameRate("0/0"))
        XCTAssertNil(DisplayMode.frameRate("90000/1"), "the TS clock is not a frame rate")
        XCTAssertNil(DisplayMode.frameRate("abc"))
        XCTAssertNil(DisplayMode.frameRate("25/1/2"))
    }

    func testRangeParsing() {
        XCTAssertEqual(DisplayMode.range("PQ"), .pq)
        XCTAssertEqual(DisplayMode.range("HLG"), .hlg)
        XCTAssertEqual(DisplayMode.range("SDR"), .sdr)
        XCTAssertEqual(DisplayMode.range(nil), .sdr)
    }

    func testDecisionDecodesInfoTolerantly() throws {
        let full = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"transcode","url":"/api/transcode/a/master.m3u8","videoMode":"copy","info":{"fps":"50/1","videoRange":"PQ","video":"hevc","width":3840,"height":2160,"audio":"aac","subtitles":[]}}"#.utf8))
        XCTAssertEqual(full.info, ResolveStreamInfo(fps: "50/1", videoRange: "PQ", video: "hevc", width: 3840, height: 2160))
        let odd = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"transcode","url":"/x","info":{"fps":25,"videoRange":7,"width":"wide"}}"#.utf8))
        XCTAssertEqual(odd.info?.fps.flatMap(DisplayMode.frameRate), 25)
        XCTAssertNil(odd.info?.videoRange)
        XCTAssertNil(odd.info?.width)
        let broken = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"direct","url":"/x","info":"nope"}"#.utf8))
        XCTAssertNil(broken.info)
        let none = try JSONDecoder().decode(PlaybackDecision.self, from: Data(#"{"strategy":"direct","url":"/x"}"#.utf8))
        XCTAssertNil(none.info)
    }

    func testModeFromDecision() {
        let hdr = DisplayMode.make(videoMode: "copy", info: ResolveStreamInfo(fps: "50/1", videoRange: "PQ", video: "hevc", width: 3840, height: 2160))
        XCTAssertEqual(hdr?.refreshRate, 50)
        XCTAssertEqual(hdr?.range, .pq)
        XCTAssertEqual(hdr?.codec, kCMVideoCodecType_HEVC)
        XCTAssertEqual(hdr?.width, 3840)
        let encoded = DisplayMode.make(videoMode: "encode", info: ResolveStreamInfo(fps: "25/1", videoRange: "HLG", video: "hevc", width: 3840, height: 2160))
        XCTAssertEqual(encoded?.range, .sdr, "an encode is SDR whatever the source")
        XCTAssertEqual(encoded?.width, 1920)
        let hlg = DisplayMode.make(videoMode: "copy", info: ResolveStreamInfo(fps: "25/1", videoRange: "HLG"))
        XCTAssertEqual(hlg?.range, .hlg)
        XCTAssertNil(DisplayMode.make(videoMode: "copy", info: ResolveStreamInfo(fps: nil, videoRange: "PQ")),
                     "no usable frame rate: fall back to the asset, asynchronously")
        XCTAssertNil(DisplayMode.make(videoMode: "copy", info: nil))
    }

    func testFormatDescriptionCarriesTheTransferFunction() throws {
        let cases: [(String?, CFString, CFString)] = [
            ("PQ", kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionColorPrimaries_ITU_R_2020),
            ("HLG", kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, kCMFormatDescriptionColorPrimaries_ITU_R_2020),
            (nil, kCMFormatDescriptionTransferFunction_ITU_R_709_2, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        ]
        for (range, transfer, primaries) in cases {
            let mode = try XCTUnwrap(DisplayMode.make(videoMode: "copy", info: ResolveStreamInfo(fps: "25/1", videoRange: range)))
            let description = try XCTUnwrap(mode.formatDescription())
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
            XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String, transfer as String)
            XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, primaries as String)
            #if os(tvOS)
            XCTAssertNotNil(mode.criteria())
            #endif
        }
    }
}
