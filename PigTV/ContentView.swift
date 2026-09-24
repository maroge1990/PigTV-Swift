import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var initialRestoreFinished = false
    // Appearance is owned here (a View), not in the App/Scene: an @AppStorage
    // change re-renders a View immediately, where the Scene-level modifier only
    // took effect after a relaunch.
    @AppStorage("pigtv.appearance") private var appearance = "system"

    var body: some View {
        content
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            // Keep UIKit's trait in step with SwiftUI's. Dismissing the full-
            // screen player could drop the root preferredColorScheme override on
            // the UIKit side only, leaving system-dark backgrounds under
            // light-mode text; setting the window style directly survives that.
            .onChange(of: appearance, initial: true) { syncWindowStyle() }
            .onChange(of: model.playerPresented) { _, presented in
                guard !presented else { return }
                syncWindowStyle()
                // Presentation teardown finishes after this change; apply again.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    syncWindowStyle()
                }
            }
    }

    private func syncWindowStyle() {
        let style: UIUserInterfaceStyle = appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private var content: some View {
        Group {
            if !initialRestoreFinished { LaunchLoadingView() }
            else if model.loggedIn { LibraryView(model: model) }
            else if let message = model.unreachable { UnreachableView(model: model, message: message).tint(Color("AccentColor")) }
            else { OnboardingView(model: model).tint(Color("AccentColor")) }
        }
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
        .task {
            // This is a cold-launch handoff only. It has no arbitrary minimum
            // duration and is not replayed when the app returns to foreground.
            await model.restore()
            initialRestoreFinished = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await model.background() } }
        }
        // A4.1/A4.5: Top Shelf items and the Siri intent open pigtv://play.
        .onOpenURL { model.open($0) }
        .alert("PigTV", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .fullScreenCover(isPresented: $model.playerPresented) {
            PlayerHost(app: model).tint(Color("AccentColor"))
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            PigPageBackground()
            VStack(spacing: 20) {
                Image("PigLogo").resizable().scaledToFit().frame(width: 150, height: 120)
                Text("PigTV").font(.largeTitle.bold())
                ProgressView("Starting PigTV…")
            }
            .padding(48)
        }
    }
}

struct UnreachableView: View {
    @ObservedObject var model: AppModel
    let message: String
    @State private var showSignIn = false
    var body: some View {
        if showSignIn {
            OnboardingView(model: model)
        } else {
            VStack(spacing: 24) {
                Image("PigLogo").resizable().scaledToFit().frame(width: 120, height: 96)
                Text("Can't reach PigTV").font(.largeTitle.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 700)
                Text(model.serverText).font(.callout.monospaced()).foregroundStyle(.secondary)
                if model.authBusy {
                    ProgressView("Trying again…")
                } else {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await model.restore() } }
                        .pigPrimaryButton()
                    Button("Use a different server") { showSignIn = true }
                }
            }
            .padding(48)
            .task {
                // Keep retrying quietly while this screen is showing.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    if !model.authBusy { await model.restore() }
                }
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label { Text("PigTV") } icon: { Image("PigLogo").resizable().scaledToFit().frame(width: 80, height: 64) }
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color("AccentColor"))
                    Text("Your channels. Your server.").font(.title2)
                    Text("Connect to your PigTV server to watch live TV.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Server address").font(.headline)
                        TextField("http://pigtv.local:3000", text: $model.serverText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(model.authBusy)
                        Text("Use the server address only, including its port if needed. HTTP is supported for your home network.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    if let pairing = model.pairing {
                        Text(pairing.code).font(.largeTitle.monospaced().bold())
                            .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
                        Text("Open PigTV in your browser, sign in, then approve this code in Settings → Devices.")
                        Text("Expires \(pairing.expiry, style: .time)").foregroundStyle(.secondary)
                        ProgressView("Waiting for approval…")
                        Button("Cancel pairing") { model.cancelPairing() }
                    } else {
                        Button("Pair with browser", systemImage: "link") { model.startPairing() }
                            .pigPrimaryButton()
                            .disabled(model.authBusy || model.serverText.isEmpty)
                        Text("Or sign in with your PigTV account").font(.headline)
                        TextField("Username", text: $model.username)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).disabled(model.authBusy)
                        SecureField("Password", text: $model.password).disabled(model.authBusy)
                        Button("Sign in") { Task { await model.login() } }
                            .buttonStyle(.bordered)
                            .disabled(model.authBusy || model.serverText.isEmpty || model.username.isEmpty || model.password.isEmpty)
                        if model.authBusy { ProgressView("Connecting…") }
                        if model.canRestore {
                            Button("Retry saved sign-in") { Task { await model.restore() } }.disabled(model.authBusy)
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// Stays presented while channels change underneath it, so switching never
// dismisses and re-presents the player.
struct PlayerHost: View {
    @ObservedObject var app: AppModel
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let playback = app.playback {
                PlayerScreen(playback: playback, app: app).id(playback.id)
            }
        }
    }
}

