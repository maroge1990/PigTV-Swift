import SwiftUI

// The card badge and the tvOS focus section, shared by the Sport cards and Recordings (they were Home's until Home was
// retired, #216). Cards take focus through the shared treatment (PigFocus.swift).

/// A small capsule label on a card ("LIVE", "in 12 min", "REC").
struct CardBadge: View {
    let text: String
    var systemImage: String? = nil
    var colour: Color = .pigAccent
    #if os(tvOS)
    private static let font: Font = .system(size: PigType.caption, weight: .bold)
    #else
    private static let font: Font = .caption.bold()
    #endif
    var body: some View {
        HStack(spacing: PigSpacing.xs) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Self.font)
        .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
        .background(colour, in: Capsule())
        .foregroundStyle(colour == .pigAccent ? Color.pigOnAccent : Color.pigOnStatus)
    }
}

extension View {
    /// A tvOS focus section (Up/Down enter it as a whole); nothing on iOS.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}

/// "in 12 min" (rounded up, so a programme 30 s away reads "in 1 min").
nonisolated enum Countdown {
    static func text(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "starting now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }
}
