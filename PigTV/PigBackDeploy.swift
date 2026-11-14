import SwiftUI

// #262: iPhone and iPad run from iOS 17 (the Apple TV stays on tvOS 26.5). The few newer APIs the app draws with go
// through these modifiers, so a call site reads the same on every OS: on iOS 26 (and tvOS) each is exactly the API it
// replaces; on older iOS it falls back to the nearest older look or behaviour.

extension View {
    /// A Liquid Glass button (`.glass`); before iOS 26 a bordered one. The caller's tint applies to both.
    @ViewBuilder
    func pigGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The prominent Liquid Glass button (`.glassProminent`); before iOS 26 a bordered prominent one.
    @ViewBuilder
    func pigGlassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A Liquid Glass background in `shape`; before iOS 26 the regular material in the same shape.
    @ViewBuilder
    func pigGlassBackground(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// On a vertical ScrollView: calls `action` with `isPast(scrolled)` as it changes, where `scrolled` is how far the
    /// content has moved up from where it rests. iOS 18+ (and tvOS) read the scroll geometry; iOS 17 reads the probe
    /// that the scroll's content carries (`pigScrollProbe()`), which must be at the content's resting top.
    @ViewBuilder
    func onScrollPast(_ isPast: @escaping (CGFloat) -> Bool, action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: Bool.self) { isPast($0.contentOffset.y + $0.contentInsets.top) } action: { _, past in action(past) }
        } else {
            coordinateSpace(name: PigScrollProbe.space)
                .backgroundPreferenceValue(PigScrollProbe.Key.self) { top in
                    Color.clear.onChange(of: top.map { isPast(PigScrollProbe.scrolled(probeTop: $0)) } ?? false, initial: true) { _, past in
                        action(past)
                    }
                }
        }
    }

    /// iOS 17's half of `onScrollPast`: put on the scroll's content, at its resting top. Nothing on iOS 18+.
    @ViewBuilder
    func pigScrollProbe() -> some View {
        if #available(iOS 18.0, *) {
            self
        } else {
            background(alignment: .top) {
                GeometryReader { proxy in
                    Color.clear.preference(key: PigScrollProbe.Key.self, value: proxy.frame(in: .named(PigScrollProbe.space)).minY)
                }
            }
        }
    }
}

/// iOS 17's scroll offset: a probe at the content's top, measured in the ScrollView's own frame.
enum PigScrollProbe {
    static let space = "pigScrollProbe"

    /// How far the content has scrolled up: the probe rests at the top of the scroll's frame (0) and moves up as it scrolls.
    nonisolated static func scrolled(probeTop: CGFloat) -> CGFloat { -probeTop }

    struct Key: PreferenceKey {
        static let defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
    }
}
