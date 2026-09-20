import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.loggedIn { LibraryView(model: model) }
            else if let message = model.unreachable { UnreachableView(model: model, message: message).tint(Color("AccentColor")) }
            else { OnboardingView(model: model).tint(Color("AccentColor")) }
        }
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
        .task { await model.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await model.background() } }
        }
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
                VStack(spacing: 24) {
                    ProgressView("Reconnecting…")
                    Button("Back to guide") { dismiss() }
                }.foregroundStyle(.white)
            } else if playback.ready {
                NativePlayer(playback: playback, app: app).ignoresSafeArea()
                    #if os(iOS)
                    .overlay(alignment: .top) { iOSControls }
                    #endif
            } else {
                VStack(spacing: 24) {
                    ProgressView("Preparing \(playback.channel.name)…")
                    Button("Cancel") { dismiss() }
                }.foregroundStyle(.white)
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
        .sheet(isPresented: $showingGuide) {
            NavigationStack {
                QuickGuidePanel(app: app, browse: app.browse) { showingGuide = false }
                    .navigationTitle("Channels")
                    #if os(iOS)
                    .toolbar { Button("Done") { showingGuide = false } }
                    #endif
            }
            .presentationBackground { PigPageBackground() }
        }
        .onChange(of: app.channelSheetRequested) { _, requested in
            if requested { app.channelSheetRequested = false; showingGuide = true }
        }
        .onAppear { playback.start() }
        .onDisappear { Task { await app.endPlayback(playback) } }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
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
            Button { showingGuide = true } label: { Image(systemName: "list.bullet.circle.fill") }
                .accessibilityLabel("Channels")
        }
        .font(.title2).foregroundStyle(.white, .black.opacity(0.6))
        .padding(.horizontal, 16).padding(.top, 8)
    }
    #endif
}

struct NativePlayer: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.allowsPictureInPicturePlayback = false
        #if os(tvOS)
        PlayerPanels.configure(controller, playback: playback, app: app)
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== playback.player { controller.player = playback.player }
        #if os(tvOS)
        PlayerPanels.updateMenu(controller, playback: playback, app: app)
        #endif
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
