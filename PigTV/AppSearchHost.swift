import SwiftUI

// D-66 (#57): Search from any tab. Every page header (PigPageHeader) carries a magnifier that opens the same side-by-side
// Search / Jump to page (GuideSearchPage) through the app's presentation layer, above every tab. The page has its own
// stack, so a result's programme or channel page is pushed on it and Back returns to the results. Jump to's Show guide
// closes the page and moves the TV Guide there (`AppPresenter.guideJump`). The TV Guide keeps its own Search (its tools
// and header), pushed on its own stack.

private struct PigOpenSearchKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// What the page header's magnifier does: opens Search. Set at the tab container (LibraryView) once signed in; nil
    /// hides the magnifier (before sign-in, and on the TV Guide, whose Search is in its own tools).
    var pigOpenSearch: (@MainActor () -> Void)? {
        get { self[PigOpenSearchKey.self] }
        set { self[PigOpenSearchKey.self] = newValue }
    }
}

/// The page header's magnifier: an icon, "Search" to VoiceOver. Nothing when there is no Search to open.
struct PigHeaderSearchButton: View {
    @Environment(\.pigOpenSearch) private var openSearch

    var body: some View {
        if let openSearch {
            Button { openSearch() } label: {
                Label("Search", systemImage: "magnifyingglass").labelStyle(.iconOnly)
            }
            .pigSecondaryButton()
            .accessibilityIdentifier("page.header.search")
        }
    }
}

/// The app-level Search page (`AppPresentation.search`), with its own stack for the pages a result opens.
struct AppSearchHost: View {
    let app: AppModel
    let browse: BrowseModel
    /// The tab it was opened from ("‹ Sport" on the TV).
    let from: String
    @State private var path: [GuideRoute] = []
    @State private var found = SearchFound()
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Jump to moves the grid; the upright iPhone's Guide is the On now list, with no time to move (as the Guide's own).
    private var canJump: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            GuideSearchPage(model: browse, date: GuideNavigation.rounded(Date()), canJump: canJump, startWithJump: false,
                            openChannel: open, openProgramme: open,
                            showGuide: { date in
                                let presenter = app.presenter
                                presenter.dismiss {
                                    presenter.guideJump = date
                                    app.requestedTab = "guide"
                                }
                            },
                            pushedFrom: from, actions: .app(app, browse: browse))
                .navigationDestination(for: GuideRoute.self) { destination($0) }
                #if os(iOS)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { app.presenter.dismiss() } } }
                #endif
        }
        .presentationBackground { PigPageBackground() }
    }

    private func open(_ channel: GuideChannel) {
        found.keep(channel)
        path.append(.channel(channel.id))
    }

    private func open(_ channel: GuideChannel, _ programme: GuideProgramme) {
        found.keep(channel, programme)
        path.append(.programme(channel: channel.id, start: programme.startTime))
    }

    /// A page's Watch: the search closes, then the player opens (it cannot present over the page).
    private func watch(_ channel: GuideChannel) {
        app.presenter.dismiss { app.beginPlayback(browse.asChannel(channel), origin: "Search") }
    }

    @ViewBuilder
    private func destination(_ route: GuideRoute) -> some View {
        switch route {
        case .programme(let id, let start):
            if case let (channel, programme)? = found.programme(id: id, start: start, in: browse) {
                ProgrammeDetails(model: browse, presenter: app.presenter, channel: channel, programme: programme,
                                 watch: { watch(channel) }, openSchedule: { open(channel) },
                                 openProgramme: { open(channel, $0) }, pushedFrom: "Search")
            } else {
                missingPage
            }
        case .channel(let id):
            if let channel = found.channel(id: id, in: browse) {
                ChannelPageView(model: browse, presenter: app.presenter, channel: channel, watch: { watch(channel) },
                                openProgramme: { open(channel, $0) }, pushedFrom: "Search")
            } else {
                missingPage
            }
        case .search:
            EmptyView()
        }
    }

    private var missingPage: some View {
        DetailPage(pushedFrom: "Search") {
            Text("This is no longer in the guide.").font(DetailType.meta).foregroundStyle(Color.pigSecondary)
        }
    }
}
