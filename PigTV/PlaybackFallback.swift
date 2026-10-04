import Foundation
import AVKit
import Combine

// What the player does about a known device error (split out of PlaybackModel.swift in build 39).

/// One level of a player error (the error and its underlying errors).
nonisolated struct PlayerErrorCode: Equatable, Sendable {
    let domain: String
    let code: Int
}

/// Build 27: device errors with a one-off cure (Mark's log, test block 26).
nonisolated enum PlaybackFallback: Equatable, Sendable {
    /// AVErrorNoCompatibleAlternatesForExternalDisplay (-11868): the HDR
    /// master playlist on a TV that cannot show it.
    case streamPlaylist
    /// kAudioFormatUnsupportedDataFormatError ('fmt?' = 1718449215): copied
    /// audio the device cannot decode.
    case audioEncode

    static let noCompatibleAlternates = -11868
    static let unsupportedAudioFormat = 1718449215

    static func `for`(_ codes: [PlayerErrorCode]) -> PlaybackFallback? {
        if codes.contains(where: { $0.domain == AVFoundationErrorDomain && $0.code == noCompatibleAlternates }) {
            return .streamPlaylist
        }
        if codes.contains(where: { $0.code == unsupportedAudioFormat }) { return .audioEncode }
        return nil
    }
}

/// Channels (by `identityKey`) that play only with re-encoded audio on this
/// device, so later plays request `audioEncode` from the first resolve.
nonisolated enum AudioEncodeMemory {
    static let key = "pigtv.audioEncode.channels"

    static func contains(_ channel: String, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(channel)
    }

    static func remember(_ channel: String, in defaults: UserDefaults = .standard) {
        var channels = defaults.stringArray(forKey: key) ?? []
        guard !channels.contains(channel) else { return }
        channels.append(channel)
        defaults.set(Array(channels.suffix(200)), forKey: key)
    }
}
