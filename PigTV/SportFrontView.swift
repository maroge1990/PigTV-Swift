import SwiftUI

// C-R (#21, D-39): the Sport tab. The Apple TV and the iPad draw `SportFrontTVPage` (D-43, D-44: the iPad follows the
// TV), the iPhone `SportFrontPhonePage` (D-44, R5-Front-iPhone); a sport's page is pushed on the tab's stack
// (`SportRoute`). Every play started here is recorded with origin "sport-front".

struct SportFrontView: View {
    static let origin = "sport-front"
    #if DEBUG
    @MainActor static var openedTestSport = false
    #endif
    let app: AppModel
    let browse: BrowseModel
    /// D-43: the sport pages pushed from the front page (a rail header, "Also in your sports", a follow). #214: the
    /// session's, so the tab bar can return it to the front page.
    @ObservedObject private var navigation: SportNavigation
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(app: AppModel, browse: BrowseModel) {
        self.app = app
        self.browse = browse
        _navigation = ObservedObject(wrappedValue: browse.sportNavigation)
    }

    var body: some View {
        #if os(iOS)
        // D-44 (Apple 142): the sport pages stack their panels on a screen narrower than `SportColumns.narrowBelow`
        // (an iPad in portrait); the width is the tab's, never the content's.
        GeometryReader { proxy in
            stack.environment(\.sportNarrow, proxy.size.width < SportColumns.narrowBelow)
        }
        #else
        stack
        #endif
    }

    private var stack: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                #if os(tvOS)
                SportFrontTVPage(app: app, browse: browse) { sport in navigation.path.append(SportRoute(sport: sport)) }
                #else
                // D-44: the iPad follows the Apple TV page; the iPhone has its own (R5-Front-iPhone).
                if sizeClass == .regular {
                    SportFrontTVPage(app: app, browse: browse) { sport in navigation.path.append(SportRoute(sport: sport)) }
                } else {
                    SportFrontPhonePage(app: app, browse: browse) { sport in navigation.path.append(SportRoute(sport: sport)) }
                }
                #endif
            }
            .pigPageBackdrop()
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: SportRoute.self) { route in
                #if os(iOS)
                // D-44: the iPhone's sport pages follow its front page (R5-*-iPhone), the extra content a page of its own.
                if sizeClass != .regular {
                    if let league = route.league {
                        SportPhoneLeaguePage(app: app, browse: browse, sport: route.sport, league: league)
                    } else {
                        SportPhonePage(app: app, browse: browse, sport: route.sport) { league in
                            navigation.path.append(SportRoute(sport: route.sport, league: league))
                        }
                    }
                } else {
                    SportPageView(app: app, browse: browse, sport: route.sport)
                }
                #else
                SportPageView(app: app, browse: browse, sport: route.sport)
                #endif
            }
        }
        // The event page and channel picker belong to the screen (SportPresenter), with the plays' origin.
        .sportPages(app: app, browse: browse, clock: Date(), origin: Self.origin)
        #if DEBUG
        // UI tests (Apple 99): PIGTV_UI_TEST_OPEN_SPORT=<sport> opens that sport's page once the front page is up, once
        // per launch (#214: the task runs again each time the tab reappears, and coming back to Sport shows the front page).
        .task {
            guard let sport = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_OPEN_SPORT"], navigation.path.isEmpty,
                  !SportFrontView.openedTestSport else { return }
            SportFrontView.openedTestSport = true
            try? await Task.sleep(for: .milliseconds(800))
            navigation.path.append(SportRoute(sport: sport))
            // D-44 (Apple 142): PIGTV_UI_TEST_OPEN_LEAGUE=<league> also pushes that league's iPhone page (#177).
            if let league = ProcessInfo.processInfo.environment["PIGTV_UI_TEST_OPEN_LEAGUE"] {
                try? await Task.sleep(for: .milliseconds(600))
                navigation.path.append(SportRoute(sport: sport, league: league))
            }
        }
        #endif
    }
}

/// A team's badge: its logo (a logo-cache path, as channel logos, through the same cache) or a monogram disc in the
/// league's colour: without a logo, while it loads, and when it fails (C-R, D-39), never an empty disc.
/// `disc` (#205): a page's own fallback disc (the NFL page's team colour and abbreviation) in place of the monogram.
struct SportBadge: View {
    let name: String
    let logo: String?
    let league: String
    let client: APIClient?
    var size: CGFloat
    var disc: (text: String, color: String?)? = nil
    @State private var decoded: DecodedLogo?

    var body: some View {
        Group {
            if SportFrontText.badgeShowsLogo(logo: logo, decoded: decoded != nil), let decoded {
                Image(uiImage: decoded.image).resizable().scaledToFit()
                    .frame(width: size, height: size)
            } else if let disc {
                Text(disc.text).font(.system(size: size * 0.34, weight: .heavy)).foregroundStyle(Color.pigOnStatus)
                    .minimumScaleFactor(0.6)
                    .frame(width: size, height: size)
                    .background(Color(teamHex: disc.color) ?? .gray, in: Circle())
            } else {
                Text(SportFrontText.monogram(name)).font(.system(size: size * 0.38, weight: .heavy)).foregroundStyle(Color.pigOnStatus)
                    .minimumScaleFactor(0.6)
                    .frame(width: size, height: size)
                    .background(Color(teamHex: SportFrontText.leagueColor(league)) ?? .gray, in: Circle())
            }
        }
        .accessibilityHidden(true)
        .task(id: logo) {
            decoded = nil
            guard let logo, let client, let key = client.artworkKey(logo) else { return }
            let result = await ChannelArtwork.decodedLogo(key: key, logo: logo, client: client)
            guard !Task.isCancelled else { return }
            decoded = result
        }
    }
}
