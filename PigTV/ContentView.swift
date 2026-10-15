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
            .overlay(alignment: .top) {
                ProviderReminderBanner(reminders: model.providerReminders)
            }
            // C-K: launch (once signed in), foreground, and after playback.
            .task(id: model.loggedIn) { await model.checkProviderReminders() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.checkProviderReminders() } }
            }
            .onChange(of: model.playerPresented) { _, presented in
                if presented { model.providerReminders.dismiss() }
                else { Task { await model.checkProviderReminders() } }
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
            if !initialRestoreFinished { LaunchLoadingView().transition(.opacity) }
            else if model.loggedIn { LibraryView(model: model) }
            else if let message = model.unreachable { UnreachableView(model: model, message: message).tint(Color("AccentColor")) }
            else { OnboardingView(model: model).tint(Color("AccentColor")) }
        }
        // The splash never holds the app back: when start-up finishes it fades out at once.
        .animation(.easeOut(duration: 0.25), value: initialRestoreFinished)
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
        .task {
            // Build 37: Siri is gone; remove the channel directory older builds wrote.
            TopShelfExport.removeLegacyChannelDirectory()
        }
        .task {
            // This is a cold-launch handoff only. It has no arbitrary minimum
            // duration and is not replayed when the app returns to foreground.
            await model.restore()
            initialRestoreFinished = true
        }
        .onChange(of: scenePhase) { _, phase in
            model.warmer.setActive(phase == .active) // R11: any other phase cancels warming
            if phase == .background { Task { await model.background() } }
        }
        .environment(\.channelWarmer, model.warmer)
        // A4.1: Top Shelf items open pigtv://play.
        .onOpenURL { model.open($0) }
        .alert("PigTV", isPresented: Binding(
            // Not while the player is up: an alert under a full-screen cover can't take
            // the tvOS focus, so it could not be dismissed. It shows once the player closes.
            get: { model.error != nil && !model.playerPresented }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .fullScreenCover(isPresented: $model.playerPresented) {
            PlayerHost(app: model).tint(Color("AccentColor"))
        }
    }
}

/// C-K: a short, non-blocking licence reminder over whatever is showing. An
/// overlay, not a cover, so it never joins the focus chain of a presentation;
/// on tvOS it cannot take focus at all (it goes away by itself after 15 s).
struct ProviderReminderBanner: View {
    @ObservedObject var reminders: ProviderReminderModel

    var body: some View {
        if let message = reminders.message {
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: bannerIcon)).accessibilityHidden(true)
                Text(message).font(.system(size: bannerText, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                Button("OK") { reminders.dismiss() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("providerReminder.dismiss")
                #endif
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(maxWidth: 1100)
            .reminderBackground()
            .padding(.top, bannerTop).padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("providerReminder")
            #if os(tvOS)
            .focusable(false)
            #endif
        }
    }

    private var bannerIcon: CGFloat { tv ? 34 : 20 }
    private var bannerText: CGFloat { tv ? 28 : 15 }
    private var bannerTop: CGFloat { tv ? 40 : 8 }
    private var tv: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }
}

private extension View {
    /// The provider reminder floats over the content, so on iOS it is Liquid Glass; tvOS keeps its material.
    @ViewBuilder func reminderBackground() -> some View {
        #if os(tvOS)
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #else
        glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #endif
    }
}

private struct LaunchLoadingView: View {
    var body: some View { BrandSplashView() }
}

