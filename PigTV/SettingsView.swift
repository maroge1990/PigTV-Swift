import SwiftUI

// D-44 (batch 6, R5-Settings-*): Settings is a menu beside its page. On the Apple TV and the iPad (regular width) the
// system split view holds the menu in its sidebar and the chosen page beside it; on the iPhone (compact width) the menu is
// a list whose rows push their pages. Diagnostics (the Top Shelf) is on the Apple TV only.

/// One page of Settings, in the menu's order.
nonisolated enum SettingsPage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case sport, account, appearance, labs, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sport: "Sport"
        case .account: "Account"
        case .appearance: "Appearance"
        case .labs: "Labs"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .sport: "sportscourt"
        case .account: "person.crop.circle"
        case .appearance: "circle.lefthalf.filled"
        case .labs: "flask"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
}

/// What the menu lists and the one-line summary under each item (pure, `SettingsMenuTests`).
nonisolated enum SettingsMenu {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif

    /// Sport only where the server keeps the account's sports (C-U `sportFollows`); Diagnostics only on the Apple TV.
    static func pages(sportFollows: Bool, isTV: Bool = isTV) -> [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .sport: sportFollows
            case .diagnostics: isTV
            default: true
            }
        }
    }

    /// The page shown beside the menu when Settings opens (split view); the iPhone opens on the menu itself (nil).
    static func opening(_ pages: [SettingsPage], compact: Bool) -> SettingsPage? { compact ? nil : pages.first }

    /// "6 sports · 9 follows"; before the account's sports have loaded, what the page holds.
    static func sportSummary(_ follows: SportFollows?) -> String {
        guard let follows else { return "Hide scores and your sports" }
        let sports = follows.sports.count, names = follows.sports.reduce(0) { $0 + $1.teams.count }
        return "\(count(sports, "sport")) · \(count(names, "follow"))"
    }

    /// "mark · pigtv.local": the account and the server's host.
    static func accountSummary(user: String?, server: String) -> String {
        let host = URL(string: server)?.host ?? server
        return [user, host].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    static func appearanceSummary(_ value: String) -> String { value.capitalized }

    /// One switch: "Stream info overlay: Off"; several: "2 on" (or "All off").
    static func labsSummary(_ toggles: [Labs.Toggle], isOn: (String) -> Bool) -> String {
        if toggles.count == 1, let only = toggles.first { return "\(only.title): \(isOn(only.key) ? "On" : "Off")" }
        let on = toggles.filter { isOn($0.key) }.count
        return on == 0 ? "All off" : "\(on) on"
    }

    /// "App 128 · Server 0444" (the server's build, else its version).
    static func aboutSummary(appBuild: String, server: ServerInfo?) -> String {
        let app = "App \(appBuild)"
        guard let server else { return app }
        return "\(app) · Server \(server.build ?? server.version)"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

struct LibrarySettings: View {
    @ObservedObject var model: AppModel
    var isTab: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("pigtv.appearance") private var appearance = "system"
    @AppStorage(Labs.streamInfo) private var streamInfo = false
    @State private var page: SettingsPage?
    @State private var opened = false
    /// The iPhone's pushed page (a fixture may push one).
    @State private var phonePath: [SettingsPage] = []
    #if os(tvOS)
    @FocusState private var focusedPage: SettingsPage?
    #endif

    private var pages: [SettingsPage] {
        SettingsMenu.pages(sportFollows: model.browse?.sportFollowsEnabled == true)
    }

    private var compact: Bool {
        #if os(tvOS)
        false
        #else
        sizeClass == .compact
        #endif
    }

    var body: some View {
        content
            .onAppear(perform: open)
            .onChange(of: pages) { _, now in if let page, !now.contains(page) { self.page = SettingsMenu.opening(now, compact: compact) } }
    }

    /// The opening page, once (a fixture may name one: PIGTV_UI_TEST_SETTINGS_PAGE).
    private func open() {
        guard !opened else { return }
        opened = true
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SETTINGS_PAGE"], let named = SettingsPage(rawValue: name),
           pages.contains(named) {
            page = named
            if compact { phonePath = [named] }
            return
        }
        #endif
        page = SettingsMenu.opening(pages, compact: compact)
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        if compact { phoneMenu } else { splitView }
        #else
        splitView
        #endif
    }

    #if os(iOS)
    private var phoneMenu: some View {
        Group {
            // iPhone: the menu, each row pushing its page.
            NavigationStack(path: $phonePath) {
                VStack(alignment: .leading, spacing: 0) {
                    PigPageHeader(title: "Settings")
                    List {
                        Section {
                            ForEach(pages) { item in
                                NavigationLink(value: item) { SettingsMenuLabel(page: item, summary: summary(item), selected: false) }
                                    .listRowBackground(Color.pigRaised)
                                    .accessibilityIdentifier("settings.menu.\(item.rawValue)")
                            }
                        } footer: {
                            Text("App \(Self.appVersion) (\(Self.appBuild))" + (model.serverInfo.map { " · Server \($0.build ?? $0.version)" } ?? ""))
                                .font(.footnote.monospacedDigit()).fontDesign(.rounded)
                                .frame(maxWidth: .infinity).padding(.top, 12)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SettingsPage.self) { item in
                    pageView(item).navigationTitle(item.title).navigationBarTitleDisplayMode(.large)
                        .background(PigPageBackground())
                }
                .pigPageBackdrop()
            }
        }
    }
    #endif

    private var splitView: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                // At the page's corner like every tab's header (it insets itself).
                PigPageHeader(title: "Settings")
                #if os(tvOS)
                // tvOS 27's NavigationSplitView inside the tab bar drew its sidebar across the whole screen and never the
                // page beside it (checked on the simulator), so the TV puts the two columns side by side itself, each a
                // focus section: Right from the menu enters the page, Left from the page returns to the menu.
                HStack(alignment: .top, spacing: SettingsMetrics.columnSpacing) {
                    menu.frame(width: SettingsMetrics.menuWidth)
                    Group {
                        if let page { pageView(page).id(page) } else { Color.clear }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                }
                .padding(.top, 20)
                #else
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    menu
                        .background(PigPageBackground())
                        .navigationSplitViewColumnWidth(SettingsMetrics.menuWidth)
                        #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                        #endif
                } detail: {
                    NavigationStack {
                        Group {
                            if let page { pageView(page).id(page) } else { Color.clear }
                        }
                        #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                        #endif
                        .background(PigPageBackground())
                    }
                }
                .navigationSplitViewStyle(.balanced)
                #endif
            }
            // The app's page, not the system's blurred backdrop (build 28).
            .pigPageBackdrop()
        }
    }

    /// The split view's menu: one row per page; the page shown is selected (14 % pink and a short bar, never a tick).
    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.menuSpacing) {
                ForEach(pages) { item in
                    Button { page = item } label: {
                        SettingsMenuLabel(page: item, summary: summary(item), selected: page == item)
                    }
                    .buttonStyle(SettingsMenuRowStyle(selected: page == item))
                    #if os(tvOS)
                    // The tvOS sidebar: the page follows the focus, as the system Settings does.
                    .focused($focusedPage, equals: item)
                    #endif
                    .accessibilityIdentifier("settings.menu.\(item.rawValue)")
                    .accessibilityValue(page == item ? "Selected" : "")
                }
            }
            .padding(SettingsMetrics.menuPadding)
        }
        #if os(tvOS)
        .focusSection()
        // Entering the menu lands on the page shown.
        .defaultFocus($focusedPage, page)
        .onChange(of: focusedPage) { _, focused in if let focused { page = focused } }
        #endif
    }

    private func summary(_ item: SettingsPage) -> String {
        switch item {
        case .sport: SettingsMenu.sportSummary(model.browse?.sportFollows.follows)
        case .account: SettingsMenu.accountSummary(user: model.user?.username, server: model.serverText)
        case .appearance: SettingsMenu.appearanceSummary(appearance)
        case .labs: SettingsMenu.labsSummary(Labs.toggles) { key in key == Labs.streamInfo ? streamInfo : Labs.isOn(key) }
        case .diagnostics: "Top Shelf"
        // The iPhone shows the versions under the menu, so its About row says what is there.
        case .about: compact ? "App and server versions" : SettingsMenu.aboutSummary(appBuild: Self.appBuild, server: model.serverInfo)
        }
    }

    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ item: SettingsPage) -> some View {
        switch item {
        case .sport:
            if let browse = model.browse {
                SettingsPageBody(title: item.title, showsTitle: !compact) {
                    SportSettingsSection(model: browse.sportFollows, me: model.user?.username,
                                         frontFollows: browse.sportFrontEnabled ? browse.sportFront.front?.follows ?? [] : [])
                }
            }
        case .account:
            SettingsAccountPage(model: model, showsTitle: !compact) { if !isTab { dismiss() } }
        case .appearance:
            SettingsPageBody(title: item.title, showsTitle: !compact) {
                Section { appearanceRows }
            }
        case .labs:
            SettingsPageBody(title: item.title, showsTitle: !compact) {
                Section { ForEach(Labs.toggles) { LabsToggleRow(toggle: $0) } }
            }
        case .diagnostics:
            SettingsPageBody(title: item.title, showsTitle: !compact) {
                #if os(tvOS)
                // Build 31: whether the Top Shelf snapshot was written and whether tvOS asked the extension for it.
                Section { TopShelfDiagnosticsRows() }
                #endif
            }
        case .about:
            SettingsPageBody(title: item.title, showsTitle: !compact) {
                Section {
                    SettingsRow("App", value: "\(Self.appVersion) (\(Self.appBuild))")
                    SettingsRow("Server", value: model.serverInfo?.identity ?? "Unknown")
                }
                if !isTab {
                    Section { Button("Done") { dismiss() } }
                }
            }
        }
    }

    private var appearanceRows: some View {
        ForEach(["system", "light", "dark"], id: \.self) { value in
            Button { appearance = value } label: {
                HStack {
                    Text(value.capitalized)
                        .foregroundStyle(appearance == value ? Color.pigAccentText : Color("PigText"))
                    Spacer()
                }
                #if os(tvOS)
                .font(.system(size: 24))
                .padding(.horizontal, 24).padding(.vertical, 16)
                .background(appearance == value ? Color.pigAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: PigRadius.compact))
                #endif
                .overlay(alignment: .leading) {
                    if appearance == value {
                        Capsule().fill(Color.pigAccent).frame(width: 3, height: 20)
                            #if os(tvOS)
                            .offset(x: 8)
                            #else
                            .offset(x: -6)
                            #endif
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            #if os(iOS)
            .buttonStyle(.borderless)
            .listRowBackground(appearance == value ? Color.pigAccent.opacity(0.14) : Color.pigRaised)
            #else
            .buttonStyle(PigSurfaceButtonStyle())
            #endif
            .accessibilityIdentifier("appearance.\(value)")
            .accessibilityValue(appearance == value ? "Selected" : "Not selected")
        }
    }
}

nonisolated enum SettingsMetrics {
    #if os(tvOS)
    static let menuWidth: CGFloat = 460
    static let columnSpacing: CGFloat = 40
    static let menuSpacing: CGFloat = 10
    static let menuPadding = EdgeInsets(top: 8, leading: 12, bottom: 24, trailing: 12)
    static let rowPadding = EdgeInsets(top: 16, leading: 22, bottom: 16, trailing: 22)
    static let icon: CGFloat = 30
    static let barWidth: CGFloat = 4
    static let pageWidth: CGFloat = 1100
    static let pagePadding: CGFloat = 8
    static let confirmSpacing: CGFloat = 18
    static let confirmPadding = EdgeInsets(top: 26, leading: 28, bottom: 26, trailing: 28)
    #else
    static let menuWidth: CGFloat = 280
    static let menuSpacing: CGFloat = 8
    static let menuPadding = EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 4)
    static let rowPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    static let icon: CGFloat = 20
    static let barWidth: CGFloat = 3
    static let pageWidth: CGFloat = 680
    static let pagePadding: CGFloat = 20
    static let confirmSpacing: CGFloat = 12
    static let confirmPadding = EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    #endif
}

