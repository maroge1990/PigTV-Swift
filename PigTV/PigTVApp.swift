//
//  PigTVApp.swift
//  PigTV
//
//  Created by Mark Rogers on 13/9/2026.
//

import SwiftUI

@main
struct PigTVApp: App {
    // Applied at the window level so a full-screen player coming and going
    // cannot flip the appearance underneath the guide.
    @AppStorage("pigtv.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}
