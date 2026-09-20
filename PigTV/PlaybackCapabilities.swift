import AVFoundation

@MainActor
enum PlaybackCapabilities {
    static func current(supports: (String) -> Bool = AVURLAsset.isPlayableExtendedMIMEType) -> [String: Bool] {
        // Ask the native playback stack rather than treating every Apple client
        // as a browser without HEVC. Both common HEVC profiles must be supported.
        let hevc = supports("video/mp4; codecs=\"hvc1.1.6.L123.B0\"") &&
                   supports("video/mp4; codecs=\"hvc1.2.4.L123.B0\"")
        return [
            "hls": true,
            // AVPlayer needs segmented live delivery, independently of codec support.
            "segmentedDelivery": true,
            "fmp4": true,
            "hevc": hevc,
            "av1": false,
            "ac3": supports("audio/mp4; codecs=\"ac-3\""),
            "eac3": supports("audio/mp4; codecs=\"ec-3\""),
            "flac": false
        ]
    }
}
