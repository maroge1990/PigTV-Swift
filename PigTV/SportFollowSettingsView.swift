import SwiftUI
import Combine

// Settings › Sport (#200, C-U, D-41): the account's sports, leagues and teams, the spoiler-free switch, league suggestions
// and "Record every game", as the web's "Your sport" panel. tvOS first: surface rows like Labs, each sport a detail page
// (`detailCover`); on iPad and iPhone a Form section whose rows are NavigationLinks.

// MARK: Questions

/// Asks one SportQuestion at a time as an alert on the screen that owns it, and hands the answer back to the model.
@MainActor
final class SportQuestionPresenter: ObservableObject {
    @Published private(set) var current: SportQuestion?
    private var continuation: CheckedContinuation<Bool, Never>?

    func ask(_ question: SportQuestion) async -> Bool {
        if let current { answer(current.dismissAnswer) }
        return await withCheckedContinuation { c in
            continuation = c
            current = question
        }
    }

    /// Answers the question shown (once; later calls do nothing).
    func answer(_ value: Bool) {
        let c = continuation
        continuation = nil
        current = nil
        c?.resume(returning: value)
    }

    /// The alert went away without a choice (Menu, or its screen closed).
    func dismiss() {
        if let current { answer(current.dismissAnswer) }
    }
}

private struct SportQuestionAlert: ViewModifier {
    @ObservedObject var presenter: SportQuestionPresenter
    func body(content: Content) -> some View {
        let q = presenter.current
        content
            .alert(q?.title ?? "", isPresented: Binding(get: { presenter.current != nil },
                                                        set: { if !$0 { presenter.dismiss() } }), presenting: q) { q in
                Button(q.confirm, role: q.confirmIsDestructive ? .destructive : .cancel) { presenter.answer(true) }
                    .accessibilityIdentifier("settings.sport.question.confirm")
                Button(q.cancel, role: q.confirmIsDestructive ? .cancel : .destructive) { presenter.answer(false) }
                    .accessibilityIdentifier("settings.sport.question.cancel")
            } message: { q in
                if let message = q.message { Text(message) }
            }
            .onDisappear { presenter.dismiss() }
    }
}

private extension View {
    func sportQuestions(_ presenter: SportQuestionPresenter) -> some View { modifier(SportQuestionAlert(presenter: presenter)) }
}

// MARK: Settings section

/// The "Sport" section of Settings, right after Appearance; only with the server's `sportFollows` flag.
struct SportSettingsSection: View {
    @ObservedObject var model: SportFollowSettingsModel
    /// The signed-in user's name, for "(set by …)" on a rule someone else made.
    let me: String?
    #if os(tvOS)
    private enum Route: Identifiable, Hashable {
        case sport(String)
        case addSport
        var id: Self { self }
    }
    @State private var route: Route?
    #endif

