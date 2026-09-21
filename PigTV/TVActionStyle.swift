import SwiftUI

// Keep tvOS's native focus behaviour while giving unfocused pink buttons
// an explicit contrasting label colour.
struct TVActionStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) {
            configuration.label.foregroundStyle(.black)
        }
        .buttonStyle(.bordered)
    }
}

// Shared by guide cells and recordings: every non-focused action keeps the
// readable page-surface/text pairing, while the focused action gains the same
// pink outline instead of inheriting a platform-dependent bordered-button tint.
struct PigSurfaceButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(focused ? Color.accentColor.opacity(0.22) : Color.guideCell(scheme),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 3)
            }
            .scaleEffect(1)
    }
}

extension View {
    @ViewBuilder
    func pigPrimaryButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(TVActionStyle())
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }
}

struct PigPageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color.black : Color.white).ignoresSafeArea()
    }
}
