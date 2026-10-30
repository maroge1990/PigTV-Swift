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

private struct WhileVisible: ViewModifier {
    let condition: Bool
    let work: @MainActor () async -> Void
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: visible && condition) { if visible && condition { await work() } }
    }
}