/// A menu item: its icon, its name and the one-line summary of its page.
private struct SettingsMenuLabel: View {
    let page: SettingsPage
    let summary: String
    let selected: Bool

    var body: some View {
        HStack(spacing: SettingsMetrics.icon * 0.6) {
            Image(systemName: page.systemImage)
                .font(.system(size: SettingsMetrics.icon * 0.8, weight: .semibold))
                .frame(width: SettingsMetrics.icon)
                .foregroundStyle(selected ? Color.pigAccentText : Color("PigSecondary"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(SettingsType.menuTitle)
                    .foregroundStyle(selected ? Color.pigAccentText : Color("PigText"))
                Text(summary).font(SettingsType.menuSummary).monospacedDigit()
                    .foregroundStyle(Color("PigSecondary")).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title), \(summary)")
    }
}

/// A row of the split view's menu: selected, 14 % pink with a short bar at its leading edge; focused (tvOS) or pressed,
/// the shared focus look (a pink ring over 22 % pink).
private struct SettingsMenuRowStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous)
        let lit = focused || configuration.isPressed
        configuration.label
            .padding(SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lit ? Color.pigAccent.opacity(0.22) : selected ? Color.pigAccent.opacity(0.14) : Color.pigRaised, in: shape)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.pigAccent).frame(width: SettingsMetrics.barWidth, height: 26)
                        .padding(.leading, 6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .contentShape(shape)
            #if os(tvOS)
            .scaleEffect(focused ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            #endif
    }
}