struct UnreachableView: View {
    @ObservedObject var model: AppModel
    let message: String
    @State private var showSignIn = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if showSignIn {
            OnboardingView(model: model)
        } else {
            ZStack {
                PigPageBackground()
                VStack(spacing: 26) {
                    PigBrandMark(width: 150, height: 120)
                        .accessibilityHidden(true)
                    Eyebrow(text: "Offline")
                    Text("Can't reach PigTV").font(DetailType.title)
                    Text(message).font(DetailType.meta).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: 820)
                    Text(model.serverText).font(DetailType.rowDetail.monospaced())
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.guideCell(scheme), in: Capsule())
                    if model.authBusy {
                        ProgressView("Trying again…").padding(.top, 10)
                    } else {
                        DetailActions {
                            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.restore() } }
                                .pigPrimaryButton()
                            Button("Use a different server", systemImage: "server.rack") { showSignIn = true }
                        }
                        .padding(.top, 10)
                    }
                    Text("PigTV keeps trying every 20 seconds while this screen is open.")
                        .font(DetailType.rowDetail).foregroundStyle(.secondary)
                }
                .padding(60)
                .frame(maxWidth: 1100)
                .background {
                    LogoWash(logo: nil, client: nil)
                        .clipShape(RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous))
                }
                .padding(40)
            }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            PigPageBackground()
            ScrollView {
                #if os(tvOS)
                HStack(alignment: .top, spacing: 60) {
                    brand.frame(width: 620, alignment: .leading)
                    form.frame(maxWidth: 900, alignment: .leading)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                #else
                VStack(alignment: .leading, spacing: 28) {
                    brand
                    form
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                #endif
            }
        }
    }

    /// The pig, the name and what PigTV is, with a static halo behind the pig only.
    private var brand: some View {
        VStack(alignment: .leading, spacing: 20) {
            PigBrandMark(width: 150, height: 120)
                .accessibilityHidden(true)
            PigWordmark()
            Text("Your channels. Your server.").font(DetailType.pageTitle)
            Text("Connect to your PigTV server to watch live TV, browse the guide and play your recordings.")
                .font(DetailType.meta).foregroundStyle(.secondary)
        }
        .padding(DetailMetrics.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { PigIdentityBackdrop() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            PigSectionHeader(title: "Server address")
            TextField("http://pigtv.local:3000", text: $model.serverText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .pigField()
                .disabled(model.authBusy)
            Text("The server address only, with its port if needed. HTTP is fine on your home network.")
                .font(DetailType.rowDetail).foregroundStyle(.secondary)
            if let pairing = model.pairing {
                PigSectionHeader(title: "Pair with your browser")
                VStack(alignment: .leading, spacing: 14) {
                    Text(pairing.code).font(.system(size: 72, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
                    Text("Open PigTV in your browser, sign in, then approve this code in Settings → Devices.")
                        .font(DetailType.meta)
                    Text("Expires \(pairing.expiry, style: .time)").font(DetailType.rowDetail).foregroundStyle(.secondary)
                    ProgressView("Waiting for approval…")
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                DetailActions {
                    Button("Cancel pairing", systemImage: "xmark") { model.cancelPairing() }
                }
            } else {
                DetailActions {
                    Button("Pair with browser", systemImage: "link") { model.startPairing() }
                        .pigPrimaryButton()
                        .disabled(model.authBusy || model.serverText.isEmpty)
                }
                PigSectionHeader(title: "Or sign in with your PigTV account")
                TextField("Username", text: $model.username)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).disabled(model.authBusy)
                    .pigField()
                SecureField("Password", text: $model.password).disabled(model.authBusy)
                    .pigField()
                DetailActions {
                    Button("Sign in", systemImage: "person.crop.circle") { Task { await model.login() } }
                        .disabled(model.authBusy || model.serverText.isEmpty || model.username.isEmpty || model.password.isEmpty)
                    if model.canRestore {
                        Button("Retry saved sign-in", systemImage: "arrow.clockwise") { Task { await model.restore() } }
                            .disabled(model.authBusy)
                    }
                }
                if model.authBusy { ProgressView("Connecting…") }
            }
        }
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
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
        // iPhone: full-screen playback is landscape (the host outlives channel switches).
        .forcesLandscapeOnPhone()
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
    // Build 31: PigTV's controls are the only ones (AVKit's are off); a tap
    // on the picture shows/hides them, see PlayerChromeTimer.
    @State private var chromeVisible = true
    @State private var lastInput = Date()
    @StateObject private var pip = PiPHandle()
    @Environment(\.horizontalSizeClass) private var sizeClass
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
                    if playback.canRetry { Button("Retry") { playback.retry() }.pigPrimaryButton() }
                    Button("Back to channels") { dismiss() }
                }.padding(48).foregroundStyle(.white)
            } else if playback.reconnecting {
                // Build 29: the tuning card on iOS too.
                VStack(spacing: 24) {
                    TuningCard(playback: playback, browse: app.browse, message: "Reconnecting…")
                    Button("Back to guide") { dismiss() }
                }
                .environment(\.colorScheme, .dark)
                #if os(tvOS)
                .onExitCommand { dismiss() }
                #endif
            } else if playback.ready {
                #if os(tvOS)
                CustomPlayerView(playback: playback, app: app) { Task { await app.endPlayback(playback) } }
                #else
                touchPlayer
                #endif
            } else {
                VStack(spacing: 24) {
                    TuningCard(playback: playback, browse: app.browse, message: "Tuning…")
                    Button("Cancel") { dismiss() }
                }
                .environment(\.colorScheme, .dark)
                #if os(tvOS)
                .onExitCommand { dismiss() }
                #endif
            }
        }
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
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
        .overlay(alignment: .top) {
            if let warning = playback.coordinationWarning {
                Text(warning).font(.caption).padding()
                    .background(.black.opacity(0.8)).foregroundStyle(.white)
            }
        }
        #if os(iOS)
        // Build 29: iPhone (compact width) opens the channel list as a
        // bottom sheet (the system Liquid Glass sheet: no custom background); iPad uses the side panel (touchPlayer).
        .sheet(isPresented: Binding(get: { showingGuide && sizeClass != .regular },
                                    set: { if !$0 { showingGuide = false } })) {
            NavigationStack {
                PlayerChannelPanel(app: app) { showingGuide = false }
                    .navigationTitle("Channels")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showingGuide = false } }
            }
            .presentationDetents([.medium, .large])
            .environment(\.colorScheme, .dark)
        }
        #endif
        #if DEBUG && os(iOS)
        .onAppear {
            // Fixture (PIGTV_UI_TEST_SCREEN=player-channels): open the panel.
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "player-channels" { showingGuide = true }
        }
        #endif
        #if os(iOS)
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
    /// The picture (AVKit, with its own controls off) and PigTV's controls
    /// over it (build 31); the channel side panel on iPad.
    private var touchPlayer: some View {
        ZStack {
            NativePlayer(player: playback.player, pip: pip, onClosed: { Task { await app.endPlayback(playback) } })
                .ignoresSafeArea()
            // A tap on the picture (anywhere not on a control) shows or hides
            // the controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    chromeVisible = PlayerChromeTimer.afterTap(visible: chromeVisible)
                    lastInput = Date()
                }
                .accessibilityLabel("Video")
                .accessibilityHint("Shows or hides the player controls")
            if chromeVisible, let browse = app.browse {
                TouchPlayerChrome(playback: playback, app: app, browse: browse, pip: pip,
                                  close: { dismiss() },
                                  openGuide: {
                                      app.requestedTab = "guide"
                                      dismiss()
                                  },
                                  openChannels: { showingGuide = true; lastInput = Date() },
                                  enterNumber: { enteringNumber = true; lastInput = Date() },
                                  touch: { lastInput = Date() })
                    .transition(.opacity)
            }
            if showingGuide && sizeClass == .regular {
                PlayerSidePanel(app: app) { showingGuide = false; lastInput = Date() }
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.easeInOut(duration: 0.22), value: showingGuide)
        .task(id: lastInput) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let paused = playback.player.timeControlStatus == .paused
                if !UIAccessibility.isVoiceOverRunning,
                   PlayerChromeTimer.shouldHide(visible: chromeVisible, lastInput: lastInput, now: Date(),
                                                paused: paused, panelOpen: showingGuide || enteringNumber) {
                    chromeVisible = false
                }
            }
        }
    }
    #endif
}

