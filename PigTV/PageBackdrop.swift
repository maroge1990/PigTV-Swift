import SwiftUI
import UIKit

// Build 32 (Mark, on device: "a white flash when moving between the top
// tabs"). SwiftUI's TabView is a UITabBarController underneath, and tvOS
// cross-fades the outgoing and incoming tab. During the fade both pages are
// partly transparent, so whatever lies behind them shows through: nothing
// the app painted, so tvOS's own backdrop (a light, blurred grey in light
// appearance; dark grey in dark), the window's default background, and any
// UIKit container between them. Recorded in the simulator (60 fps, frame by
// frame; see blueprint.md build 32) as a grey veil in both appearances.
//
// Every UIKit layer that can be seen during a switch is painted the page
// colour, which is dynamic (plum in dark, warm paper in light) so it follows the
// window's appearance override as well as the system's:
// - the window (PigTVApp's scene: `WindowBackdrop`);
// - every view controller from a tab's page up to the window (tab root
//   hosting controller, navigation controller, tab bar controller, root
//   hosting controller) and the tab bar controller's other loaded children,
//   when a page enters the window (`PageBackdropPainter`, placed behind each
//   tab's page by `pigPageBackdrop()`), before it is first drawn;
// - the guide grid's UIKit controller and collection view
//   (GuideGridViewController.viewDidLoad);
// - the tab bar's own background (TabBarStyle).

extension UIColor {
    /// PigPageBackground's colour: plum in dark appearance, warm paper in light.
    static let pigPage = UIColor(named: "PigCanvas")!
}

@MainActor
enum PageBackdrop {
    /// Paints the window and every container view controller that holds
    /// `view`, plus the tab bar controller's other loaded children.
    static func paint(from view: UIView) {
        guard let window = view.window else { return }
        paint(window)
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { paintContainer(controller) }
            responder = current.next
        }
        if let root = window.rootViewController { paintContainers(below: root) }
    }

    static func paint(_ window: UIWindow) {
        if window.backgroundColor != .pigPage { window.backgroundColor = .pigPage }
    }

    /// The root, tab bar and navigation controllers below it, and the tab bar
    /// controllers' loaded children. Presented controllers (the player,
    /// detail covers) are not children, so they are never touched.
    private static func paintContainers(below controller: UIViewController, isRoot: Bool = true) {
        if isRoot || controller is UITabBarController || controller is UINavigationController {
            paintContainer(controller)
        }
        if let tabs = controller as? UITabBarController {
            for child in tabs.viewControllers ?? [] { paintContainer(child) }
        }
        for child in controller.children { paintContainers(below: child, isRoot: false) }
    }

    private static func paintContainer(_ controller: UIViewController) {
        guard let view = controller.viewIfLoaded, view.backgroundColor != .pigPage else { return }
        view.backgroundColor = .pigPage
    }
}

/// A zero-size view behind a tab's page that paints its UIKit containers as
/// soon as it enters a window (before the page's first frame).
struct PageBackdropPainter: UIViewRepresentable {
    func makeUIView(context: Context) -> PainterView { PainterView() }
    func updateUIView(_ view: PainterView, context: Context) {}

    final class PainterView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            PageBackdrop.paint(from: self)
        }
    }
}

/// The window behind everything: painted once when the scene's first view
/// enters it (PigTVApp puts this behind every root screen).
struct WindowBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowView { WindowView() }
    func updateUIView(_ view: WindowView, context: Context) {}

    final class WindowView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            PageBackdrop.paint(window)
            #if DEBUG
            // Fixtures (PIGTV_UI_TEST_APPEARANCE) set the window's style as
            // ContentView.syncWindowStyle does for the app's Appearance setting.
            switch ProcessInfo.processInfo.environment["PIGTV_UI_TEST_APPEARANCE"] {
            case "dark": window.overrideUserInterfaceStyle = .dark
            case "light": window.overrideUserInterfaceStyle = .light
            default: break
            }
            #endif
        }
    }
}

extension View {
    /// The page background (PigPageBackground) plus the UIKit layers behind
    /// it painted the same colour, so a tab switch never shows another one.
    func pigPageBackdrop() -> some View {
        background {
            ZStack {
                PageBackdropPainter().frame(width: 0, height: 0).accessibilityHidden(true)
                PigPageBackground()
            }
        }
    }
}
