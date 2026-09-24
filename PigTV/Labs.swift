import Foundation

// Contract C-F: Settings → Labs. Persistent opt-in switches for risky
// behaviour, all off by default, so Mark can turn them on during testing.
// Keys live here only; the settings screen and feature code both read them.
nonisolated enum Labs {
    /// Roadmap A4.2: codec/resolution/fps/bitrate/dropped frames in the info overlay.
    static let streamInfo = "pigtv.labs.streamInfo"

    struct Toggle: Identifiable {
        let key: String
        let title: String
        let detail: String
        var id: String { key }
    }

    /// Settings order and wording.
    static let toggles: [Toggle] = [
        Toggle(key: streamInfo, title: "Stream info overlay",
               detail: "Shows codec, resolution, frame rate, bitrate and dropped frames in the player's info overlay.")
    ]

    static func isOn(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}