#if os(iOS)
// iPhone/iPad picture (live and recordings): a bare AVPlayerLayer view (PigTV's
// controls are the only ones on screen). It replaces AVPlayerViewController (build 31) so PigTV's own
// button can start Picture in Picture: AVPlayerViewController has no API for
// that. The PiP controller starts by itself when the app is left (auto-PiP),
// closing the PiP window ends playback (`onClosed`), and expanding it returns
// to this still-presented full-screen player. Apple TV uses CustomPlayerView.
struct NativePlayer: UIViewRepresentable {
    let player: AVPlayer
    var pip: PiPHandle?
    /// The PiP window was closed (not expanded): end the playback.
    var onClosed: () -> Void = {}

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClosed: onClosed) }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.attachPiP(to: view.playerLayer, handle: pip)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        context.coordinator.onClosed = onClosed
        context.coordinator.attachPiP(to: view.playerLayer, handle: pip) // early in a launch PiP may not be supported yet
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: LayerView, coordinator: Coordinator) {
        coordinator.controller?.delegate = nil
        coordinator.controller = nil
        PictureInPictureState.shared.set(active: false)
        PictureInPictureState.shared.armed = false
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var onClosed: () -> Void
        var controller: AVPictureInPictureController?
        private var restoring = false
        init(onClosed: @escaping () -> Void) { self.onClosed = onClosed }

        func attachPiP(to layer: AVPlayerLayer, handle: PiPHandle?) {
            guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported(),
                  let made = AVPictureInPictureController(playerLayer: layer) else { return }
            made.canStartPictureInPictureAutomaticallyFromInline = true
            made.delegate = self
            controller = made
            handle?.controller = made
            PictureInPictureState.shared.armed = true
        }

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            restoring = false
            PictureInPictureState.shared.set(active: true)
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            // The full-screen player was never dismissed, so it is already there.
            restoring = true
            completionHandler(true)
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            PictureInPictureState.shared.set(active: false)
            if !restoring { onClosed() }
            restoring = false
        }
    }
}
#endif
