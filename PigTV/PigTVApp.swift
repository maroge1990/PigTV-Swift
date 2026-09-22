//
//  PigTVApp.swift
//  PigTV
//
//  Created by Mark Rogers on 13/9/2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct PigTVApp: App {
    // Applied at the window level so a full-screen player coming and going
    // cannot flip the appearance underneath the guide.
    @AppStorage("pigtv.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "settings" {
                    SettingsTestScreen()
                } else if ProcessInfo.processInfo.environment["PIGTV_SYNTHETIC_TESTS"] == "1" {
                    Color.clear
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                // A single SwiftUI-owned appearance for the whole hierarchy so
                // background and text never disagree (the window-level override
                // left them out of step — black text on a black surface). The
                // id forces a clean rebuild when the choice changes so it
                // applies immediately rather than only after a relaunch.
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .id(appearance)
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
#endif
