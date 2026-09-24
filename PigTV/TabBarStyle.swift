#if os(tvOS)
import UIKit

// Build 27 (Mark's test block): once focus moved from the top tab bar into
// the page, the selected tab was pink text on the system's light grey pill,
// hard to read in light and dark. Now it follows the app's focus language:
// - focus in the tab bar: the focused tab is a solid pink pill, white text;
// - focus in the page: the selected tab keeps pink text over a faint pink
//   pill; the other tabs use the system colours.
// tvOS draws both pills from one `selectionIndicatorTintColor` (and moving
// focus along the bar selects the tab, so the two states never coexist), so
// the bar's appearance is swapped when focus enters or leaves it.
enum TabBarStyle {
    private static var observer: NSObjectProtocol?
    private static weak var tabBar: UITabBar?
    private static var focusInBar: Bool?

    static func appearance(focusInBar: Bool) -> UITabBarAppearance {
        let pink = UIColor(named: "AccentColor") ?? .systemPink
        let item = UITabBarItemAppearance(style: .stacked)
        item.selected.titleTextAttributes = [.foregroundColor: pink]
        item.selected.iconColor = pink
        item.focused.titleTextAttributes = [.foregroundColor: UIColor.white]
        item.focused.iconColor = .white
        let appearance = UITabBarAppearance()
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        appearance.selectionIndicatorTintColor = focusInBar ? pink : UIColor { traits in
            pink.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.22 : 0.12)
        }
        // Light mode: a near-white bar instead of the system's mid grey, so
        // pink (and black) text on it keeps its contrast.
        appearance.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .clear : UIColor.white.withAlphaComponent(0.85)
        }
        return appearance
    }

    static func apply() {
        UITabBar.appearance().standardAppearance = appearance(focusInBar: false)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification,
                                                          object: nil, queue: .main) { @Sendable note in
            // queue: .main, and focus updates are main-thread only, so the
            // notification never leaves the main thread.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                focusMoved(to: context?.nextFocusedView)
            }
        }
    }

    private static func focusMoved(to view: UIView?) {
        var bar: UITabBar?
        var current = view
        while let candidate = current {
            if let found = candidate as? UITabBar { bar = found; break }
            current = candidate.superview
        }
        if let bar { tabBar = bar }
        let inBar = bar != nil
        guard inBar != focusInBar, let target = tabBar else { return }
        focusInBar = inBar
        target.standardAppearance = appearance(focusInBar: inBar)
    }
}
#endif
