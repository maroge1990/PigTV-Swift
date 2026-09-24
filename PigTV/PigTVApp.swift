//
//  PigTVApp.swift
//  PigTV
//
//  Created by Mark Rogers on 13/9/2026.
//

import SwiftUI
#if os(tvOS)
import AVKit
#endif

@main
struct PigTVApp: App {
    #if os(tvOS)
    // AVKit must be loaded on tvOS even though no AVKit player is used any more:
    // `UIWindow.avDisplayManager` (HDR / frame-rate switching in PlayerLayerView)
    // and `AVPlayerItem.externalMetadata` are AVKit categories. After build 21
    // removed the last AVKit player, nothing referenced AVKit, so it was never
    // loaded and the first channel start crashed with "unrecognized selector"
    // (test block 1.9). The app target links AVKit explicitly for tvOS
    // (OTHER_LDFLAGS[sdk=appletv*] = -framework AVKit); a class reference alone
    // was stripped. A test asserts the categories exist.
    init() {
        _ = AVPlayerViewController.self
        TabBarStyle.apply()
    }
    #endif

    // Appearance is owned by ContentView (a View), where an @AppStorage change
    // re-renders immediately; the Settings test screen sets its own.
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "settings" {
                SettingsTestScreen()
            } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "guide" {
                GuideTestScreen()
            } else if ["home", "home-empty"].contains(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "") {
                HomeTestScreen(firstRun: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "home-empty")
            } else if ProcessInfo.processInfo.environment["PIGTV_SYNTHETIC_TESTS"] == "1" {
                Color.clear
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

#if DEBUG
// Isolated UI fixture: no restoration, authentication or server requests.
private struct SettingsTestScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model)
            #if os(tvOS)
            .buttonStyle(TVActionStyle())
            #endif
    }
}

// Offline guide with synthetic data, for iterating the grid layout/scroll.
private struct GuideTestScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model, initialTab: "guide")
            .task { model.injectGuideFixture() }
            // PIGTV_UI_TEST_APPEARANCE=light|dark: the tvOS simulator cannot
            // switch its own appearance (simctl ui appearance is unsupported).
            .preferredColorScheme(fixtureScheme)
    }
}

// Offline Home (build 28): PIGTV_UI_TEST_SCREEN=home (history, favourites,
// sport, recordings, logos) or home-empty (the first-run state).
private struct HomeTestScreen: View {
    let firstRun: Bool
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model)
            #if os(tvOS)
            .buttonStyle(TVActionStyle())
            #endif
            .task { model.injectHomeFixture(firstRun: firstRun) }
            .preferredColorScheme(fixtureScheme)
    }
}

private var fixtureScheme: ColorScheme? {
    switch ProcessInfo.processInfo.environment["PIGTV_UI_TEST_APPEARANCE"] {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
}
#endif
