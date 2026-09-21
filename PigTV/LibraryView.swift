import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // Tint is applied per tab so the tab bar keeps the system's own
        // selected-item colouring (pink-on-grey was unreadable).
        TabView {
            if let browse = model.browse {
                GuideView(app: model, model: browse)
                    .tint(Color("AccentColor"))
                    .tabItem { Label("TV Guide", systemImage: "calendar") }
                RecordingsView(model: browse)
                    .tint(Color("AccentColor"))
                    .tabItem { Label("Recordings", systemImage: "record.circle") }
            }
            LibrarySettings(model: model, isTab: true)
                .tint(Color("AccentColor"))
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}


struct LiveChannelsView: View {
    @ObservedObject var model: AppModel
    @State private var details: Channel?
    @State private var settings = false
    @State private var pendingPlayback: Channel?

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 270), spacing: 22)]
        #else
        [GridItem(.adaptive(minimum: 240), spacing: 16)]
        #endif
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    Button { select(nil) } label: {
                        Label("All channels", systemImage: model.selectedCategory == nil ? "checkmark.circle.fill" : "tv")
                    }
                }
                Section("Categories") {
                    ForEach(model.categories) { category in
                        Button { select(category) } label: {
                            HStack {
                                Text(category.name)
                                Spacer()
                                if model.selectedCategory == category {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
            }
            .navigationTitle("PigTV")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("LIVE TV", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                            Text(model.selectedCategory?.name ?? "On now")
                                .font(.title2.bold())
                            Text("\(model.channels.count) channels loaded")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 60)) { time in
                            Text(time.date, style: .time)
                                .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        }.accessibilityHidden(true)
                    }
                    HStack {
                        TextField("Search channels", text: $model.search)
                            .autocorrectionDisabled()
                            .onSubmit { reload() }
                        Button("Search", systemImage: "magnifyingglass") { reload() }
                        Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                    }
                    if model.channels.isEmpty && !model.libraryBusy {
                        ContentUnavailableView("No channels here", systemImage: "tv",
                            description: Text(model.hasMore
                                ? "Load more to find channels in this source."
                                : "Try another category or search, or check your server’s source sync."))
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(model.channels) { channel in
                            Button { details = channel } label: {
                                ChannelCard(channel: channel, client: model.browse?.client, logo: model.browse?.logo(for: channel))
                            }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityHint("Show programme details and watch live")
                        }
                    }
                    if model.libraryBusy { ProgressView("Loading channels…") }
                    if model.hasMore {
                        Button("Load more channels") {
                            Task { await model.loadLibrary(reset: false) }
                        }.disabled(model.libraryBusy)
                    }
                    if model.playbackBusy && model.playback == nil {
                        ProgressView("Releasing the previous stream…")
                    }
                }
                .padding(32)
            }
            .navigationTitle("Live TV")
        }
        .fullScreenCover(item: $details, onDismiss: {
            // Wait for the detail sheet to finish closing before presenting
            // the full-screen player.
            if let channel = pendingPlayback {
                pendingPlayback = nil
                model.beginPlayback(channel)
            }
        }) { channel in
            ChannelDetails(channel: channel, browse: model.browse) {
                pendingPlayback = channel
                details = nil
            }
        }
        .sheet(isPresented: $settings) { LibrarySettings(model: model) }
    }

    private func reload() { Task { await model.loadLibrary() } }
    private func select(_ category: Category?) {
        model.selectedCategory = category
        reload()
    }
}

struct ChannelCard: View {
    let channel: Channel
    var client: APIClient? = nil
    var logo: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ChannelArtwork(logo: logo ?? channel.logo, client: client)
                    .frame(width: 72, height: 42)
                Spacer()
                Text("LIVE").font(.caption2.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Text(channel.name).font(.headline).lineLimit(2)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let current = currentProgramme(channel, at: timeline.date)
                VStack(alignment: .leading, spacing: 10) {
                    Text(current?.title ?? "Programme information unavailable")
                        .font(.subheadline).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    ProgressView(value: current?.progress(at: timeline.date) ?? 0)
                        .accessibilityLabel("Programme progress")
                    if let current {
                        HStack {
                            Text(current.start, style: .time)
                            Spacer()
                            Text(current.end, style: .time)
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Watch channel for live content")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .top) {
            Capsule().fill(Color.accentColor).frame(width: 44, height: 3)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle.bold())
                settingsContent
            }
            .padding(64)
        }
        .background(PigPageBackground())
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
                        .padding(20)
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
            } header: { Text("Appearance").foregroundStyle(.secondary) }
            Section {
                LabeledContent("Signed in as", value: model.user?.username ?? "")
                LabeledContent("Server", value: model.serverText)
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .disabled(model.playbackBusy)
            } header: { Text("Account").foregroundStyle(.secondary) }
            Section {
                LabeledContent("App", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                LabeledContent("Server", value: model.serverInfo?.identity ?? "Unknown")
            } header: { Text("Version").foregroundStyle(.secondary) }
            if !isTab {
                Section { Button("Done") { dismiss() } }
            }
        }
    }

    private var signOutButton: some View {
        Button("Sign out", role: .destructive) {
            dismiss()
            Task { await model.logout() }
        }
    }
}
