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
            } else if (ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "").hasPrefix("player") {
                PlayerTestScreen()
            } else if let screen = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"],
                      DesignTestScreen.screens.contains(screen) {
                DesignTestScreen(screen: screen)
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
            .preferredColorScheme(fixtureScheme)
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

// The player over the Home fixture's data (build 29): PIGTV_UI_TEST_SCREEN=
// player (with PIGTV_UI_TEST_MEDIA=<path to a local movie>) | player-channels
// (the channel panel open) | player-tuning (no media: the tuning card).
private struct PlayerTestScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        ZStack {
            PigPageBackground()
            if model.playerPresented { PlayerHost(app: model) }
        }
        .tint(Color("AccentColor"))
        .preferredColorScheme(fixtureScheme)
        .task {
            let media = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_MEDIA"].map { URL(fileURLWithPath: $0) }
            let screen = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"]
            model.injectPlayerFixture(media: screen == "player-tuning" ? nil : media)
        }
    }
}

// One secondary screen on the Home fixture's data, for design checks
// (build 28 consistency pass): PIGTV_UI_TEST_SCREEN=programme | programme-later
// | record | schedule | channel | recording | search | jump | unreachable |
// onboarding, with PIGTV_UI_TEST_APPEARANCE=light|dark.
private struct DesignTestScreen: View {
    static let screens: Set<String> = ["programme", "programme-later", "record", "schedule", "channel", "recording",
                                       "search", "jump", "unreachable", "onboarding"]
    let screen: String
    @StateObject private var app = AppModel()
    @State private var ready = false
    @State private var search = "sky"
    @State private var programmeSearch = "live"
    @State private var jumpDate = Date()

    var body: some View {
        Group {
            if ready, let browse = app.browse { content(browse) } else { Color.clear }
        }
        #if os(tvOS)
        .buttonStyle(TVActionStyle())
        #endif
        .tint(Color("AccentColor"))
        .preferredColorScheme(fixtureScheme)
        .task {
            app.injectHomeFixture()
            app.serverText = "http://pigtv.local:3000"
            if let browse = app.browse { GuideFixtures.addSchedules(to: browse) }
            ready = true
        }
    }

    @ViewBuilder
    private func content(_ browse: BrowseModel) -> some View {
        let channel = browse.guide[2]
        let now = Date()
        let live = channel.programmes.first { $0.isLive(at: now) } ?? channel.programmes[0]
        let later = GuideFixtures.scheduledProgramme(in: browse.guide)
        switch screen {
        case "programme", "record":
            ProgrammeDetails(model: browse, channel: channel, programme: live, watch: {}, openSchedule: {})
        case "programme-later":
            ProgrammeDetails(model: browse, channel: later.channel, programme: later.programme, watch: {}, openSchedule: {})
        case "schedule":
            ChannelScheduleView(model: browse, channel: channel, logo: browse.logo(for: channel), watch: {})
        case "channel":
            ChannelDetails(channel: browse.asChannel(channel), browse: browse, watch: {}, openSchedule: {})
        case "recording":
            RecordingDetails(model: browse, original: browse.recordings[1])
        case "search":
            GuideSearchSheet(model: browse, search: $search, programmeSearch: $programmeSearch,
                             done: {}, choose: { _, _ in }, refresh: {})
        case "jump":
            GuideJumpSheet(date: $jumpDate, show: { _ in }, cancel: {})
        case "unreachable":
            UnreachableView(model: app, message: "This device cannot reach the server. Check that you are on the home network or that Tailscale is connected.")
        default:
            OnboardingView(model: app)
        }
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
