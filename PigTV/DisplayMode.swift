import Foundation
import AVFoundation
import CoreMedia

// Build 27: the TV's display mode (frame rate and HDR) comes straight from the
// resolve decision's `info` (fps, videoRange) instead of loading the asset's
// `preferredDisplayCriteria`. On the device, that load of a live master
// playlist never finished within its 3 s bound, and playback waited for it,
// so every channel started ~3 s late (server log: first picture − resolve
// ≈ 3.0 s). Nothing here waits on the network. Pure; tests `DisplayModeTests`.
nonisolated struct DisplayMode: Equatable, Sendable {
    enum Range: String, Sendable {
        case sdr, pq, hlg
        var isHDR: Bool { self != .sdr }
    }

    let refreshRate: Double
    let range: Range
    let codec: CMVideoCodecType
    let width: Int32
    let height: Int32

    /// Mirrors the server's `parseFrameRate`: "25/1", "30000/1001" or "50";
    /// nil outside 1…240 fps (ffprobe says 90000/1 or 0/0 when it cannot tell).
    static func frameRate(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map { Double($0) }
        let rate: Double?
        switch parts.count {
        case 1: rate = parts[0]
        case 2:
            if let num = parts[0], let den = parts[1], den != 0 { rate = num / den } else { rate = nil }
        default: rate = nil
        }
        guard let rate, rate.isFinite, rate >= 1, rate <= 240 else { return nil }
        return rate
    }

    /// "PQ" → .pq, "HLG" → .hlg; anything else (null, "SDR") → .sdr.
    static func range(_ text: String?) -> Range {
        switch text?.uppercased() {
        case "PQ": return .pq
        case "HLG": return .hlg
        default: return .sdr
        }
    }

    /// The mode for a resolve decision, or nil when the server gave no usable
    /// frame rate (then the asset's criteria are applied later, never awaited).
    /// An encoded video is SDR whatever the source was (the server's rule).
    static func make(videoMode: String?, info: ResolveStreamInfo?) -> DisplayMode? {
        guard let info, let rate = frameRate(info.fps) else { return nil }
        let range = videoMode == "encode" ? .sdr : range(info.videoRange)
        let copied = videoMode != "encode"
        // Only the colour extensions and the rate matter to the display
        // manager; the codec is the copied source's where known.
        let hevc = copied && ["hevc", "h265"].contains(info.video?.lowercased() ?? "") || range.isHDR
        let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let width = copied ? (info.width ?? 0) : 0
        let height = copied ? (info.height ?? 0) : 0
        let known = width > 0 && height > 0 && width <= 8192 && height <= 8192
        return DisplayMode(refreshRate: rate, range: range, codec: codec,
                           width: Int32(known ? width : 1920), height: Int32(known ? height : 1080))
    }

    var transferFunction: CFString {
        switch range {
        case .pq: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case .sdr: return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
    }
    var colorPrimaries: CFString {
        range.isHDR ? kCMFormatDescriptionColorPrimaries_ITU_R_2020 : kCMFormatDescriptionColorPrimaries_ITU_R_709_2
    }
    var matrix: CFString {
        range.isHDR ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
    }

    /// A video format description carrying the colour extensions the display
    /// manager reads (transfer function, primaries, matrix).
    func formatDescription() -> CMVideoFormatDescription? {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_ColorPrimaries: colorPrimaries,
            kCMFormatDescriptionExtension_YCbCrMatrix: matrix
        ]
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: width, height: height,
                                                    extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    #if os(tvOS)
    /// `AVDisplayCriteria(refreshRate:formatDescription:)` is AVFoundation
    /// API (tvOS 17+), not an AVKit category.
    func criteria() -> AVDisplayCriteria? {
        guard let description = formatDescription() else { return nil }
        return AVDisplayCriteria(refreshRate: Float(refreshRate), formatDescription: description)
    }
    #endif
}
