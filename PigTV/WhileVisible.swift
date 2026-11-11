import SwiftUI

extension View {
    /// Runs `work` only while this view is on screen, and cancels it when the
    /// view goes away (a tab that is not selected, a cover over it). A
    /// TabView keeps the pages it has shown, so a plain `.task` loop (a
    /// clock, a periodic refresh) could keep running behind another tab
    /// (audit R05: hidden screens do no work). `work` starts again when the
    /// view reappears.
    /// `when`: run only while this also holds (e.g. the scene is active and no sheet covers the page); `work`
    /// starts when both hold, whichever came second, and is cancelled when either stops.
    func whileVisible(when condition: Bool = true, _ work: @escaping @MainActor () async -> Void) -> some View {
        modifier(WhileVisible(condition: condition, work: work))
    }
}

private struct PigCoveredByPlayerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Audit F4: true on the pages under the full-screen player. SwiftUI does not promise that a tab under a
    /// full-screen cover gets `onDisappear`, so `whileVisible` rests on this instead. ContentView sets it from
    /// `playerPresented`; everything inside the player gets false.
    var pigCoveredByPlayer: Bool {
        get { self[PigCoveredByPlayerKey.self] }
        set { self[PigCoveredByPlayerKey.self] = newValue }
    }
}

/// When `whileVisible`'s work runs: on screen, its own condition holds, and no player covers it.
nonisolated enum WhileVisibleRule {
    static func runs(visible: Bool, condition: Bool, covered: Bool) -> Bool { visible && condition && !covered }
}

private struct WhileVisible: ViewModifier {
    let condition: Bool
    let work: @MainActor () async -> Void
    @State private var visible = false
    @Environment(\.pigCoveredByPlayer) private var covered

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            // When the player closes the id changes and the work starts again: every visible page refreshes at once.
            .task(id: WhileVisibleRule.runs(visible: visible, condition: condition, covered: covered)) {
                if WhileVisibleRule.runs(visible: visible, condition: condition, covered: covered) { await work() }
            }
    }
}
