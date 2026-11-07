import SwiftUI

// The card focus style, the card badge and the tvOS focus section, shared by the Sport cards and Recordings (they
// were Home's until Home was retired, #216).

/// A card's focus: the app's pink outline and translucent pink fill, plus the tvOS lift (scale and shadow).
struct PigCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous)
        configuration.label
            .foregroundStyle(.primary)
            .background(focused ? Color.pigAccent.opacity(0.22) : Color.guideCell(scheme), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .scaleEffect(focused && !reduceMotion ? 1.07 : (configuration.isPressed ? 0.98 : 1))
            .shadow(color: Color.pigShadow.opacity(focused ? (scheme == .dark ? 0.6 : 0.25) : 0), radius: focused ? 26 : 0, y: focused ? 16 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

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
