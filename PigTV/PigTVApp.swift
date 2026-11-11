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

    #if os(iOS)
    // Orientation lock for full-screen playback on iPhone (PlaybackWindow.swift).
    @UIApplicationDelegateAdaptor(PigTVAppDelegate.self) private var appDelegate
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
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "settings-sport" {
            SportSettingsTestScreen()
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "guide" {
            GuideTestScreen()
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "home" {
            HomeTestScreen()
        } else if ["tab-guide", "tab-recordings"].contains(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "") {
            // The library fixture inside the tab bar, opened on that tab (design checks).
            HomeTestScreen(initialTab: String((ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "").dropFirst(4)))
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "splash" {
            BrandSplashView()
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "topshelf-cards" {
            TopShelfCardsTestScreen()
        } else if (ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] ?? "").hasPrefix("player") {
            PlayerTestScreen()
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "front" {
            SportFrontTestScreen()
        } else if let screen = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"],
                  DesignTestScreen.screens.contains(screen) {
            DesignTestScreen(screen: screen)
        } else if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_LAUNCH"] == "clear" {
            Color.clear.onAppear { LaunchFixture.clear() }
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
            .buttonStyle(PigSecondaryButtonStyle())
            #endif
            .preferredColorScheme(fixtureScheme)
    }
}

// C-U (#200): Settings › Sport offline, PIGTV_UI_TEST_SCREEN=settings-sport: Settings in the tab bar, signed in, with two
// followed sports, a league suggestion and a "Record every game" (SportFollowFixtures).
private struct SportSettingsTestScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model, initialTab: "settings")
            #if os(tvOS)
            .buttonStyle(PigSecondaryButtonStyle())
            #endif
            .task {
                model.injectHomeFixture(sportFollows: true)
                SportFollowFixtures.apply(to: model.browse?.sportFollows)
                PageStateFixtures.apply(model)
            }
            .preferredColorScheme(fixtureScheme)
    }
}

// Offline guide with synthetic data, for iterating the grid layout/scroll.
private struct GuideTestScreen: View {
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model, initialTab: "guide")
            .task {
                model.injectGuideFixture()
                PageStateFixtures.apply(model)
            }
            // PIGTV_UI_TEST_APPEARANCE=light|dark: the tvOS simulator cannot
            // switch its own appearance (simctl ui appearance is unsupported).
            .preferredColorScheme(fixtureScheme)
    }
}

// C-R (#21, D-39, Apple 89): the app on the Home fixture with the server's Sport front page, opening where the app opens
// (Sport), on the server's own answer given base64 in PIGTV_UI_TEST_FRONT_JSON (PigTVTests/Fixtures/sport-front-0381.json).
// C-S (Apple 90): with PIGTV_UI_TEST_CRICKET_JSON (the Cricket page's answer, base64) the server also has the Cricket
// page, and a Watch reaches the real player, whose resolve goes to a non-routable TEST-NET address (the tuning card).
// D-43 (Apple 99): with PIGTV_UI_TEST_PAGES_JSON (PigTVTests/Fixtures/sport-pages-d43.json, base64: `front`, `leagues`,
// `events`, `cricket`) every sport page has its server page: the C-T leagues, the C-V events and two cricket leagues, the
// catalogue's labels and the followed names; PIGTV_UI_TEST_SPOILERS=1 turns spoiler-free on.
private struct SportFrontTestScreen: View {
    static let cricket = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_CRICKET_JSON"].flatMap { Data(base64Encoded: $0) }
    static let pages = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_PAGES_JSON"].flatMap { Data(base64Encoded: $0) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    @StateObject private var model = AppModel()

