import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    /// The tab the app opens on (Home; the offline fixtures pick their own).
    var initialTab = "home"
    @State private var tab: String?
    var body: some View {
        // Accent tint on the TabView so the selected tab reads pink — the
        // white selection was hard to distinguish from unselected tabs.
        TabView(selection: Binding(get: { tab ?? (model.browse == nil ? "settings" : initialTab) },
                                   set: { tab = $0 })) {
            if let browse = model.browse {
                // Build 28: Home opens with the app.
                HomeView(app: model, model: browse, openGuide: { tab = "guide" }, openSport: { tab = "sport" })
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag("home")
                GuideView(app: model, model: browse)
                    .tabItem { Label("TV Guide", systemImage: "calendar") }
                    .tag("guide")
                // C-I (build 30): only when the server has sport events.
                // Five tabs fit the iPhone's bar, so it is a tab there too.
                if browse.sportEnabled {
                    SportView(app: model, browse: browse, sport: browse.sport)
                        .tabItem { Label("Sport", systemImage: "sportscourt") }
                        .tag("sport")
                }
                RecordingsView(model: browse)
                    .tabItem { Label("Recordings", systemImage: "record.circle") }
                    .tag("recordings")
            }
            LibrarySettings(model: model, isTab: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .tint(Color("AccentColor"))
        .onChange(of: model.requestedTab, initial: true) { _, requested in
            guard let requested else { return }
            tab = requested
            model.requestedTab = nil
        }
    }
}


struct LibrarySettings: View {
    @ObservedObject var model: AppModel
    var isTab: Bool = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pigtv.appearance") private var appearance = "system"
    @State private var confirmSignOut = false

    var body: some View {
        #if os(tvOS)
        // A SwiftUI scroll layout keeps appearance changes and remote focus
        // in one hierarchy, without nested focusable UITableView cells.
        // Same page treatment as Guide and Recordings: no separate backdrop,
        // the guide's header style and its cell surfaces for every row.
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 14) {
                    Image("PigLogo").resizable().scaledToFit().frame(width: 58, height: 48)
                        .accessibilityHidden(true)
                    Text("Settings").font(.system(size: 34, weight: .bold))
                }
                settingsContent
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 48).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The app's page, not the system's blurred backdrop (build 28).
        .background(PigPageBackground())
        .confirmationDialog("Sign out of PigTV?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            signOutButton
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("You will need to pair or sign in again on this device.")
        }
        #else
        NavigationStack {
            Form { settingsContent }
                .navigationTitle("Settings")
                .scrollContentBackground(.hidden)
                .background(PigPageBackground())
                .confirmationDialog("Sign out of PigTV?", isPresented: $confirmSignOut) {
                    signOutButton
                }
        }
        #endif
    }

    private var settingsContent: some View {
        Group {
            Section {
                ForEach(["system", "light", "dark"], id: \.self) { value in
                    Button { appearance = value } label: {
                        HStack {
                            Text(value.capitalized)
                            Spacer()
                            if appearance == value {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            }
                        }
                        #if os(tvOS)
                        .font(.system(size: 24))
                        .padding(.horizontal, 24).padding(.vertical, 16)
                        #endif
                        .contentShape(Rectangle())
                    }
                    #if os(iOS)
                    .buttonStyle(.borderless)
                    #else
                    .buttonStyle(PigSurfaceButtonStyle())
                    #endif
                    .accessibilityIdentifier("appearance.\(value)")
                    .accessibilityValue(appearance == value ? "Selected" : "Not selected")
                }
            } header: { sectionHeader("Appearance") }
            Section {
                SettingsRow("Signed in as", value: model.user?.username ?? "")
                SettingsRow("Server", value: model.serverText)
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        #if os(tvOS)
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                }
                    #if os(tvOS)
                    .buttonStyle(PigSurfaceButtonStyle())
                    #endif
                    .disabled(model.playbackBusy)
            } header: { sectionHeader("Account") }
            Section {
                ForEach(Labs.toggles) { LabsToggleRow(toggle: $0) }
            } header: { sectionHeader("Labs") }
            #if os(tvOS)
            // Build 31: whether the Top Shelf snapshot was written and
            // whether tvOS asked the extension for it.
            Section { TopShelfDiagnosticsRows() } header: { sectionHeader("Diagnostics") }
            #endif
            Section {
                SettingsRow("App", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                SettingsRow("Server", value: model.serverInfo?.identity ?? "Unknown")
            } header: { sectionHeader("Version") }
            if !isTab {
                Section { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        #if os(tvOS)
        // The detail screens' section heading (build 28).
        PigSectionHeader(title: title)
        #else
        Text(title).foregroundStyle(.secondary)
        #endif
    }

    private var signOutButton: some View {
        Button("Sign out", role: .destructive) {
            dismiss()
            Task { await model.logout() }
        }
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
        .accessibilityIdentifier(toggle.key)
        #endif
    }
}

#if os(tvOS)
/// Settings → Diagnostics: "Top Shelf: Written 25 Sep 2026 at 5:01 pm, 12
/// items · App Group OK" and what the extension did when tvOS last asked.
/// Read off the main actor each time Settings appears.
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
private struct SettingsRow: View {
    let title: String
    let value: String
    var wraps = false
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, value: String, wraps: Bool = false) { self.title = title; self.value = value; self.wraps = wraps }
    var body: some View {
        #if os(tvOS)
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).fixedSize()
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(wraps ? 2 : 1).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 24))
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 10))
        #else
        LabeledContent(title, value: value)
        #endif
    }
}