nonisolated enum SettingsType {
    #if os(tvOS)
    static let menuTitle: Font = .system(size: 23, weight: .bold)
    static let menuSummary: Font = .system(size: 17).monospacedDigit()
    static let pageTitle: Font = .system(size: 40, weight: .heavy)
    static let confirmTitle: Font = .system(size: 26, weight: .bold)
    static let confirmBody: Font = .system(size: 21)
    static let footnote: Font = .system(size: 18)
    #else
    static let menuTitle: Font = .headline
    static let menuSummary: Font = .footnote
    static let pageTitle: Font = .title2.bold()
    static let confirmTitle: Font = .headline
    static let confirmBody: Font = .subheadline
    static let footnote: Font = .footnote
    #endif
}

/// A page beside the menu: its title (the iPhone's pushed page has the navigation bar's instead), then its sections: on
/// the TV surface rows in a scroll view, on iOS a Form.
struct SettingsPageBody<Content: View>: View {
    let title: String
    var showsTitle = true
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if showsTitle { Text(title).font(SettingsType.pageTitle).accessibilityAddTraits(.isHeader) }
                content
            }
            .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pagePadding).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("settings.page")
        #else
        // #227 (Mark's iPad test, 4 Nov 2026): beside the menu, the page's first card starts on the menu's first row's
        // line. Before Apple 148 the page drew its own title there, so its content began about 60 pt lower than the menu;
        // the selected menu row already names the page, so the title is only VoiceOver's header now. The iPhone's pages
        // keep the navigation bar's title.
        Form { content }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 5, for: .scrollContent) // the menu rows' text and the first row's on one line
            .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(showsTitle ? title : "")
            .accessibilityIdentifier("settings.page")
        #endif
    }
}

