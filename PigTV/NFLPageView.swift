import SwiftUI

// C-Q (#21): the NFL page, opened from the Sport tab when the server advertises `sportPageNfl`. The approved mock-up
// ("PigTV Sport mock-ups": NFL · Apple TV; DESIGN.md › Sport pages): a header with Following and the spoiler-free
// chip; the weeks in order (last week, then this one) as chips, opening on the current one; each week's games as cards
// (teams, records, score or kick-off, the clock and down and distance while live, the channel once the guide carries
// it) and the teams on a bye; on the right the followed team's card (next and last game, Watch, Record every game) above
// the standings, by Division (the followed team's first), Conference (seeds) or Overall. Spoiler-free hides scores,
// results, the live situation, records, seeds and streaks. No section tabs and no season calendar.
//
// A game is a C-I event (`NFLPageText.event`): Watch, "Watch when it starts" and Record are the Sport tab's own, on
// each channel's airing times (#20). Team discs (colour and abbreviation) stand in for logos, as in the mock-up.

private enum NFLMetrics {
    #if os(tvOS)
    static let title: Font = .system(size: 46, weight: .heavy)
    static let cardTitle: Font = .system(size: 26, weight: .bold)
    static let team: Font = .system(size: 23, weight: .semibold)
    static let score: Font = .system(size: 26, weight: .heavy)
    static let detail: Font = .system(size: 18)
    static let chip: Font = .system(size: 22, weight: .medium)
    static let tableName: Font = .system(size: 20, weight: .semibold)
    static let tableDetail: Font = .system(size: 18)
    static let spacing: CGFloat = 24
    static let columnGap: CGFloat = 40
    static let sideWidth: CGFloat = 640
    static let gameWidth: CGFloat = 520
    static let disc: CGFloat = 40
    static let radius: CGFloat = 22
    static let cardPadding = EdgeInsets(top: 16, leading: 22, bottom: 16, trailing: 22)
    #else
    static let title: Font = .largeTitle.bold()
    static let cardTitle: Font = .title3.bold()
    static let team: Font = .headline
    static let score: Font = .title3.bold()
    static let detail: Font = .subheadline
    static let chip: Font = .subheadline
    static let tableName: Font = .callout.weight(.semibold)
    static let tableDetail: Font = .footnote
    static let spacing: CGFloat = 18
    static let columnGap: CGFloat = 24
    static let sideWidth: CGFloat = 420
    static let gameWidth: CGFloat = 340
    static let disc: CGFloat = 30
    static let radius: CGFloat = 16
    static let cardPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    #endif
}

struct NFLPageView: View {
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject var model: NFLPageModel
    /// The household's preferences (spoiler-free, the followed team), shared by every sport page.
    @ObservedObject var preferences: F1PageModel
    /// Observed for the bells (a pending "watch when it starts").
    @ObservedObject private var appState: AppModel
    @Environment(\.sportPresenter) private var presenter
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var week: Int?
    @State private var view: NFLPageText.StandingsView = .division
    @State private var chosen: NFLGame?
    @State private var recording: SportEvent?
    @State private var choosingTeam = false

    init(app: AppModel, browse: BrowseModel) {
        self.app = app
        self.browse = browse
        self.model = browse.nflPage
        self.preferences = browse.f1Page
        _appState = ObservedObject(wrappedValue: app)
    }

