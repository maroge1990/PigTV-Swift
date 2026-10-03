import SwiftUI

extension View {
    /// Runs `work` only while this view is on screen, and cancels it when the
    /// view goes away (a tab that is not selected, a cover over it). A
    /// TabView keeps the pages it has shown, so a plain `.task` loop (a
    /// clock, a periodic refresh) could keep running behind another tab
    /// (audit R05: hidden screens do no work). `work` starts again when the
    /// view reappears.
    func whileVisible(_ work: @escaping @MainActor () async -> Void) -> some View {
        modifier(WhileVisible(work: work))
    }
}

private struct WhileVisible: ViewModifier {
    let work: @MainActor () async -> Void
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: visible) { if visible { await work() } }
    }
}
