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

/// Settings › Sport (D-44 batch 6, R5-SetSport-*), only with the server's `sportFollows` flag: Hide scores and Score delay
/// side by side, then your sports in your order (each with its leagues and its followed teams or people, their logos where
/// the loaded Sport data has them, else monograms), the league suggestions and Add a sport. On the TV a sport opens its
/// page as a cover; on iOS it is pushed.
struct SportSettingsSection: View {
    @ObservedObject var model: SportFollowSettingsModel
    /// The signed-in user's name, for "(set by …)" on a rule someone else made.
    let me: String?
    /// The loaded Sport front page's follows, for their cached logos (C-R `follows[].logo`).
    var frontFollows: [SportFront.Follow] = []
    @StateObject private var delay: ScoreDelaySetting
    #if os(tvOS)
    private enum Route: Identifiable, Hashable {
        case sport(String)
        case addSport
        var id: Self { self }
    }
    @State private var route: Route?
    #endif

    init(model: SportFollowSettingsModel, me: String?, frontFollows: [SportFront.Follow] = []) {
        self.model = model
        self.me = me
        self.frontFollows = frontFollows
        _delay = StateObject(wrappedValue: ScoreDelaySetting(client: model.client, fixture: model.isFixture))
    }

    var body: some View {
        content
            #if os(tvOS)
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
            #endif
            .task { await model.load() }
            .task { await delay.load() }
            // The offline fixtures apply theirs after the page has appeared.
            .onReceive(model.$follows) { _ in if model.isFixture { delay.useFixture() } }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            statusLines
            if let follows = model.follows {
                HStack(alignment: .top, spacing: PigSpacing.s) {
                    spoilerRow(follows.spoilerFree)
                    if delay.shown { delayRow }
                }
                .focusSection()
                yourSportsHeading.padding(.top, PigSpacing.xs)
                ForEach(follows.sports, id: \.sport) { entry in sportRow(entry) }
                if model.state == .empty {
                    // #280 (E1): Add a sport is its one action.
                    PigEmptyState(title: PageWords.noSportsTitle, text: PageWords.noSportsText,
                                  action: model.canEdit ? PigStateAction(label: PageWords.addSport, systemImage: "plus") { route = .addSport } : nil,
                                  identifier: "settings.sport.empty")
                } else {
                    if !model.offline { ForEach(model.suggestions) { SportSuggestionRow(model: model, suggestion: $0) } }
                    if !model.unfollowedSports.isEmpty { addSportRow }
                }
            } else { loadingOrFailed }
        }
        #else
        Section { statusLines }
        if let follows = model.follows {
            Section {
                spoilerRow(follows.spoilerFree)
                if delay.shown { delayRow }
            }
            Section {
                // #256: Edit order, then drag a sport by its handle (each sport's page keeps Move up / Move down).
                ForEach(follows.sports, id: \.sport) { entry in sportRow(entry) }
                    .onMove(perform: model.canEdit ? { from, to in Task { await model.moveSports(from: from, to: to) } } : nil)
                if model.state == .empty {
                    // #280 (E1): its one action is the Add a sport row just below (a pushed page in this list).
                    PigEmptyState(title: PageWords.noSportsTitle, text: PageWords.noSportsText, identifier: "settings.sport.empty")
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    yourSportsHeading
                    Spacer()
                    if follows.sports.count > 1 && model.canEdit {
                        // #256: a press and drag on the row itself goes to its button; Edit order shows the handles.
                        Button(model.ordering ? "Done" : "Edit order") {
                            withAnimation { model.ordering.toggle() }
                        }
                        .font(SettingsSportType.caption.weight(.semibold))
                        .textCase(nil)
                        .accessibilityIdentifier("settings.sport.order")
                    }
                }
            }
            if !model.offline, !model.suggestions.isEmpty {
                Section { ForEach(model.suggestions) { SportSuggestionRow(model: model, suggestion: $0) } }
            }
            if !model.unfollowedSports.isEmpty { Section { addSportRow } }
        } else {
            Section { loadingOrFailed }
        }
        #endif
    }

    @ViewBuilder
    private var statusLines: some View {
        if !model.message.isEmpty {
            SportStatusLine(text: model.message).accessibilityIdentifier("settings.sport.message")
        }
        if !delay.message.isEmpty {
            SportStatusLine(text: delay.message).accessibilityIdentifier("settings.sport.delay.message")
        }
        if model.follows != nil, model.offline {
            // #280 (R1): this device's last copy stays, with the slim notice.
            PigStaleNotice(since: nil, retry: { await model.load() }, identifier: "settings.sport.offline")
        }
    }

    /// #280: before the first answer, the page's shape; with neither an answer nor a copy, the error (nothing polls this
    /// page, so its own 20 s retry is the only one).
    @ViewBuilder
    private var loadingOrFailed: some View {
        if let failure = model.state.failure {
            PigErrorState(failure: failure, retry: { await model.load() }, identifier: "settings.sport.failed")
                #if os(iOS)
                .listRowBackground(Color.clear)
                #endif
        } else {
            SettingsSportPlaceholder()
                #if os(iOS)
                .listRowBackground(Color.clear)
                #endif
        }
    }

    private var yourSportsHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: PigSpacing.m) {
            Text("Your sports").font(SettingsSportType.heading).foregroundStyle(Color.pigText)
                .accessibilityAddTraits(.isHeader)
            #if os(tvOS)
            Text("in your order · select one to change its leagues and teams").font(SettingsSportType.caption)
                .foregroundStyle(Color.pigSecondary)
            #else
            Text("in your order").font(SettingsSportType.caption).foregroundStyle(Color.pigSecondary)
            #endif
        }
        .textCase(nil)
    }

    private func spoilerRow(_ on: Bool) -> some View {
        #if os(tvOS)
        Button { Task { await model.setSpoilerFree(!on) } } label: {
            HStack(spacing: PigSpacing.m) {
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text("Hide scores").font(SettingsSportType.tileTitle)
                    Text("Scores and results stay hidden on every device signed in as you.").font(SettingsSportType.tileDetail)
                        .foregroundStyle(Color.pigSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SwitchGlyph(on: on)
            }
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            .frame(maxWidth: .infinity, minHeight: SettingsSportMetrics.tileHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .disabled(!model.canEdit)
        .settingsFirstFocus()
        .accessibilityIdentifier("settings.sport.spoilerFree")
        .accessibilityValue(on ? "On" : "Off")
        #else
        Toggle(isOn: Binding(get: { on }, set: { value in Task { await model.setSpoilerFree(value) } })) {
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                Text("Hide scores")
                Text("On every device signed in as you.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(Color.pigAccent)
        .listRowBackground(Color.pigRaised)
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.spoilerFree")
        #endif
    }

    /// Score delay: −10, the delay, +10 (C-O; only where the server keeps it).
    private var delayRow: some View {
        let seconds = delay.preferences?.scoreDelaySeconds
        let less = Button { Task { await delay.step(-ScoreDelay.step) } } label: {
            Text("−10").font(SettingsSportType.stepper).monospacedDigit().fontDesign(.rounded)
                #if os(tvOS)
                .padding(.horizontal, PigSpacing.m)
                #endif
        }
        .disabled(seconds == nil || seconds == ScoreDelay.range.lowerBound || delay.saving)
        .accessibilityLabel("Ten seconds less")
        .accessibilityIdentifier("settings.sport.delay.less")
        let more = Button { Task { await delay.step(ScoreDelay.step) } } label: {
            Text("+10").font(SettingsSportType.stepper).monospacedDigit().fontDesign(.rounded)
                #if os(tvOS)
                .padding(.horizontal, PigSpacing.m)
                #endif
        }
        .disabled(seconds == nil || seconds == ScoreDelay.range.upperBound || delay.saving)
        .accessibilityLabel("Ten seconds more")
        .accessibilityIdentifier("settings.sport.delay.more")
        let value = Text(seconds.map(ScoreDelay.text) ?? "—").font(SettingsSportType.delay).monospacedDigit().fontDesign(.rounded)
            .frame(minWidth: SettingsSportMetrics.delayWidth)
            .accessibilityLabel("Score delay \(seconds.map { "\($0) seconds" } ?? "unknown")")
            .accessibilityIdentifier("settings.sport.delay.value")
        #if os(tvOS)
        return HStack(spacing: PigSpacing.s) {
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                Text("Score delay").font(SettingsSportType.tileTitle)
                Text("0–300 seconds. Clocks and scores follow it.").font(SettingsSportType.tileDetail)
                    .foregroundStyle(Color.pigSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // #279: two real buttons, 56 pt or more with their own surface on the raised tile.
            less.buttonStyle(PigSurfaceButtonStyle(restingFill: .pigSurface))
            value
            more.buttonStyle(PigSurfaceButtonStyle(restingFill: .pigSurface))
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
        .frame(maxWidth: .infinity, minHeight: SettingsSportMetrics.tileHeight, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .focusSection()
        #else
        return HStack(spacing: PigSpacing.m) {
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                Text("Score delay")
                Text("0–300 seconds").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                less.frame(minWidth: 44, minHeight: 36)
                value
                more.frame(minWidth: 44, minHeight: 36)
            }
            .buttonStyle(.borderless)
            .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
        }
        .listRowBackground(Color.pigRaised)
        #endif
    }

    private func sportRow(_ entry: SportFollows.Entry) -> some View {
        let leagues = entry.leagues.map(model.label).joined(separator: " · ")
        let names = SettingsSportLogos.names(entry, follows: frontFollows)
        #if os(tvOS)
        return Button { route = .sport(entry.sport) } label: {
            HStack(spacing: PigSpacing.m) {
                Text(entry.sport).font(SettingsSportType.tileTitle).frame(width: SettingsSportMetrics.nameWidth, alignment: .leading)
                    .lineLimit(1)
                Text(leagues).font(SettingsSportType.rowDetail).foregroundStyle(Color.pigSecondary).lineLimit(1)
                Spacer(minLength: 12)
                FollowedNames(names: names, client: model.client)
            }
            .padding(.horizontal, PigSpacing.l)
            .frame(maxWidth: .infinity, minHeight: SettingsSportMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .accessibilityLabel([entry.sport, leagues, names.map(\.name).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("settings.sport.row.\(entry.sport)")
        #else
        return NavigationLink {
            SportFollowScreen(model: model, sport: entry.sport, me: me)
        } label: {
            HStack(spacing: PigSpacing.m) {
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(entry.sport).font(.headline)
                    Text(leagues).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                FollowedNames(names: names, client: model.client)
            }
        }
        .listRowBackground(Color.pigRaised)
        .accessibilityIdentifier("settings.sport.row.\(entry.sport)")
        #endif
    }

    private var addSportRow: some View {
        #if os(tvOS)
        return Button { route = .addSport } label: {
            Label("Add a sport", systemImage: "plus").font(SettingsSportType.tileTitle)
                .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.add")
        #else
        return NavigationLink {
            SportAddSportScreen(model: model) { _ in }
        } label: {
            Label("Add a sport", systemImage: "plus").foregroundStyle(Color.pigAccentText)
        }
        .listRowBackground(Color.pigRaised)
        .disabled(!model.canEdit)
        .accessibilityIdentifier("settings.sport.add")
        #endif
    }
}

/// The followed teams or people beside a sport: up to two, each with its cached logo or a monogram, then "+n".
private struct FollowedNames: View {
    let names: [SettingsSportLogos.Name]
    let client: APIClient

    var body: some View {
        HStack(spacing: SettingsSportMetrics.badge * 0.4) {
            ForEach(names.prefix(2), id: \.name) { name in
                HStack(spacing: SettingsSportMetrics.badge * 0.25) {
                    SportBadge(name: name.name, logo: name.logo, league: "", client: client, size: SettingsSportMetrics.badge)
                        .accessibilityHidden(true)
                    Text(name.name).font(SettingsSportType.follow).foregroundStyle(Color.pigAccentText).lineLimit(1)
                }
            }
            if names.count > 2 {
                Text("+\(names.count - 2)").font(SettingsSportType.follow).monospacedDigit().foregroundStyle(Color.pigSecondary)
            }
        }
        .fixedSize()
    }
}

/// The Hide scores switch as the TV draws it (tvOS has no Toggle switch): pink and to the right when on.
private struct SwitchGlyph: View {
    let on: Bool
    var body: some View {
        Capsule().fill(on ? Color.pigAccent : Color.pigBorder)
            .frame(width: 64, height: 36)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.pigOnStatus).frame(width: 30, height: 30).padding(PigSpacing.xxs)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .accessibilityHidden(true)
    }
}

nonisolated enum SettingsSportMetrics {
    #if os(tvOS)
    static let tileHeight: CGFloat = 108
    static let rowHeight: CGFloat = 62
    static let nameWidth: CGFloat = 250
    static let delayWidth: CGFloat = 76
    static let badge: CGFloat = 30
    #else
    static let tileHeight: CGFloat = 0
    static let rowHeight: CGFloat = 52
    static let nameWidth: CGFloat = 0
    static let delayWidth: CGFloat = 46
    static let badge: CGFloat = 22
    #endif
}

nonisolated enum SettingsSportType {
    #if os(tvOS)
    static let heading: Font = .system(size: PigType.cardTitle, weight: .heavy)
    static let caption: Font = .system(size: PigType.caption)
    static let tileTitle: Font = .system(size: PigType.body, weight: .bold)
    static let tileDetail: Font = .system(size: PigType.caption)
    static let rowDetail: Font = .system(size: PigType.secondary)
    static let follow: Font = .system(size: PigType.caption, weight: .semibold)
    static let stepper: Font = .system(size: PigType.secondary, weight: .bold)
    static let delay: Font = .system(size: PigType.cardTitle, weight: .bold)
    #else
    static let heading: Font = .headline
    static let caption: Font = .footnote
    static let tileTitle: Font = .headline
    static let tileDetail: Font = .footnote
    static let rowDetail: Font = .footnote
    static let follow: Font = .footnote.weight(.semibold)
    static let stepper: Font = .subheadline
    static let delay: Font = .headline
    #endif
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
        HStack(spacing: PigSpacing.l) {
            text.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            buttons
        }
        .font(.system(size: PigType.body))
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: PigRadius.compact))
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sport.suggestion")
        #else
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            text
            HStack(spacing: PigSpacing.l) { buttons }.buttonStyle(.borderless)
        }
        .listRowBackground(Color.pigRaised)
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
            VStack(alignment: .leading, spacing: PigSpacing.l) { content }
                .frame(maxWidth: 1300, alignment: .leading)
                .padding(.horizontal, PigSpacing.section)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: PigSpacing.l, alignment: .leading)], alignment: .leading, spacing: PigSpacing.l) {
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
            VStack(alignment: .leading, spacing: PigSpacing.m) { list }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, PigSpacing.section)
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
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(sport.sport).foregroundStyle(Color.pigText)
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
            VStack(alignment: .leading, spacing: PigSpacing.m) { content }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, PigSpacing.section)
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
            HStack(spacing: PigSpacing.l) {
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    Text(title)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: PigType.secondary)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron { Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            #if os(tvOS)
            .font(.system(size: PigType.body))
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
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
        HStack(spacing: PigSpacing.m) {
            title.font(DetailType.rowTitle).lineLimit(1)
            Spacer(minLength: 12)
            actions.font(DetailType.button)
        }
        .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.s)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: PigRadius.compact))
        .focusSection()
        #else
        HStack(spacing: PigSpacing.l) {
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
            .font(.system(size: PigType.body))
            #else
            .font(.footnote)
            #endif
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
