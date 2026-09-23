import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // Accent tint on the TabView so the selected tab reads pink — the
        // white selection was hard to distinguish from unselected tabs.
        TabView {
            if let browse = model.browse {
                GuideView(app: model, model: browse)
                    .tabItem { Label("TV Guide", systemImage: "calendar") }
                RecordingsView(model: browse)
                    .tabItem { Label("Recordings", systemImage: "record.circle") }
            }
            LibrarySettings(model: model, isTab: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color("AccentColor"))
    }
}


// EPG responses can outlive their current programme. Never present expired
// metadata as live; the supplied next programme can take over when it starts.
private func currentProgramme(_ channel: Channel, at date: Date) -> Programme? {
    [channel.now, channel.next].compactMap { $0 }.first {
        $0.start <= date && date < $0.end
    }
}

struct ChannelDetails: View {
    let channel: Channel
    var browse: BrowseModel? = nil
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        ChannelArtwork(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client)
                            .frame(width: 96, height: 64)
                        Text(channel.name).font(.title2.bold())
                    }
                    Button("Watch live", systemImage: "play.fill", action: watch)
                        .pigPrimaryButton()
                    if let category = channel.category {
                        Text(category).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        VStack(alignment: .leading, spacing: 24) {
                            if let now = currentProgramme(channel, at: timeline.date) {
                                programme(now, heading: "On now")
                                ProgressView(value: now.progress(at: timeline.date))
                            } else {
                                Text("Programme information unavailable")
                                    .foregroundStyle(.secondary)
                            }
                            if let next = channel.next, next.start > timeline.date {
                                Divider()
                                programme(next, heading: "Up next")
                            }
                        }
                    }
                    if let browse { FavouriteControl(channel: channel, client: browse.client) }
                    Button("Back to channels") { dismiss() }
                }.padding(40).frame(maxWidth: 850, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("Channel")
            .presentationBackground { PigPageBackground() }
        }
    }

    private func programme(_ item: Programme, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading.uppercased()).font(.caption.bold()).foregroundStyle(Color.accentColor)
            Text(item.title).font(.title2.bold())
            HStack {
                Text(item.start, style: .time)
                Text("–")
                Text(item.end, style: .time)
            }.foregroundStyle(.secondary)
        }
    }
}

struct FavouriteControl: View {
    let channel: Channel
    let client: APIClient
    @State private var saved: Bool?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved {
                Button(saved ? "Remove from favourites" : "Add to favourites",
                       systemImage: saved ? "heart.fill" : "heart") {
                    Task { await change(!saved) }
                }.disabled(busy)
            } else if busy {
                ProgressView("Checking favourite…")
            } else {
                Button("Check favourite status") { Task { await check() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.task { await check() }
    }

    private func check() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: FavouriteCheck = try await client.request("favorites/check", query: [
                URLQueryItem(name: "sourceId", value: String(channel.sourceId)),
                URLQueryItem(name: "itemId", value: channel.rawID),
                URLQueryItem(name: "itemType", value: "channel")
            ])
            saved = result.isFavorite
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ value: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: ActionResult = try await client.request("favorites", method: value ? "POST" : "DELETE",
                body: FavouriteBody(sourceId: channel.sourceId, itemId: channel.rawID))
            guard result.success else { throw PigTVError.message("The server did not confirm the favourite change.") }
            saved = value
        } catch { self.error = error.localizedDescription }
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
        .confirmationDialog("Sign out of PigTV?", isPresented: $confirmSignOut) {
            signOutButton
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
                    Text("Sign out")
                        #if os(tvOS)
                        .font(.system(size: 24))
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
            Section {
                SettingsRow("App", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                SettingsRow("Server", value: model.serverInfo?.identity ?? "Unknown")
            } header: { sectionHeader("Version") }
            if !isTab {
                Section { Button("Done") { dismiss() } }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            #if os(tvOS)
            .font(.system(size: 24, weight: .semibold)).padding(.top, 8)
            #endif
            .foregroundStyle(.secondary)
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

// Read-only settings value. On TV it sits on the same cell surface as the
// guide so the page matches the other tabs; elsewhere it is a Form row.
private struct SettingsRow: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        #if os(tvOS)
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.system(size: 24))
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 10))
        #else
        LabeledContent(title, value: value)
        #endif
    }
}