/// Settings › Account: who is signed in, to which server, and Sign out. D-44: Sign out is the one action that confirms,
/// and it confirms inside its own row (never a dialog): the row becomes "Sign out of PigTV?" with Stay signed in (the
/// rose primary, focused) and Sign out. "Use a different server" needs the same sign-out, so it opens the same row.
struct SettingsAccountPage: View {
    @ObservedObject var model: AppModel
    var showsTitle = true
    /// Called once signing out has begun (a Settings sheet closes itself).
    var signedOut: () -> Void = {}
    /// The row's confirmation, and why it was opened.
    @State private var confirm: SignOutReason?
    #if os(tvOS)
    @FocusState private var focus: AccountFocus?
    private enum AccountFocus: Hashable { case signOut, stay }
    #endif

    enum SignOutReason { case signOut, changeServer }

    var body: some View {
        SettingsPageBody(title: "Account", showsTitle: showsTitle) {
            Section {
                SettingsRow("Signed in as", value: model.user?.username ?? "")
                SettingsRow("Server", value: model.serverText, monospaced: true)
                Button { open(.changeServer) } label: {
                    HStack {
                        Text("Use a different server")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    #if os(tvOS)
                    .font(.system(size: 24))
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    #endif
                    .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                #else
                .foregroundStyle(Color("PigText"))
                .listRowBackground(Color.pigRaised)
                #endif
                .disabled(model.playbackBusy || confirm != nil)
                .accessibilityIdentifier("settings.account.changeServer")
            }
            Section {
                if let confirm { confirmation(confirm) } else { signOutRow }
            }
            Section {
                Text("App \(LibrarySettings.appVersion) (\(LibrarySettings.appBuild))"
                     + (model.serverInfo.map { " · Server \($0.build ?? $0.version)" } ?? ""))
                    .font(SettingsType.footnote).fontDesign(.rounded).monospacedDigit()
                    .foregroundStyle(Color("PigSecondary"))
                    #if os(iOS)
                    .listRowBackground(Color.clear)
                    #endif
            }
        }
        #if os(tvOS)
        .onChange(of: confirm != nil) { _, open in focus = open ? .stay : .signOut }
        #endif
        #if DEBUG
        // The evidence screenshots: PIGTV_UI_TEST_SIGNOUT_CONFIRM=1 opens on the row's confirmation.
        .onAppear { if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SIGNOUT_CONFIRM"] == "1" { confirm = .signOut } }
        #endif
    }

    private func open(_ reason: SignOutReason) {
        withAnimation(.easeOut(duration: 0.15)) { confirm = reason }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { confirm = nil }
    }

    private var signOutRow: some View {
        Button(role: .destructive) { open(.signOut) } label: {
            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                .foregroundStyle(Color.pigDanger)
                #if os(tvOS)
                .font(.system(size: 24))
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
        }
        #if os(tvOS)
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .focused($focus, equals: .signOut)
        #else
        .listRowBackground(Color.pigRaised)
        #endif
        .disabled(model.playbackBusy)
        .accessibilityIdentifier("settings.account.signOut")
    }

    /// The row asking: Stay signed in first (the safe choice takes the focus), then Sign out.
    private func confirmation(_ reason: SignOutReason) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.confirmSpacing) {
            Text("Sign out of PigTV?").font(SettingsType.confirmTitle).foregroundStyle(Color.pigDanger)
                .accessibilityAddTraits(.isHeader)
            Text(reason == .changeServer
                 ? "To use a different server, sign out first. You will need to pair or sign in again on this device."
                 : "You will need to pair or sign in again on this device.")
                .font(SettingsType.confirmBody).foregroundStyle(Color("PigSecondary"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Stay signed in") { close() }
                    .pigPrimaryButton()
                    #if os(tvOS)
                    .focused($focus, equals: .stay)
                    #else
                    .buttonStyle(.borderless)
                    #endif
                    .accessibilityIdentifier("settings.account.stay")
                Button("Sign out", role: .destructive) {
                    let changeServer = reason == .changeServer
                    confirm = nil
                    signedOut()
                    Task { await model.logout(chooseServer: changeServer) }
                }
                #if os(tvOS)
                .foregroundStyle(Color.pigDanger)
                #else
                .buttonStyle(.bordered).tint(Color.pigDanger)
                #endif
                .disabled(model.playbackBusy)
                .accessibilityIdentifier("settings.account.confirmSignOut")
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(SettingsMetrics.confirmPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigDanger.opacity(0.45), lineWidth: 2) }
        // Menu answers "Stay signed in".
        .onExitCommand { close() }
        #else
        .listRowBackground(RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).fill(Color.pigRaised)
            .overlay { RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigDanger, lineWidth: 2) })
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.account.confirm")
    }
}

// C-F: one persistent Labs switch (default off) with its one-line
// explanation. On TV it is a surface button showing On/Off, like the
// appearance rows; elsewhere a Form toggle.
private struct LabsToggleRow: View {
    let toggle: Labs.Toggle
    @AppStorage private var isOn: Bool
    init(toggle: Labs.Toggle) {
        self.toggle = toggle
        _isOn = AppStorage(wrappedValue: false, toggle.key)
    }
    var body: some View {
        #if os(tvOS)
        Button { isOn.toggle() } label: {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(toggle.title)
                    Text(toggle.detail).font(.system(size: 20)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(isOn ? "On" : "Off").foregroundStyle(.secondary)
            }
            .font(.system(size: 24))
            .padding(.horizontal, 24).padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle())
        .accessibilityIdentifier(toggle.key)
        .accessibilityValue(isOn ? "On" : "Off")
        #else
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.title)
                Text(toggle.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(Color.pigAccent)
        .listRowBackground(Color.pigRaised)
        .accessibilityIdentifier(toggle.key)
        #endif
    }
}

#if os(tvOS)
/// Settings → Diagnostics: "Top Shelf: Written 25 Sep 2026 at 5:01 pm, 12
/// items · App Group OK" and what the extension did when tvOS last asked.
/// Read off the main actor each time the page appears.
private struct TopShelfDiagnosticsRows: View {
    @State private var lines: TopShelfDiagnostics.Lines?
    var body: some View {
        Group {
            SettingsRow("Top Shelf", value: lines?.snapshot ?? "Checking…", wraps: true)
            SettingsRow("Top Shelf extension", value: lines?.extensionStatus ?? "Checking…", wraps: true)
        }
        .task {
            lines = await Task.detached(priority: .utility) { TopShelfDiagnostics.lines() }.value
        }
    }
}
#endif

// Read-only settings value. On TV it sits on the same cell surface as the
// guide so the page matches the other tabs; elsewhere it is a Form row.
struct SettingsRow: View {
    let title: String
    let value: String
    var wraps = false
    var monospaced = false
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, value: String, wraps: Bool = false, monospaced: Bool = false) {
        self.title = title; self.value = value; self.wraps = wraps; self.monospaced = monospaced
    }
    var body: some View {
        #if os(tvOS)
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Spacer()
            Text(value).fontWeight(.semibold).fontDesign(monospaced ? .monospaced : nil)
                .lineLimit(wraps ? 2 : 1).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 24))
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: PigRadius.card))
        .accessibilityElement(children: .combine)
        #else
        LabeledContent(title) { Text(value).fontDesign(monospaced ? .monospaced : nil).foregroundStyle(Color("PigText")) }
            .listRowBackground(Color.pigRaised)
        #endif
    }
}