    /// One part of the pages fixture, decoded.
    private static func part<T: Decodable>(_ value: Any?) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    var body: some View {
        LibraryView(model: model)
            #if os(tvOS)
            .buttonStyle(PigSecondaryButtonStyle())
            #endif
            .preferredColorScheme(fixtureScheme)
            .task {
                if let pages = Self.pages { injectPages(pages); return }
                model.injectHomeFixture(sportFront: true, cricket: Self.cricket != nil)
                guard let browse = model.browse,
                      let base64 = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_FRONT_JSON"],
                      let data = Data(base64Encoded: base64),
                      let front = try? JSONDecoder().decode(SportFront.self, from: data) else { return }
                browse.sportFront.setFixture(front)
                // D-43: PIGTV_UI_TEST_FRONT_F1=1 gives the Motorsport page the F1 fixture's weekend to embed.
                browse.f1Page.setFixture(ProcessInfo.processInfo.environment["PIGTV_UI_TEST_FRONT_F1"] == "1"
                                         ? F1PageFixtures.page(live: false, guide: browse.guide) : F1Page(available: false))
                browse.nflPage.setFixture(NFLPage(available: false))
                if let cricket = Self.cricket, let page = try? JSONDecoder().decode(CricketPage.self, from: cricket) {
                    browse.cricketPage.setFixture(page)
                    browse.f1Page.setFixture(F1Page(available: false), preferences: SportPagePreferences(
                        sports: ["Cricket"], teams: ["Cricket": ["Australia"]]))
                    if let address = try? ServerAddress("http://192.0.2.1:3000") {
                        model.configureClientForTesting(APIClient(address: address, token: "fixture", info: model.serverInfo))
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(get: { Self.cricket != nil && model.playerPresented },
                                                  set: { model.playerPresented = $0 })) {
                PlayerHost(app: model).tint(Color("AccentColor"))
            }
    }

    private func injectPages(_ pages: [String: Any]) {
        let leagues = pages["leagues"] as? [String: Any] ?? [:]
        let events = pages["events"] as? [String: Any] ?? [:]
        // #280: PIGTV_UI_TEST_SPORT_FOLLOWS=1: the server has per-account follows (C-U), so the empty page offers Settings › Sport.
        model.injectHomeFixture(sportFront: true, cricket: pages["cricket"] != nil,
                                sportFollows: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SPORT_FOLLOWS"] == "1",
                                pageLeagues: Array(leagues.keys).sorted(), events: !events.isEmpty)
        guard let browse = model.browse, let front: SportFront = Self.part(pages["front"]) else { return }
        browse.sportFront.setFixture(front)
        browse.sportFront.setLabels(["F1": "Formula 1", "NASCAR": "NASCAR Cup", "Cricket": "International (men)",
                                     "Sheffield Shield": "Sheffield Shield", "BBL": "BBL", "EPL": "Premier League"])
        for (league, value) in leagues { if let page: LeaguePage = Self.part(value) { browse.leaguePages.setFixture(page, league: league) } }
        for (league, value) in events { if let page: SportEventsPage = Self.part(value) { browse.eventPages.setFixture(page, league: league) } }
        if let cricket: CricketPage = Self.part(pages["cricket"]) { browse.cricketPage.setFixture(cricket) }
        // #243 (Apple 168): the NFL's page (C-Q) from PIGTV_UI_TEST_NFL_JSON (base64), its followed team from
        // PIGTV_UI_TEST_NFL_FOLLOW; the retired NFLPageView's tests run on the D-43 page.
        let environment = ProcessInfo.processInfo.environment
        if let base64 = environment["PIGTV_UI_TEST_NFL_JSON"], let data = Data(base64Encoded: base64),
           let nfl = try? JSONDecoder().decode(NFLPage.self, from: data) {
            browse.nflPage.setFixture(nfl)
        } else {
            browse.nflPage.setFixture(NFLPage(available: false))
        }
        var teams: [String: [String]] = [:]
        for follow in front.follows { teams[follow.league, default: []].append(follow.name) }
        // PIGTV_UI_TEST_FRONT_F1=1: the F1 fixture's weekend; =live: the same weekend with its race on now.
        let f1Mode = environment["PIGTV_UI_TEST_FRONT_F1"]
        let f1 = f1Mode == "1" || f1Mode == "live"
            ? F1PageFixtures.page(live: f1Mode == "live", guide: browse.guide) : F1Page(available: false)
        browse.f1Page.setFixture(f1, preferences: SportPagePreferences(
            spoilerFree: environment["PIGTV_UI_TEST_SPOILERS"] == "1",
            nflFollowing: environment["PIGTV_UI_TEST_NFL_FOLLOW"],
            sports: front.sports.map(\.league), teams: teams))
        Self.applyStates(browse, front: front, leagues: Array(leagues.keys) + Array(events.keys))
    }

    /// #280: the pages' states for the simulator and UI tests. PIGTV_UI_TEST_SPORT_STATE=loading|empty|failed|stale puts
    /// the front page's answer, and so the front page and every sport page, in that state; PIGTV_UI_TEST_LEAGUE_STATE=
    /// loading|empty|failed|unavailable|stale puts every league's own page (Formula 1, the NFL, cricket, the C-T leagues
    /// and the C-V events) in it, the front page's answer as given.
    static func applyStates(_ browse: BrowseModel, front: SportFront, leagues: [String]) {
        let environment = ProcessInfo.processInfo.environment
        if let state = environment["PIGTV_UI_TEST_SPORT_STATE"] {
            browse.sportFront.setFixtureState(state, front: front)
        }
        guard let state = environment["PIGTV_UI_TEST_LEAGUE_STATE"] else { return }
        browse.f1Page.setFixtureState(state)
        browse.nflPage.setFixtureState(state)
        browse.cricketPage.setFixtureState(state)
        let named = leagues + [environment["PIGTV_UI_TEST_OPEN_LEAGUE"]].compactMap { $0 }
        for league in Set(named) {
            browse.leaguePages.setFixtureState(state, league: league)
            browse.eventPages.setFixtureState(state, league: league)
        }
    }
}

// The offline library (build 28): PIGTV_UI_TEST_SCREEN=home (favourites, sport, recordings, logos), on the app's
// opening tab (Sport; #216 retired Home, the name stays). The Sport tab is the front page on the server's own answer: PIGTV_UI_TEST_FRONT_JSON (base64) when given, else the source tree's
// PigTVTests/Fixtures/sport-front-0381.json (the simulator reads the Mac's files; elsewhere the page shows its error state).
private struct HomeTestScreen: View {
    var initialTab: String? = nil
    static let presentsPlayer = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_PLAY"] == "1"
    static let front: SportFront? = {
        let data = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_FRONT_JSON"].flatMap { Data(base64Encoded: $0) }
            ?? (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("PigTVTests/Fixtures/sport-front-0381.json")))
        return data.flatMap { try? JSONDecoder().decode(SportFront.self, from: $0) }
    }()
    @StateObject private var model = AppModel()
    var body: some View {
        LibraryView(model: model, initialTab: initialTab)
            #if os(tvOS)
            .buttonStyle(PigSecondaryButtonStyle())
            #endif
            // The Undo toast, as ContentView shows it over the tabs (Apple 122).
            .overlay(alignment: .bottom) { UndoToast(presenter: model.presenter) }
            .task {
                model.injectHomeFixture()
                if let front = Self.front { model.browse?.sportFront.setFixture(front) }
                if initialTab == "recordings", let browse = model.browse { GuideFixtures.addSchedules(to: browse) }
                PageStateFixtures.apply(model)
                // PIGTV_UI_TEST_DASHBOARD_PLAY=1: a play reaches the real player, whose resolve goes to a
                // non-routable TEST-NET address, so it stays on the tuning card (as player-tuning does).
                if Self.presentsPlayer, let address = try? ServerAddress("http://192.0.2.1:3000") {
                    model.configureClientForTesting(APIClient(address: address, token: "fixture", info: model.serverInfo))
                }
                // #179: PIGTV_UI_TEST_OPEN_URL="<seconds>|<pigtv:// link>" delivers that link as a Top Shelf card does
                // (ContentView's onOpenURL -> AppModel.open), after the test has opened a page (OutsidePlayUITests).
                if let spec = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_OPEN_URL"],
                   let bar = spec.firstIndex(of: "|"), let seconds = Double(spec[..<bar]),
                   let url = URL(string: String(spec[spec.index(after: bar)...])) {
                    try? await Task.sleep(for: .seconds(seconds))
                    model.open(url)
                }
            }
            .fullScreenCover(isPresented: Binding(get: { Self.presentsPlayer && model.playerPresented },
                                                  set: { model.playerPresented = $0 })) {
                PlayerHost(app: model).tint(Color("AccentColor"))
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
            model.playback?.applyReviewState(screen ?? "")
        }
    }
}

// One secondary screen on the Home fixture's data, for design checks
// (build 28 consistency pass): PIGTV_UI_TEST_SCREEN=programme | programme-later
// | record | schedule | channel | recording | search | jump | unreachable |
// onboarding | sport-event (an upcoming event's page) | sport-channels (the
// channel picker), with PIGTV_UI_TEST_APPEARANCE=light|dark.
private struct DesignTestScreen: View {
    static let screens: Set<String> = ["programme", "programme-later", "record", "record-change", "record-sport", "schedule", "channel", "recording",
                                       "search", "jump", "unreachable", "onboarding", "sport-event", "sport-channels", "recording-player", "recordings", "recording-game", "pairing", "recording-loading", "recording-preparing", "recording-error", "recording-resume", "signin-server"]
    let screen: String
    @StateObject private var app = AppModel()
    @State private var ready = false

