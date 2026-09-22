//
//  PigTVApp.swift
//  PigTV
//
//  Created by Mark Rogers on 13/9/2026.
//

import SwiftUI

@main
struct PigTVApp: App {
    // Appearance is owned by ContentView (a View), where an @AppStorage change
    // re-renders immediately; the Settings test screen sets its own.
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "settings" {
                SettingsTestScreen()
            } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "guide" {
                GuideTestScreen()
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
        LibraryView(model: model)
            .task { model.injectGuideFixture() }
    }
}
#endif
