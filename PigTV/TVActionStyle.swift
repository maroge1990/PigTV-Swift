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
