import SwiftUI
#if os(iOS)
import UIKit
#endif

// Apple's design checklist (maroge1990/PigTV#280): on iPhone and iPad, recording, following and deleting are felt as well
// as seen: a success for something made (a recording scheduled, a rule added, a sport or name followed), a light tap for
// something removed (with its Undo). None on Apple TV. The system's own setting (Settings › Sounds & Haptics › System
// Haptics) is respected by the feedback generators themselves. One helper, called where the action succeeds.

nonisolated enum PigHaptic: Equatable, Sendable {
    case record, follow, delete

    enum Feedback: Equatable, Sendable { case success, lightImpact }

    /// What the device plays for `event` (nil: nothing, as on the television). Pure.
    static func feedback(for event: PigHaptic, television: Bool) -> Feedback? {
        guard !television else { return nil }
        switch event {
        case .record, .follow: return .success
        case .delete: return .lightImpact
        }
    }

    #if DEBUG
    /// Tests: each event played, in order.
    @MainActor static var observer: ((PigHaptic) -> Void)?
    #endif

    @MainActor static func play(_ event: PigHaptic) {
        #if DEBUG
        observer?(event)
        #endif
        #if os(iOS)
        switch feedback(for: event, television: false) {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .lightImpact: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case nil: break
        }
        #endif
    }
}