    private var wide: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop()
        #if os(iOS)
        .navigationTitle("NFL")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .whileVisible {
            async let page: Void = model.keepFresh()
            async let prefs: Void = preferences.load()
            _ = await (page, prefs)
        }
        .detailCover(item: $recording) { event in
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme(on: best)) { _ in
                    recording = nil
                }
            }
        }
        .confirmationDialog(chosen.map { title($0) } ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible, presenting: chosen) { game in
            gameActions(game)
        }
        .confirmationDialog("Follow a team", isPresented: $choosingTeam, titleVisibility: .visible) {
            ForEach(model.page.map(NFLPageText.followable) ?? [], id: \.abbr) { team in
                Button(team.full ?? team.abbr) { Task { await preferences.setNFLFollowing(team.abbr) } }
            }
            if preferences.preferences.nflFollowing != nil {
                Button("Follow no team") { Task { await preferences.setNFLFollowing(nil) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The team you follow leads the page and the standings, on every device.")
        }
        .accessibilityIdentifier("nfl.page")
    }

    private func title(_ game: NFLGame) -> String {
        guard let page = model.page else { return "" }
        return "\(NFLPageText.name(game.away.abbr, in: page)) at \(NFLPageText.name(game.home.abbr, in: page))"
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let spoilerFree = preferences.hidesSpoilers
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: NFLMetrics.spacing) {
                header
                if let page = model.page, page.available, !page.weeks.isEmpty {
                    let shown = page.weeks.first { $0.number == (week ?? NFLPageText.openingWeek(page)) } ?? page.weeks[page.weeks.count - 1]
                    if wide {
                        HStack(alignment: .top, spacing: NFLMetrics.columnGap) {
                            weekColumn(page, shown: shown, now: now, spoilerFree: spoilerFree).frame(maxWidth: .infinity, alignment: .topLeading)
                            side(page, now: now, spoilerFree: spoilerFree).frame(width: NFLMetrics.sideWidth)
                        }
                    } else {
                        if preferences.preferences.nflFollowing != nil { teamCard(page, now: now, spoilerFree: spoilerFree) }
                        weekColumn(page, shown: shown, now: now, spoilerFree: spoilerFree)
                        standings(page, spoilerFree: spoilerFree)
                    }
                } else if !model.loaded || model.page?.available == false {
                    ProgressView("Loading the NFL…").frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    unavailable
                }
                if let error = preferences.saveError {
                    Text(error).font(NFLMetrics.detail).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .padding(wide ? 32 : 16)
            #endif
        }
        .scrollClipDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            #if os(tvOS)
            Text("NFL").font(NFLMetrics.title).accessibilityAddTraits(.isHeader)
            #else
            if wide { Text("NFL").font(NFLMetrics.title).accessibilityAddTraits(.isHeader) }
            #endif
            Spacer(minLength: 0)
            Button { choosingTeam = true } label: {
                Label(followingName.map { "Following \($0)" } ?? "Follow a team", systemImage: "star.fill")
                    .font(NFLMetrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: preferences.preferences.nflFollowing != nil))
            .disabled(model.page?.teams.isEmpty ?? true)
            .accessibilityIdentifier("nfl.following")
            Button { Task { await preferences.setSpoilerFree(!preferences.preferences.spoilerFree) } } label: {
                Label(preferences.preferences.spoilerFree ? "Spoiler-free on" : "Scores shown",
                      systemImage: preferences.preferences.spoilerFree ? "eye.slash" : "eye")
                    .font(NFLMetrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: preferences.preferences.spoilerFree))
            .disabled(!preferences.preferencesKnown)
            .accessibilityLabel(preferences.preferences.spoilerFree ? "Spoiler-free is on" : "Scores are shown")
            .accessibilityHint("Changes it for every device")
            .accessibilityIdentifier("nfl.spoilers")
        }
        .tvFocusSection()
    }

    private var followingName: String? {
        guard let abbr = preferences.preferences.nflFollowing else { return nil }
        return model.page.map { NFLPageText.name(abbr, in: $0) } ?? abbr
    }

    // MARK: The weeks

    @ViewBuilder
    private func weekColumn(_ page: NFLPage, shown: NFLWeek, now: Date, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(page.weeks) { w in
                    Button { week = w.number } label: { Text(w.label).font(NFLMetrics.chip) }
                        .buttonStyle(GuideFilterStyle(selected: w.number == shown.number))
                        .accessibilityAddTraits(w.number == shown.number ? .isSelected : [])
                        .accessibilityIdentifier("nfl.week.\(w.number)")
                }
            }
            .tvFocusSection()
            if spoilerFree && shown.games.allSatisfy({ $0.status == .done }) {
                hidden("\(shown.label) results hidden", "Spoiler-free is on. Recordings of these games are still in your library.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: NFLMetrics.gameWidth), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(shown.games) { game in gameCard(game, page: page, now: now, spoilerFree: spoilerFree) }
                }
                .tvFocusSection()
            }
            if !shown.byes.isEmpty {
                Text("Bye: \(shown.byes.map { NFLPageText.name($0, in: page) }.joined(separator: ", "))")
                    .font(NFLMetrics.detail).foregroundStyle(.secondary)
            }
        }
    }

    private func gameCard(_ game: NFLGame, page: NFLPage, now: Date, spoilerFree: Bool) -> some View {
        let mine = preferences.preferences.nflFollowing.map { $0 == game.home.abbr || $0 == game.away.abbr } ?? false
        let event = NFLPageText.event(game, in: page)
        return Button { chosen = game } label: {
            VStack(alignment: .leading, spacing: 8) {
                teamLine(game.away, game: game, page: page, spoilerFree: spoilerFree)
                teamLine(game.home, game: game, page: page, spoilerFree: spoilerFree)
                HStack(spacing: 10) {
                    if game.status == .live {
                        Text("LIVE").font(NFLMetrics.detail.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.pigDanger, in: Capsule()).foregroundStyle(.white)
                    }
                    Text(NFLPageText.status(game, spoilerFree: spoilerFree)).font(NFLMetrics.detail).monospacedDigit()
                    Spacer(minLength: 6)
                    Text(event.best?.name ?? (game.status == .done ? "" : "Not in guide yet")).font(NFLMetrics.detail)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                if game.status == .live, !spoilerFree, let down = game.situation?.downDistance {
                    Text(down + (game.situation?.redZone == true ? " · Red zone" : "")).font(NFLMetrics.detail).foregroundStyle(.secondary)
                }
            }
            .padding(NFLMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: NFLMetrics.radius, style: .continuous)
                    .strokeBorder(mine ? Color.pigAccentText : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: NFLMetrics.radius))
        .accessibilityIdentifier("nfl.game.\(game.id)")
    }

    private func teamLine(_ side: NFLGame.Side, game: NFLGame, page: NFLPage, spoilerFree: Bool) -> some View {
        HStack(spacing: 12) {
            disc(side.abbr, page: page)
            Text(NFLPageText.name(side.abbr, in: page)).font(NFLMetrics.team).lineLimit(1)
            if !spoilerFree, let record = side.record {
                Text(record).font(NFLMetrics.detail).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 6)
            if let score = NFLPageText.score(side, game: game, spoilerFree: spoilerFree) {
                Text(score).font(NFLMetrics.score).monospacedDigit()
            }
        }
    }

    private func disc(_ abbr: String, page: NFLPage) -> some View {
        Text(abbr).font(.system(size: NFLMetrics.disc * 0.34, weight: .heavy)).foregroundStyle(.white)
            .frame(width: NFLMetrics.disc, height: NFLMetrics.disc)
            .background(Color(teamHex: page.teams[abbr]?.color.flatMap { $0 == "000000" ? "3A3242" : $0 }) ?? .gray, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func gameActions(_ game: NFLGame) -> some View {
        if let page = model.page {
            let event = NFLPageText.event(game, in: page)
            if F1PageText.watchesNow(event, now: Date()) {
                Button(game.status == .live ? "Watch live" : "Watch") {
                    if let presenter { presenter.play(event) } else { app.playSportEvent(event) }
                }
            } else if game.status == .scheduled, event.best != nil {
                if appState.pendingWatch?.eventID == event.id {
                    Button("Don't watch at kick-off") { app.cancelPendingWatch() }
                } else {
                    Button("Watch at kick-off") { app.watchWhenStarts(event, now: Date()) }
                }
            }
            if game.status != .done, event.best != nil { Button("Record") { recording = event } }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: The side: the followed team, the standings

    @ViewBuilder
    private func side(_ page: NFLPage, now: Date, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: NFLMetrics.spacing) {
            if preferences.preferences.nflFollowing != nil { teamCard(page, now: now, spoilerFree: spoilerFree) }
            standings(page, spoilerFree: spoilerFree)
        }
    }

    @ViewBuilder
    private func teamCard(_ page: NFLPage, now: Date, spoilerFree: Bool) -> some View {
        if let abbr = preferences.preferences.nflFollowing {
            let team = page.teams[abbr]
            let (last, next) = NFLPageText.lastAndNext(page, team: abbr)
            let row = page.standings.flatMap(\.teams).first { $0.abbr == abbr }
            card(title: team?.full ?? abbr, note: nil) {
                if !spoilerFree, let row {
                    Text([row.record, row.seed.map { "Seed \($0)" }, row.streak].compactMap { $0 }.joined(separator: " · "))
                        .font(NFLMetrics.detail).foregroundStyle(.secondary)
                }
                if let next {
                    Text("NEXT · \(title(next))").font(NFLMetrics.team).lineLimit(1)
                    Text(NFLPageText.status(next, spoilerFree: spoilerFree)).font(NFLMetrics.detail).foregroundStyle(.secondary)
                }
                if let last, !spoilerFree {
                    Text("LAST · \(title(last)) · \(last.away.score.map(String.init) ?? "–")–\(last.home.score.map(String.init) ?? "–")")
                        .font(NFLMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 14) {
                    if let next, NFLPageText.event(next, in: page).best != nil {
                        Button(next.status == .live ? "Watch live" : "Watch at kick-off", systemImage: "play.fill") { chosen = next }
                            .pigPrimaryButton()
                            .accessibilityIdentifier("nfl.team.watch")
                    }
                    if browse.rulesAvailable, let name = team?.name {
                        Button("Record every \(name) game", systemImage: "record.circle") {
                            Task { await browse.addRule(RuleBody(kind: "sport", match: name)) }
                        }
                        .accessibilityIdentifier("nfl.team.recordEvery")
                    }
                }
                .tvFocusSection()
            }
        }
    }

    private func standings(_ page: NFLPage, spoilerFree: Bool) -> some View {
        card(title: "Standings", note: nil) {
            HStack(spacing: 10) {
                ForEach(NFLPageText.StandingsView.allCases, id: \.self) { v in
                    Button { view = v } label: { Text(v.rawValue).font(NFLMetrics.chip) }
                        .buttonStyle(GuideFilterStyle(selected: v == view))
                        .accessibilityIdentifier("nfl.standings.\(v.rawValue.lowercased())")
                }
            }
            .tvFocusSection()
            if spoilerFree {
                hidden("Standings hidden", "Records, seeds and streaks reveal results while spoiler-free is on.")
            } else {
                ForEach(NFLPageText.standings(page, view: view, following: preferences.preferences.nflFollowing), id: \.title) { group in
                    Text(group.title.uppercased()).font(NFLMetrics.detail.weight(.bold)).tracking(1.5).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(group.rows, id: \.row.abbr) { item in
                        HStack(spacing: 10) {
                            Text("\(item.rank)").font(NFLMetrics.tableDetail.weight(.bold)).frame(width: 30, alignment: .trailing).monospacedDigit()
                            disc(item.row.abbr, page: page).scaleEffect(0.7).frame(width: NFLMetrics.disc * 0.7, height: NFLMetrics.disc * 0.7)
                            Text((item.row.abbr == preferences.preferences.nflFollowing ? "★ " : "") + NFLPageText.name(item.row.abbr, in: page))
                                .font(NFLMetrics.tableName).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(item.row.record ?? "").font(NFLMetrics.tableDetail).monospacedDigit()
                            Text(item.row.streak ?? "").font(NFLMetrics.tableDetail).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func card<Content: View>(title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(NFLMetrics.cardTitle).lineLimit(1)
                Spacer(minLength: 8)
                if let note { Text(note).font(NFLMetrics.detail).foregroundStyle(.secondary).lineLimit(1) }
            }
            content()
        }
        .padding(NFLMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: NFLMetrics.radius, style: .continuous))
    }

    private func hidden(_ title: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: wide ? 36 : 28, weight: .semibold)).accessibilityHidden(true)
            Text(title).font(NFLMetrics.cardTitle)
            Text(text).font(NFLMetrics.detail).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: wide ? 220 : 140)
        .accessibilityElement(children: .combine)
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "football").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("The NFL is unavailable right now").font(DetailType.title).multilineTextAlignment(.center)
            Text(model.error ?? "The game data could not be reached. The guide and playback are not affected.")
                .font(DetailType.meta).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
        }
        .padding(.vertical, 70).frame(maxWidth: .infinity)
    }
}