struct PlayerScreen: View {
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingGuide = false
    #if os(iOS)
    // C-A: iOS "Go to number" (tvOS has no digit entry).
    @State private var enteringNumber = false
    @State private var typedNumber = ""
    @State private var numberNotFound: String?
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let message = playback.viewerConflict {
                VStack(spacing: 24) {
                    Text("Another device is watching").font(.title2.bold())
                    Text(message).multilineTextAlignment(.center)
                    Button("Keep watching there") { dismiss() }.pigPrimaryButton()
                    Button("Stop the other stream and watch here", role: .destructive) { playback.confirmViewerStop() }
                }.padding(48).foregroundStyle(.white)
            } else if let conflict = playback.recordingConflict {
                VStack(spacing: 24) {
                    Text("A recording is in progress").font(.title2.bold())
                    Text("\(conflict.title) on \(conflict.channelName)")
                    Text("Watching live TV will stop the recording. What has already been recorded will be kept.")
                    Button("Keep recording") { dismiss() }.pigPrimaryButton()
                    Button("Stop recording and watch", role: .destructive) { playback.confirmRecordingStop() }
                }.padding(48).foregroundStyle(.white)
            } else if let error = playback.error {
                VStack(spacing: 24) {
                    Text("Unable to play \(playback.channel.name)").font(.title2)
                    Text(error)
                    if playback.canRetry { Button("Retry") { playback.retry() } }
                    Button("Back to channels") { dismiss() }
                }.padding(48).foregroundStyle(.white)
            } else if playback.reconnecting {
                #if os(tvOS)
                VStack(spacing: 24) {
                    TuningCard(playback: playback, browse: app.browse, message: "Reconnecting…")
                    Button("Back to guide") { dismiss() }
                }
                .environment(\.colorScheme, .dark)
                .onExitCommand { dismiss() }
                #else
                VStack(spacing: 24) {
                    ProgressView("Reconnecting…")
                    Button("Back to guide") { dismiss() }
                }.foregroundStyle(.white)
                #endif
            } else if playback.ready {
                #if os(tvOS)
                CustomPlayerView(playback: playback, app: app) { Task { await app.endPlayback(playback) } }
                #else
                NativePlayer(playback: playback).ignoresSafeArea()
                    .overlay(alignment: .top) { iOSControls }
                #endif
            } else {
                #if os(tvOS)
                VStack(spacing: 24) {
                    TuningCard(playback: playback, browse: app.browse, message: "Tuning…")
                    Button("Cancel") { dismiss() }
                }
                .environment(\.colorScheme, .dark)
                .onExitCommand { dismiss() }
                #else
                VStack(spacing: 24) {
                    ProgressView("Preparing \(playback.channel.name)…")
                    Button("Cancel") { dismiss() }
                }.foregroundStyle(.white)
                #endif
            }
        }
        .alert("A recording needs the stream", isPresented: Binding(
            get: { playback.recordingPrompt != nil },
            set: { if !$0 { playback.recordingPrompt = nil } }
        ), presenting: playback.recordingPrompt) { prompt in
            Button("Stop playback for recording") {
                Task { await app.endPlayback(playback) }
            }
            Button("Keep watching", role: .cancel) { playback.keepWatching(prompt) }
        } message: { prompt in
            Text("\(prompt.title) on \(prompt.channelName) is due to record. Stop playback to allow it? If you keep watching, the recording will wait for the stream.")
        }
        .overlay(alignment: .bottom) {
            if let warning = playback.coordinationWarning {
                Text(warning).font(.caption).padding()
                    .background(.black.opacity(0.8)).foregroundStyle(.white)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingGuide) {
            NavigationStack {
                QuickGuidePanel(app: app, browse: app.browse) { showingGuide = false }
                    .navigationTitle("Channels")
                    .toolbar { Button("Done") { showingGuide = false } }
            }
            .presentationBackground { PigPageBackground() }
        }
        .alert("Go to channel", isPresented: $enteringNumber) {
            TextField("Channel number", text: $typedNumber)
                .keyboardType(.numberPad)
            Button("Go") {
                let text = typedNumber
                typedNumber = ""
                if !app.goToChannel(numberText: text) {
                    numberNotFound = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            Button("Cancel", role: .cancel) { typedNumber = "" }
        } message: {
            Text("Enter a channel number.")
        }
        .alert("No channel \(numberNotFound ?? "")", isPresented: Binding(
            get: { numberNotFound != nil }, set: { if !$0 { numberNotFound = nil } })) {
            Button("OK", role: .cancel) { numberNotFound = nil }
        } message: {
            Text("No channel in the guide has that number.")
        }
        #endif
        .onAppear { playback.start() }
        .onDisappear { Task { await app.endPlayback(playback) } }

    }

    #if os(iOS)
    private var iOSControls: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Close playback")
            Spacer()
            Text(playback.channel.name).font(.subheadline.bold()).lineLimit(1)
            Spacer()
            Button { app.zap(-1) } label: { Image(systemName: "chevron.down.circle.fill") }
                .accessibilityLabel("Previous channel")
            Button { app.zap(1) } label: { Image(systemName: "chevron.up.circle.fill") }
                .accessibilityLabel("Next channel")
            if app.browse?.showsChannelNumbers == true {
                Button { enteringNumber = true } label: { Image(systemName: "number.circle.fill") }
                    .accessibilityLabel("Go to number")
            }
            Button { showingGuide = true } label: { Image(systemName: "list.bullet.circle.fill") }
                .accessibilityLabel("Channels")
        }
        .font(.title2).foregroundStyle(.white, .black.opacity(0.6))
        .padding(.horizontal, 16).padding(.top, 8)
    }
    #endif
}