    var body: some View {
        Group {
            if ready, let browse = app.browse { content(browse) } else { Color.clear }
        }
        #if os(tvOS)
        .buttonStyle(PigSecondaryButtonStyle())
        #endif
        .tint(Color("AccentColor"))
        .preferredColorScheme(fixtureScheme)
        // The app's presentation layer, as LibraryView hosts it (Record opens through it), and the Undo toast as
        // ContentView shows it.
        .appPresentations(app.presenter, app: app, browse: app.browse)
        .overlay(alignment: .bottom) { UndoToast(presenter: app.presenter) }
        .task {
            // The record pages with the server's per-account follows (C-U).
            app.injectHomeFixture(sportFollows: ["record", "record-change", "record-sport"].contains(screen))
            app.serverText = "http://pigtv.local:3000"
            if screen == "pairing" { app.injectPairingReview() }
            // D-44 batch 6: Sign in's step 1 (the server), as after "Use a different server".
            if screen == "signin-server" { app.signInAtServer = true }
            if let browse = app.browse { GuideFixtures.addSchedules(to: browse) }
            PageStateFixtures.apply(app)
            ready = true
            // #280: PIGTV_UI_TEST_ACTION_ERROR=1: a page's action did not work (after it has appeared, which clears it).
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_ACTION_ERROR"] == "1", let browse = app.browse {
                try? await Task.sleep(for: .seconds(1))
                browse.actionError = PageWords.ruleAddFailed
            }
            // Codex 5a round 1: PIGTV_UI_TEST_RECORD_FLIP=recording | gone changes the scheduled programme's row 4 s after
            // the page opens (it starts recording, or it is gone), as a refreshed list would.
            if let flip = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_RECORD_FLIP"], let browse = app.browse {
                try? await Task.sleep(for: .seconds(4))
                if flip == "gone" {
                    browse.schedules.removeAll { $0.id == 90 }
                } else if let index = browse.schedules.firstIndex(where: { $0.id == 90 }),
                          let data = try? JSONEncoder().encode(GuideFixtures.ScheduleRow(browse.schedules[index], status: flip)),
                          let row = try? JSONDecoder().decode(ScheduledRecording.self, from: data) {
                    browse.schedules[index] = row
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ browse: BrowseModel) -> some View {
        if ["search", "jump"].contains(screen) {
            // Before the others: with PIGTV_UI_TEST_GUIDE_STATE the guide may have no channels (#280).
            GuideSearchPage(model: browse, date: Date(), canJump: true, startWithJump: screen == "jump",
                            openChannel: { _ in }, openProgramme: { _, _ in }, showGuide: { _ in })
        } else {
            screenContent(browse)
        }
    }

    @ViewBuilder
    private func screenContent(_ browse: BrowseModel) -> some View {
        let channel = browse.guide[2]
        let now = Date()
        let live = channel.programmes.first { $0.isLive(at: now) } ?? channel.programmes[0]
        let later = GuideFixtures.scheduledProgramme(in: browse.guide)
        switch screen {
        case "programme", "record":
            ProgrammeDetails(model: browse, presenter: app.presenter, channel: channel, programme: live, watch: {}, openSchedule: {},
                             openProgramme: { _ in })
        case "programme-later", "record-change":
            ProgrammeDetails(model: browse, presenter: app.presenter, channel: later.channel, programme: later.programme, watch: {},
                             openSchedule: {}, openProgramme: { _ in })
        case "schedule":
            ChannelPageView(model: browse, presenter: app.presenter, channel: channel, watch: {}, openProgramme: { _ in })
        case "channel":
            ChannelPageView(model: browse, presenter: app.presenter, channel: channel, watch: {}, openProgramme: { _ in })
        case "recordings":
            RecordingsView(model: browse, presenter: app.presenter, openGuide: { app.requestedTab = "guide" })
        case "recording-player", "recording-loading", "recording-preparing", "recording-error", "recording-resume":
            RecordingPlayerScreen(recording: browse.recordings[1], client: browse.client)
        case "recording":
            RecordingView(model: browse, presenter: app.presenter, original: browse.recordings[1])
        case "recording-game":
            // Apple 121: a game recording, drawn with its two teams.
            if let game = browse.recordings.first(where: { $0.id == 24 }) { RecordingView(model: browse, presenter: app.presenter, original: game) }
        case "record-sport":
            // Apple 114: the record page for a game on three channels, with the game's id (it stops when the game ends).
            Color.clear.task {
                guard let event = browse.sport.soon.first(where: { $0.channels.count > 2 }),
                      var request = browse.recordRequest(event: event) else { return }
                request.gameId = "fixture:\(event.id)"
                app.presenter.present(.record(request))
            }
        case "sport-event":
            if let event = browse.sport.soon.first {
                SportEventDetails(event: event, app: app, browse: browse, play: { _ in })
            }
        case "sport-channels":
            if let event = browse.sport.live.first {
                SportChannelPicker(event: event, app: app, browse: browse, clock: now, play: { $0() })
            }
        case "unreachable":
            UnreachableView(model: app, message: UserMessage.unreachable)
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
            VStack(spacing: PigSpacing.m) {
                LazyVGrid(columns: [GridItem(.fixed(852), spacing: PigSpacing.l), GridItem(.fixed(852), spacing: PigSpacing.l)], spacing: PigSpacing.l) {
                    ForEach(cards, id: \.0) { card in
                        Image(uiImage: card.1).resizable().frame(width: 852, height: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text(summary).font(.system(size: PigType.body)).foregroundStyle(.white.opacity(0.8))
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

/// #280: the other pages' states for the simulator and UI tests, in the style of PIGTV_UI_TEST_SPORT_STATE:
/// PIGTV_UI_TEST_GUIDE_STATE=loading|empty|failed|stale (the TV Guide, and Search, which looks through it),
/// PIGTV_UI_TEST_RECORDINGS_STATE=loading|empty|failed|stale (Recordings and Scheduled),
/// PIGTV_UI_TEST_SETTINGS_SPORT_STATE=loading|empty|failed|stale (Settings › Sport) and
/// PIGTV_UI_TEST_SIGNIN_ERROR=server|password|pairing|saved (Sign in's inline note), on the fixtures that show them.
enum PageStateFixtures {
    static func apply(_ app: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        // The Sport front in its state inside the tab bar (the `front` screen applies it itself).
        if let state = environment["PIGTV_UI_TEST_SPORT_STATE"], environment["PIGTV_UI_TEST_SCREEN"] != "front", let browse = app.browse {
            browse.sportFront.setFixtureState(state, front: browse.sportFront.front)
        }
        if let state = environment["PIGTV_UI_TEST_GUIDE_STATE"] { app.browse?.setGuideFixtureState(state) }
        if let state = environment["PIGTV_UI_TEST_RECORDINGS_STATE"] { app.browse?.setRecordingsFixtureState(state) }
        if let state = environment["PIGTV_UI_TEST_SETTINGS_SPORT_STATE"] { app.browse?.sportFollows.setFixtureState(state) }
        if let kind = environment["PIGTV_UI_TEST_SIGNIN_ERROR"] { app.injectSignInError(kind) }
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
