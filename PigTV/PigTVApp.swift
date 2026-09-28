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
            // Build 32: the window itself is the page colour (PageBackdrop.swift).
            root.background(WindowBackdrop().accessibilityHidden(true))
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "settings" {
            SettingsTestScreen()
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "guide" {
            GuideTestScreen()
        } else if ["home", "home-empty"].contains(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "") {
            HomeTestScreen(firstRun: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "home-empty")
        } else if ["sport", "sport-empty"].contains(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "") {
            HomeTestScreen(firstRun: false, initialTab: "sport",
                           noSport: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "sport-empty")
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "topshelf-cards" {
            TopShelfCardsTestScreen()
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
// C-I (build 30): PIGTV_UI_TEST_SCREEN=sport opens the Sport tab on the same
// data (NFL, AFL, F1 and NRL events); sport-empty shows its empty state.
private struct HomeTestScreen: View {
    let firstRun: Bool
    var initialTab = "home"
    var noSport = false
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model, initialTab: initialTab)
            #if os(tvOS)
            .buttonStyle(TVActionStyle())
            #endif
            .task {
                model.injectHomeFixture(firstRun: firstRun)
                if noSport { model.browse?.sport.setFixture([]) }
            }
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
// onboarding | sport-event (an upcoming event's page) | sport-channels (the
// channel picker), with PIGTV_UI_TEST_APPEARANCE=light|dark.
private struct DesignTestScreen: View {
    static let screens: Set<String> = ["programme", "programme-later", "record", "schedule", "channel", "recording",
                                       "search", "jump", "unreachable", "onboarding", "sport-event", "sport-channels"]
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
        case "sport-event":
            if let event = browse.sport.soon.first {
                SportEventDetails(event: event, app: app, browse: browse, play: { _ in })
            }
        case "sport-channels":
            if let event = browse.sport.live.first {
                SportChannelPicker(event: event, app: app, browse: browse, clock: now, play: { $0() })
            }
        case "unreachable":
            UnreachableView(model: app, message: "This device cannot reach the server. Check that you are on the home network or that Tailscale is connected.")
        default:
            OnboardingView(model: app)
        }
    }
}

// Build 32: PIGTV_UI_TEST_SCREEN=topshelf-cards renders the Home fixture's
// Top Shelf cards through the real export (so it also writes the snapshot
// and cards into the simulator's App Group, for checking the Top Shelf) and
// shows the first four "on now" cards at 1x size (852×480, the focused size).
private struct TopShelfCardsTestScreen: View {
    @StateObject private var app = AppModel()
    @State private var cards: [(String, UIImage)] = []
    @State private var summary = "Rendering…"

    var body: some View {
        ZStack {
            Color(white: 0.2).ignoresSafeArea()
            VStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.fixed(852), spacing: 24), GridItem(.fixed(852), spacing: 24)], spacing: 24) {
                    ForEach(cards, id: \.0) { card in
                        Image(uiImage: card.1).resizable().frame(width: 852, height: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text(summary).font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("topshelf.cards")
            }
        }
        .task {
            app.injectHomeFixture()
            guard let browse = app.browse else { return }
            browse.exportTopShelf()
            await TopShelfCardExport.finish()
            guard let snapshot = TopShelfCardExport.lastRendered else { summary = "No cards"; return }
            let now = Date()
            cards = snapshot.channels.prefix(4).compactMap { entry in
                guard let card = entry.card(at: now), let url = TopShelfCards.fileURL(card.file, in: AppGroupStorage.containerURL),
                      let image = UIImage(contentsOfFile: url.path) else { return nil }
                return (card.file, image)
            }
            let count = TopShelfCards.renderedCount(for: snapshot, in: AppGroupStorage.containerURL)
            let pixels = cards.first.map { "\(Int($0.1.size.width * $0.1.scale))×\(Int($0.1.size.height * $0.1.scale)) px" } ?? "-"
            summary = "\(count) cards rendered · \(pixels) each"
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
