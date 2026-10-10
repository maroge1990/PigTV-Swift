import SwiftUI
import Combine

// iPhone/iPad full-screen playback support: forced landscape on iPhone and
// Picture in Picture state. Nothing here exists on tvOS.

#if os(iOS)
import AVKit

/// The orientations the app allows right now. Normally everything the
/// Info.plist lists; while a player is full screen on an iPhone, landscape only.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = defaultMask
    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// A player went full screen: turn the phone to landscape however it is held.
    static func landscape() {
        guard isPhone else { return }
        mask = .landscape
        apply(.landscape)
    }

    /// The player closed: portrait (and everything else) is allowed again. A
    /// phone held upright goes back to portrait; one held sideways stays.
    static func release() {
        guard isPhone else { return }
        mask = defaultMask
        apply(UIDevice.current.orientation.isLandscape ? defaultMask : .portrait)
    }

    private static func apply(_ target: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
    }
}

final class PigTVAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Picture in Picture reads as unsupported until the audio session's
        // category is playback, and NativePlayer sets PiP up when its view is
        // made - before playback would set the category. Setting the category
        // (not activating the session) leaves other apps' audio alone.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Whether a Picture in Picture window is up (or about to be), so leaving the
/// app does not end the playback behind it.
@MainActor
final class PictureInPictureState {
    static let shared = PictureInPictureState()
    private(set) var active = false
    /// Auto-PiP is armed while a player is on screen and playing video.
    var armed = false
    func set(active: Bool) { self.active = active }
}

/// Start Picture in Picture from PigTV's own controls (AVPlayerViewController
/// has no API for it, so the live picture is an AVPlayerLayer view).
@MainActor
final class PiPHandle: ObservableObject {
    /// Asked each time: it reads false until the audio session category is
    /// playback (set at launch, see PigTVAppDelegate). The iPhone simulator
    /// always reports false; the iPad simulator and devices report true.
    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var controller: AVPictureInPictureController?
    func start() { controller?.startPictureInPicture() }
}
#endif

extension View {
    /// iPhone only: full-screen playback is landscape. Nothing on iPad or tvOS.
    @ViewBuilder
    func forcesLandscapeOnPhone() -> some View {
        #if os(iOS)
        onAppear { OrientationLock.landscape() }
            .onDisappear { OrientationLock.release() }
        #else
        self
        #endif
    }
}