#if os(tvOS)
// A1.2: shown centred over black while resolving media or reconnecting, so a
// channel change reads as "tuning to something" rather than a blank wait.
// Built entirely from cached guide data (`playback.programme()`/
// `nextProgramme()`), so there is no network wait to show it.
private struct TuningCard: View {
    @ObservedObject var playback: PlaybackModel
    let browse: BrowseModel?
    let message: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let programme = playback.programme(at: context.date)
            let next = playback.nextProgramme(after: context.date)
            VStack(spacing: 18) {
                LogoTile(logo: browse?.logo(for: playback.channel) ?? playback.channel.logo,
                         client: browse?.client, name: playback.channel.name)
                    .frame(width: 200, height: 110)
                Text(playback.channel.name).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(programme?.title ?? "No programme information")
                    .font(.system(size: 32, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                if let programme {
                    Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    GeometryReader { geometry in
                        let progress = min(1, max(0, context.date.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start)))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white).frame(width: geometry.size.width * progress)
                        }
                    }.frame(width: 360, height: 6)
                }
                if let next {
                    Text("Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.65))
                }
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(message).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(48)
        .frame(maxWidth: 640)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
    }
}
#endif

#if os(iOS)
// iPhone/iPad player: AVKit with its standard controls. Apple TV uses the
// PigTV-owned CustomPlayerView instead.
struct NativePlayer: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== playback.player { controller.player = playback.player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
