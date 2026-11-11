import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    /// The tab the app opens on (nil: `LibraryView.openingTab`; the offline fixtures may pick their own).
    var initialTab: String? = nil
    @State private var tab: String?
    /// The viewer (or a link) chose a tab: the opening decision never overrides it.
    @State private var chosen = false

    /// D-39 (Apple 89): the app opens on Sport when the server has it. #216 (D-44, Apple 102): Home ("TV") is retired,
    /// so without sport it opens on the TV Guide.
    nonisolated static func openingTab(sportEnabled: Bool) -> String { sportEnabled ? "sport" : "guide" }
    /// D-44: the tab bar's order by tag, as `body` builds it: Sport (when the server has it), TV Guide, Recordings, Settings.
    nonisolated static func tabOrder(sportEnabled: Bool) -> [String] {
        (sportEnabled ? ["sport"] : []) + ["guide", "recordings", "settings"]
    }
    /// What `pigtv://home` asks for (Top Shelf snapshots written before #216 still carry it): the Sport tab.
    nonisolated static let homeLinkTab = "sport"
    /// The tab a request lands on: itself when the bar has it, else the opening tab (`pigtv://home`'s Sport without
    /// sport, or the retired "home").
    nonisolated static func tab(for requested: String, sportEnabled: Bool) -> String {
        tabOrder(sportEnabled: sportEnabled).contains(requested) ? requested : openingTab(sportEnabled: sportEnabled)
    }

    /// #214: a selection of the Sport tab (again while on it, or coming back from another tab) shows its front page.
    @MainActor static func tabSelected(_ tab: String, navigation: SportNavigation?) {
        if tab == "sport" { navigation?.showFront() }
    }

    /// The tab shown: the chosen one, else the opening tab (Settings until signed in).
    private var selection: String {
        tab ?? model.browse.map { initialTab ?? Self.openingTab(sportEnabled: $0.sportEnabled) } ?? "settings"
    }

    /// Moves when the session or whether it has sport changes.
    private var openingKey: String {
        model.browse.map { "\(ObjectIdentifier($0))|\($0.sportEnabled)" } ?? ""
    }

    var body: some View {
        // Accent tint on the TabView so the selected tab reads pink — the
        // white selection was hard to distinguish from unselected tabs.
        // Until the opening tab is written (below), the selection is what it will be, so a selection the tab bar writes
        // back at launch is the opening tab, not the first in the bar.
        TabView(selection: Binding(get: { selection },
                                   set: { new in
                                       if new != selection { chosen = true }
                                       PigTVSignpost.tabSelected(new)
                                       Self.tabSelected(new, navigation: model.browse?.sportNavigation)
                                       tab = new
                                   })) {
            if let browse = model.browse {
                // C-I (build 30): only when the server has sport events. D-39 (Apple 89): first, as the app opens on it.
                // Five tabs fit the iPhone's bar, so it is a tab there too.
                if browse.sportEnabled {
                    SportsLandingView(app: model, browse: browse)
                        .id(ObjectIdentifier(browse))
                        .tabItem { Label("Sport", systemImage: "sportscourt") }
                        .tag("sport")
                    .onAppear { PigTVSignpost.tabContentAppeared("sport") }
                }
                // #216 (D-44): no Home ("TV") tab; Favourites on now is the TV Guide's Favourites filter.
                GuideView(app: model, model: browse)
                    .tabItem { Label("TV Guide", systemImage: "calendar") }
                    .tag("guide")
                .onAppear { PigTVSignpost.tabContentAppeared("guide") }
                RecordingsView(model: browse, presenter: model.presenter, openGuide: { model.requestedTab = "guide" })
                    .tabItem { Label("Recordings", systemImage: "record.circle") }
                    .tag("recordings")
                .onAppear { PigTVSignpost.tabContentAppeared("recordings") }
            }
            LibrarySettings(model: model, isTab: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
                .onAppear { PigTVSignpost.tabContentAppeared("settings") }
        }
        .tint(Color("AccentColor"))
        // #49 groundwork: the app-level presentation layer's page, above every tab.
        .appPresentations(model.presenter, app: model, browse: model.browse)
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if TabSwitchProbe.enabled { TabSwitchProbeLabel() }
        }
        // Deciding the opening tab (nil → a tab) is not a switch.
        .onChange(of: tab) { old, _ in if old != nil && TabSwitchProbe.enabled { TabSwitchProbe.shared.tabChanged() } }
        #endif
        // D-39: the opening tab is written when the session's browse model and its sport availability are known, and again
        // only if that availability changes before the viewer has chosen a tab: a chosen tab is never overridden.
        .onChange(of: openingKey, initial: true) {
            guard !chosen, let browse = model.browse else { return }
            tab = initialTab ?? Self.openingTab(sportEnabled: browse.sportEnabled)
        }
        .onChange(of: model.requestedTab, initial: true) { _, requested in
            guard let requested else { return }
            model.requestedTab = nil
            // Before sign-in there is only Settings; the opening tab follows sign-in anyway.
            guard let browse = model.browse else { return }
            chosen = true
            tab = Self.tab(for: requested, sportEnabled: browse.sportEnabled)
            Self.tabSelected(tab ?? "", navigation: browse.sportNavigation)
        }
    }
}
