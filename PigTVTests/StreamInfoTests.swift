import XCTest
import CoreMedia
@testable import PigTV

// A4.2: naming and formatting for the Labs stream info line.
final class StreamInfoTests: XCTestCase {
    func testFourCCAndCodecNames() {
        XCTAssertEqual(StreamInfoFormat.fourCC(kCMVideoCodecType_HEVC), "hvc1")
        XCTAssertEqual(StreamInfoFormat.fourCC(kCMVideoCodecType_H264), "avc1")
        XCTAssertEqual(StreamInfoFormat.codecName("avc1"), "H.264")
        XCTAssertEqual(StreamInfoFormat.codecName("avc3"), "H.264")
        XCTAssertEqual(StreamInfoFormat.codecName("hev1"), "HEVC")
        XCTAssertEqual(StreamInfoFormat.codecName("dvh1"), "HEVC")
        XCTAssertEqual(StreamInfoFormat.codecName("xyz9"), "xyz9")
    }

    func testDynamicRange() {
        let pq = String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        let hlg = String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG)
        let sdr = String(kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        XCTAssertEqual(StreamInfoFormat.dynamicRange(subtype: "hvc1", transferFunction: pq, hasDolbyVisionConfig: false), "HDR10")
        XCTAssertEqual(StreamInfoFormat.dynamicRange(subtype: "hvc1", transferFunction: hlg, hasDolbyVisionConfig: false), "HLG")
        XCTAssertNil(StreamInfoFormat.dynamicRange(subtype: "avc1", transferFunction: sdr, hasDolbyVisionConfig: false))
        XCTAssertNil(StreamInfoFormat.dynamicRange(subtype: "avc1", transferFunction: nil, hasDolbyVisionConfig: false))
        XCTAssertEqual(StreamInfoFormat.dynamicRange(subtype: "dvh1", transferFunction: pq, hasDolbyVisionConfig: false), "Dolby Vision")
        XCTAssertEqual(StreamInfoFormat.dynamicRange(subtype: "hvc1", transferFunction: pq, hasDolbyVisionConfig: true), "Dolby Vision")
    }

    func testNumbers() {
        XCTAssertEqual(StreamInfoFormat.frameRate(25), "25 fps")
        XCTAssertEqual(StreamInfoFormat.frameRate(50.0001), "50 fps")
        XCTAssertEqual(StreamInfoFormat.frameRate(59.94006), "59.94 fps")
        XCTAssertEqual(StreamInfoFormat.bitrate(8_421_000), "8.4 Mb/s")
        XCTAssertEqual(StreamInfoFormat.bitrate(850_400), "850 kb/s")
        XCTAssertNil(StreamInfoFormat.bitrate(-1))
        XCTAssertNil(StreamInfoFormat.bitrate(.nan))
        XCTAssertEqual(StreamInfoFormat.droppedFrames([3, -1, 4]), 7)
        XCTAssertNil(StreamInfoFormat.droppedFrames([-1]))
        XCTAssertNil(StreamInfoFormat.droppedFrames([]))
    }

    func testLine() {
        var stats = StreamStats(codec: "HEVC", dynamicRange: "HDR10", width: 3840, height: 2160, frameRate: 50,
                                indicatedBitrate: 15_200_000, observedBitrate: 42_000_000, droppedFrames: 2, stalls: 1,
                                strategy: "transcode", videoMode: "copy", server: "v1.2.0 · build 0124")
        XCTAssertEqual(stats.line,
                       "HEVC HDR10 · 3840×2160 @ 50 fps · 15.2 Mb/s (observed 42.0 Mb/s) · 2 dropped · 1 stall · transcode · video copy · Server v1.2.0 · build 0124")
        stats = StreamStats(strategy: "direct")
        XCTAssertEqual(stats.line, "0 stalls · direct")
    }
}
