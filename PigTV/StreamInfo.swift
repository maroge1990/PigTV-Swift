import Foundation
import AVFoundation
import CoreMedia

// Roadmap A4.2 (Labs → Stream info overlay): one compact line of stream
// statistics in the tvOS player's info overlay. The naming and formatting is
// pure (unit-tested in StreamInfoTests); PlaybackModel.streamStats() gathers
// the raw values from the player item.

nonisolated struct StreamStats: Equatable, Sendable {
    var codec: String?
    var dynamicRange: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var indicatedBitrate: Double?
    var observedBitrate: Double?
    var droppedFrames: Int?
    var stalls = 0
    /// "direct", or "transcode" plus the server's video route ("copy"/"encode").
    var strategy: String?
    var videoMode: String?
    var server: String?
    /// C-J: the provider serving this play (nil on an older server).
    var provider: ResolveProvider?

    /// The overlay line's parts, in order; missing values are left out.
    var parts: [String] {
        var parts: [String] = []
        let video = [codec, dynamicRange].compactMap { $0 }.joined(separator: " ")
        if !video.isEmpty { parts.append(video) }
        if let width, let height, width > 0, height > 0 {
            var size = "\(width)×\(height)"
            if let frameRate, frameRate > 0 { size += " @ " + StreamInfoFormat.frameRate(frameRate) }
            parts.append(size)
        } else if let frameRate, frameRate > 0 {
            parts.append(StreamInfoFormat.frameRate(frameRate))
        }
        let indicated = indicatedBitrate.flatMap(StreamInfoFormat.bitrate)
        let observed = observedBitrate.flatMap(StreamInfoFormat.bitrate)
        switch (indicated, observed) {
        case let (i?, o?): parts.append("\(i) (observed \(o))")
        case let (i?, nil): parts.append(i)
        case let (nil, o?): parts.append("observed \(o)")
        default: break
        }
        if let droppedFrames { parts.append("\(droppedFrames) dropped") }
        parts.append(stalls == 1 ? "1 stall" : "\(stalls) stalls")
        if let route = StreamInfoFormat.route(strategy: strategy, videoMode: videoMode) { parts.append(route) }
        if let provider {
            // The primary with no failover is the ordinary case: match the
            // line's density and show the name only when it is not.
            if provider.isBackup || provider.failover {
                parts.append("Provider: \(provider.label)")
                if provider.failover { parts.append("switched from primary") }
            }
        }
        if let server, !server.isEmpty { parts.append("Server \(server)") }
        return parts
    }

    var line: String { parts.joined(separator: " · ") }
}

nonisolated enum StreamInfoFormat {
    /// Four-character code as text ("hvc1").
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }

    /// Display name for a video sample description subtype.
    static func codecName(_ subtype: String) -> String? {
        switch subtype {
        case "avc1", "avc2", "avc3", "avc4": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "HEVC"
        case "dva1", "dvav": return "H.264"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4"
        case "mp2v", "mpg2": return "MPEG-2"
        default: return subtype.trimmingCharacters(in: .whitespaces).isEmpty ? nil : subtype
        }
    }

    /// Dolby Vision (its own sample entry, or a DV configuration box on an
    /// HEVC entry), else HDR10 (PQ) or HLG from the transfer function; nil
    /// for SDR.
    static func dynamicRange(subtype: String, transferFunction: String?, hasDolbyVisionConfig: Bool) -> String? {
        if ["dvh1", "dvhe", "dva1", "dvav"].contains(subtype) || hasDolbyVisionConfig { return "Dolby Vision" }
        switch transferFunction {
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): return "HDR10"
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): return "HLG"
        default: return nil
        }
    }

    /// "25 fps", "59.94 fps".
    static func frameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        if rounded == rounded.rounded() { return "\(Int(rounded)) fps" }
        return String(format: "%.2f fps", rounded)
    }

    /// "8.4 Mb/s" or "850 kb/s"; nil for a missing (≤ 0 or non-finite) value.
    static func bitrate(_ bitsPerSecond: Double) -> String? {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return nil }
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000) }
        return "\(Int((bitsPerSecond / 1000).rounded())) kb/s"
    }

    /// "direct", "transcode · video copy", "transcode · video encode".
    static func route(strategy: String?, videoMode: String?) -> String? {
        switch (strategy, videoMode) {
        case let (s?, m?): return "\(s) · video \(m)"
        case let (s?, nil): return s
        case let (nil, m?): return "video \(m)"
        default: return nil
        }
    }

    /// Frames dropped over the whole item: the access log starts a new event
    /// on every variant switch, each counting its own drops. nil when no
    /// event reports a count (the log uses a negative value for unknown).
    static func droppedFrames(_ perEvent: [Int]) -> Int? {
        let known = perEvent.filter { $0 >= 0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

extension PlaybackModel {
    /// The current values for the Labs stream info line. Async because the
    /// video track's format descriptions and frame rate are loaded properties.
    func streamStats() async -> StreamStats {
        var stats = StreamStats()
        stats.stalls = stallCount
        stats.strategy = routeStrategy
        stats.videoMode = routeVideoMode
        stats.server = serverIdentity
        stats.provider = provider
        guard let item = player.currentItem else { return stats }
        let size = item.presentationSize
        if size.width > 0, size.height > 0 { stats.width = Int(size.width); stats.height = Int(size.height) }
        let log = item.accessLog()?.events ?? []
        if let last = log.last {
            stats.indicatedBitrate = last.indicatedBitrate
            stats.observedBitrate = last.observedBitrate
        }
        stats.droppedFrames = StreamInfoFormat.droppedFrames(log.map(\.numberOfDroppedVideoFrames))
        guard let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) else { return stats }
        let current = Double(track.currentVideoFrameRate)
        if let asset = track.assetTrack {
            if let descriptions = try? await asset.load(.formatDescriptions), let format = descriptions.first {
                let subtype = StreamInfoFormat.fourCC(CMFormatDescriptionGetMediaSubType(format))
                stats.codec = StreamInfoFormat.codecName(subtype)
                let transfer = CMFormatDescriptionGetExtension(format,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                let atoms = CMFormatDescriptionGetExtension(format,
                    extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
                let dolby = atoms.map { $0.keys.contains("dvcC") || $0.keys.contains("dvvC") } ?? false
                stats.dynamicRange = StreamInfoFormat.dynamicRange(subtype: subtype, transferFunction: transfer,
                                                                   hasDolbyVisionConfig: dolby)
            }
            if let nominal = try? await asset.load(.nominalFrameRate), nominal > 0 { stats.frameRate = Double(nominal) }
        }
        if stats.frameRate == nil, current > 0 { stats.frameRate = current }
        return stats
    }
}