    var body: some View {
        Section {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 28) { rows }
                .detailCover(item: $route) { route in
                    switch route {
                    case .sport(let sport): SportFollowScreen(model: model, sport: sport, me: me)
                    case .addSport: SportAddSportScreen(model: model) { added in
                        self.route = nil
                        if let added, !model.isOneLeague(added) {
                            // The new sport's page, to choose its leagues, once this one has gone.
                            Task { try? await Task.sleep(for: .milliseconds(600)); self.route = .sport(added) }
                        }
                    }
                    }
                }
            #else
            rows
            #endif
        } header: {
            #if os(tvOS)
            PigSectionHeader(title: "Sport")
            #else
            Text("Sport").foregroundStyle(Color("PigSecondary"))
            #endif
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var rows: some View {
        if !model.message.isEmpty {
            SportStatusLine(text: model.message).accessibilityIdentifier("settings.sport.message")
        }
        if let follows = model.follows {
            if model.offline {
                SportStatusLine(text: "Can't reach the server: showing your last copy.").accessibilityIdentifier("settings.sport.offline")
            } else {
                ForEach(model.suggestions) { SportSuggestionRow(model: model, suggestion: $0) }
            }
            spoilerRow(follows.spoilerFree)
            ForEach(follows.sports, id: \.sport) { entry in sportRow(entry) }
            if follows.sports.isEmpty {
                SportStatusLine(text: "Follow a sport to fill the Sport tab.").accessibilityIdentifier("settings.sport.empty")
            }
            if !model.unfollowedSports.isEmpty { addSportRow }
        } else if model.loadFailed {
            SportStatusLine(text: "Your sport choices could not be loaded.").accessibilityIdentifier("settings.sport.failed")
            Button { Task { await model.load() } } label: {
                Text("Retry")
                    #if os(tvOS)
                    .font(.system(size: 24))
                    #endif
            }
            .accessibilityIdentifier("settings.sport.retry")
        } else {
            SportStatusLine(text: "Loading…")
        }
    }

    private func spoilerRow(_ on: Bool) -> some View {
        #if os(tvOS)
        SportSurfaceRow(title: "Hide scores", detail: "Scores and results stay hidden on every device signed in as you.",
                        value: on ? "On" : "Off") { Task { await model.setSpoilerFree(!on) } }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("settings.sport.spoilerFree")
            .accessibilityValue(on ? "On" : "Off")
        #else
        Toggle(isOn: Binding(get: { on }, set: { value in Task { await model.setSpoilerFree(value) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide scores")
                Text("Scores and results stay hidden on every device signed in as you.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.spoilerFree")
        #endif
    }

    private func sportRow(_ entry: SportFollows.Entry) -> some View {
        let summary = SportFollowLogic.summary(entry, catalog: model.catalog)
        #if os(tvOS)
        return SportSurfaceRow(title: entry.sport, detail: summary, value: nil, chevron: true) { route = .sport(entry.sport) }
            .accessibilityIdentifier("settings.sport.row.\(entry.sport)")
        #else
        return NavigationLink {
            SportFollowScreen(model: model, sport: entry.sport, me: me)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sport)
                Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("settings.sport.row.\(entry.sport)")
        #endif
    }

    private var addSportRow: some View {
        let names = model.unfollowedSports.map(\.sport).joined(separator: ", ")
        #if os(tvOS)
        return SportSurfaceRow(title: "Add a sport", detail: names, value: nil, chevron: true) { route = .addSport }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("settings.sport.add")
        #else
        return NavigationLink {
            SportAddSportScreen(model: model) { _ in }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a sport")
                Text(names).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.add")
        #endif
    }
}

/// "NRL has Brisbane Broncos games too (the first Tue 4 Nov)." with Add / No thanks.
private struct SportSuggestionRow: View {
    @ObservedObject var model: SportFollowSettingsModel
    let suggestion: SportSuggestions.Suggestion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let text = Text(SportFollowLogic.suggestionText(suggestion))
        let buttons = Group {
            Button("Add \(suggestion.label)") { Task { await model.accept(suggestion) } }
                .accessibilityIdentifier("settings.sport.suggestion.add.\(suggestion.league)")
            Button("No thanks") { Task { await model.decline(suggestion) } }
                .accessibilityIdentifier("settings.sport.suggestion.decline.\(suggestion.league)")
        }
        .disabled(!model.canEdit)
        #if os(tvOS)
        HStack(spacing: 24) {
            text.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            buttons
        }
        .font(.system(size: 24))
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: PigRadius.compact))
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sport.suggestion")
        #else
        VStack(alignment: .leading, spacing: 8) {
            text
            HStack(spacing: 16) { buttons }.buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sport.suggestion")
        #endif
    }
}

// MARK: One sport

/// A followed sport: its place in the order, its leagues (unless the catalogue has one), and its teams or people.
struct SportFollowScreen: View {
    @ObservedObject var model: SportFollowSettingsModel
    let sport: String
    let me: String?
    @StateObject private var questions = SportQuestionPresenter()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    #if os(tvOS)
    @State private var searching = false
    #endif

    var body: some View {
        page
            .sportQuestions(questions)
            .onAppear { model.message = "" }
            // Stopped following here or on another device: nothing left to show.
            .onChange(of: model.entry(sport) == nil) { _, gone in if gone && model.follows != nil { dismiss() } }
    }

    @ViewBuilder
    private var page: some View {
        #if os(tvOS)
        DetailPage(title: sport) {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: 1300, alignment: .leading)
                .padding(.horizontal, 48)
        }
        .accessibilityIdentifier("settings.sport.screen")
        .detailCover(isPresented: $searching) { SportNameSearchScreen(model: model, sport: sport) }
        #else
        Form { content }
            .navigationTitle(sport)
            .accessibilityIdentifier("settings.sport.screen")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let entry = model.entry(sport) {
            let index = model.follows?.sports.firstIndex { $0.sport == sport } ?? 0
            let count = model.follows?.sports.count ?? 1
            if !model.message.isEmpty {
                SportStatusLine(text: model.message).accessibilityIdentifier("settings.sport.message")
            }
            if model.offline {
                SportStatusLine(text: "Can't reach the server: showing your last copy.")
            }
            Section {
                orderActions(index: index, count: count)
            }
            if !model.isOneLeague(sport) { leagues(entry) }
            names(entry)
        }
    }

    @ViewBuilder
    private func orderActions(index: Int, count: Int) -> some View {
        let up = Button { Task { await model.moveSport(sport, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
            .disabled(!model.canEdit || index == 0)
            .accessibilityIdentifier("settings.sport.moveUp")
        let down = Button { Task { await model.moveSport(sport, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
            .disabled(!model.canEdit || index >= count - 1)
            .accessibilityIdentifier("settings.sport.moveDown")
        let stop = Button(role: .destructive) {
            Task { if await model.removeSport(sport, ask: questions.ask) { dismiss() } }
        } label: { Label("Stop following \(sport)", systemImage: "xmark.circle") }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("settings.sport.stop")
        #if os(tvOS)
        DetailActions { up; down; stop }
        #else
        up; down; stop
        #endif
    }

    @ViewBuilder
    private func leagues(_ entry: SportFollows.Entry) -> some View {
        Section {
            ForEach(Array(entry.leagues.enumerated()), id: \.element) { i, league in
                SportItemRow {
                    Text(model.label(league))
                } actions: {
                    SportRowAction(title: "Move up", systemImage: "arrow.up", id: "settings.sport.league.\(league).up") {
                        Task { await model.moveLeague(sport, league, by: -1) }
                    }
                    .disabled(!model.canEdit || i == 0)
                    SportRowAction(title: "Move down", systemImage: "arrow.down", id: "settings.sport.league.\(league).down") {
                        Task { await model.moveLeague(sport, league, by: 1) }
                    }
                    .disabled(!model.canEdit || i >= entry.leagues.count - 1)
                    SportRowAction(title: "Remove", systemImage: "minus.circle", id: "settings.sport.league.\(league).remove") {
                        Task { await model.removeLeague(sport, league, ask: questions.ask) }
                    }
                    .disabled(!model.canEdit)
                }
            }
        } header: { header("Leagues") }
        let groups = unfollowedLeagues(entry)
        if !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    if let heading = group.heading {
                        Text(heading).font(DetailType.rowDetail).foregroundStyle(.secondary)
                    }
                    #if os(tvOS)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 24) {
                        ForEach(group.leagues, id: \.league) { league in addLeagueButton(league) }
                    }
                    .focusSection()
                    #else
                    ForEach(group.leagues, id: \.league) { league in addLeagueButton(league) }
                    #endif
                }
            } header: { header("Add a league") }
        }
    }

    private func addLeagueButton(_ league: SportCatalog.League) -> some View {
        Button { Task { await model.addLeague(sport, league.league) } } label: {
            Label(league.label, systemImage: "plus")
        }
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.addLeague.\(league.league)")
    }

    /// The catalogue's leagues of this sport not followed, under their headings in its order.
    private struct LeagueGroup: Identifiable {
        let heading: String?
        var leagues: [SportCatalog.League]
        var id: String { heading ?? "" }
    }

    private func unfollowedLeagues(_ entry: SportFollows.Entry) -> [LeagueGroup] {
        var out: [LeagueGroup] = []
        for league in model.catalog.sport(sport)?.leagues ?? [] where !entry.leagues.contains(league.league) {
            if let i = out.firstIndex(where: { $0.heading == league.heading }) { out[i].leagues.append(league) }
            else { out.append(LeagueGroup(heading: league.heading, leagues: [league])) }
        }
        return out
    }

    @ViewBuilder
    private func names(_ entry: SportFollows.Entry) -> some View {
        let people = model.followsPeople(entry)
        let records = !people && model.rulesAvailable
        Section {
            if entry.teams.isEmpty {
                SportStatusLine(text: "None yet: they are highlighted in every league above they play in.")
            }
            ForEach(entry.teams, id: \.self) { name in
                let rule = model.rule(sport, name)
                let on = rule?.enabled == true
                let by = rule?.createdByName.flatMap { $0 != me ? " (set by \($0))" : nil } ?? ""
                SportItemRow {
                    Label { Text(name) } icon: { Image(systemName: "star.fill").foregroundStyle(Color.pigAccent) }
                } actions: {
                    #if os(tvOS)
                    if records {
                        Button { Task { await model.setRecording(sport, name, on: !on, ask: questions.ask) } } label: {
                            Text("Record every game\(by): \(on ? "On" : "Off")")
                        }
                        .disabled(!model.canEdit || model.ruleBusy.contains("\(sport)|\(name)"))
                        .accessibilityIdentifier("settings.sport.name.\(name).record")
                        .accessibilityValue(on ? "On" : "Off")
                    }
                    #endif
                    SportRowAction(title: "Unfollow", systemImage: "minus.circle", id: "settings.sport.name.\(name).unfollow") {
                        Task { await model.unfollow(sport, name, ask: questions.ask) }
                    }
                    .disabled(!model.canEdit)
                }
                #if os(iOS)
                if records {
                    Toggle("Record every game\(by)", isOn: Binding(get: { on }, set: { value in
                        Task { await model.setRecording(sport, name, on: value, ask: questions.ask) }
                    }))
                    .disabled(!model.canEdit || model.ruleBusy.contains("\(sport)|\(name)"))
                    .accessibilityIdentifier("settings.sport.name.\(name).record")
                }
                #endif
            }
            followButton(entry, people: people)
        } header: { header(SportFollowLogic.namesHeading(sport, people: people)) }
    }

    @ViewBuilder
    private func followButton(_ entry: SportFollows.Entry, people: Bool) -> some View {
        let title = SportFollowLogic.followTitle(sport, people: people)
        let full = entry.teams.count >= SportFollowLogic.maxNames
        #if os(tvOS)
        Button { searching = true } label: { Label(title, systemImage: "magnifyingglass") }
            .disabled(!model.canEdit || full)
            .accessibilityIdentifier("settings.sport.follow")
        #else
        NavigationLink { SportNameSearchScreen(model: model, sport: sport) } label: { Label(title, systemImage: "magnifyingglass") }
            .disabled(!model.canEdit || full)
            .accessibilityIdentifier("settings.sport.follow")
        #endif
        if full { SportStatusLine(text: "At most \(SportFollowLogic.maxNames) in one sport.") }
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        #if os(tvOS)
        PigSectionHeader(title: title)
        #else
        Text(title)
        #endif
    }
}

// MARK: Add a sport

/// The catalogue's sports not followed yet; choosing one follows it (with its first league) and closes the list.
struct SportAddSportScreen: View {
    @ObservedObject var model: SportFollowSettingsModel
    /// The sport just followed (nil: none).
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        DetailPage(title: "Add a sport") {
            VStack(alignment: .leading, spacing: 20) { list }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, 48)
        }
        #else
        Form { Section { list } }.navigationTitle("Add a sport")
        #endif
    }

    @ViewBuilder
    private var list: some View {
        if !model.message.isEmpty { SportStatusLine(text: model.message) }
        ForEach(model.unfollowedSports, id: \.sport) { sport in
            let leagues = sport.leagues.map(\.label).joined(separator: ", ")
            #if os(tvOS)
            SportSurfaceRow(title: sport.sport, detail: leagues, value: nil) { choose(sport.sport) }
                .disabled(!model.canEdit)
                .accessibilityIdentifier("settings.sport.addSport.\(sport.sport)")
            #else
            Button { choose(sport.sport) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sport.sport).foregroundStyle(Color("PigText"))
                    Text(leagues).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .disabled(!model.canEdit)
            .accessibilityIdentifier("settings.sport.addSport.\(sport.sport)")
            #endif
        }
    }

    private func choose(_ sport: String) {
        Task {
            let added = await model.addSport(sport)
            #if os(tvOS)
            done(added ? sport : nil)
            #else
            if added { dismiss() }
            done(added ? sport : nil)
            #endif
        }
    }
}

// MARK: Follow a team or person

/// A search over the names the sport's followed leagues offer (deduped, any case, not followed already, up to 30).
struct SportNameSearchScreen: View {
    @ObservedObject var model: SportFollowSettingsModel
    let sport: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        DetailPage(title: title) {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, 48)
        }
        .onAppear { model.message = "" }
        #else
        Form { content }
            .navigationTitle(title)
            .onAppear { model.message = "" }
        #endif
    }

    private var title: String {
        model.entry(sport).map { SportFollowLogic.followTitle(sport, people: model.followsPeople($0)) } ?? sport
    }

    @ViewBuilder
    private var content: some View {
        if let entry = model.entry(sport) {
            let offered = model.offered(entry)
            let people = model.followsPeople(entry)
            TextField(people ? "Search names" : "Search teams", text: $query)
                .pigField()
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.sport.search.field")
            if !model.message.isEmpty { SportStatusLine(text: model.message).accessibilityIdentifier("settings.sport.message") }
            if offered.isEmpty {
                SportStatusLine(text: "The list fills in once these leagues' fixtures have been read.")
                let typed = SportFollowLogic.clean(query)
                if !typed.isEmpty {
                    Button("Follow \(typed)") { choose(typed) }
                        .disabled(!model.canEdit)
                        .accessibilityIdentifier("settings.sport.search.typed")
                }
            } else {
                ForEach(SportFollowLogic.matches(query, offered: offered, following: entry.teams), id: \.self) { name in
                    Button { choose(name) } label: {
                        Text(name)
                            #if os(tvOS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            #endif
                    }
                    .disabled(!model.canEdit)
                    .accessibilityIdentifier("settings.sport.search.result.\(name)")
                }
            }
        }
    }

    private func choose(_ name: String) {
        Task { if await model.follow(sport, name) { dismiss() } }
    }
}

// MARK: Rows

/// A Settings row on tvOS: a surface button with a title, a one-line detail and a value, like the Labs switches.
private struct SportSurfaceRow: View {
    let title: String
    let detail: String?
    let value: String?
    var chevron = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron { Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            #if os(tvOS)
            .font(.system(size: 24))
            .padding(.horizontal, 24).padding(.vertical, 16)
            #endif
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(PigSurfaceButtonStyle())
        #endif
    }
}

/// A league or a followed name with its actions: on tvOS a cell with a row of buttons (one focus section), on iOS a Form
/// row with borderless icon buttons.
private struct SportItemRow<Title: View, Actions: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            title.font(DetailType.rowTitle).lineLimit(1)
            Spacer(minLength: 12)
            actions.font(DetailType.button)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: PigRadius.compact))
        .focusSection()
        #else
        HStack(spacing: 16) {
            title.lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .buttonStyle(.borderless)
        #endif
    }
}

/// One action in a SportItemRow: its words on tvOS, its icon (with the words for VoiceOver) on iOS.
private struct SportRowAction: View {
    let title: String
    let systemImage: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            Text(title)
            #else
            Image(systemName: systemImage)
            #endif
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// A line of status text (what the last change did, the empty and offline states).
private struct SportStatusLine: View {
    let text: String
    var body: some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22))
            #else
            .font(.footnote)
            #endif
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
