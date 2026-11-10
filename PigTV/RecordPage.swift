import SwiftUI

// D-44 batch 5 (Apple 114, R5-Record-*): the one record page, a centred sheet on the page canvas, opened from the
// long-press menu's More options… (the TV Guide and Sport alike) and from every Record button. What (this one, or a
// rule: every new episode / every episode; every <team> game / every <league> game) · When it stops (a Sport card's
// game: when ESPN says it's over, else the guide end, plus Start early / Finish late) · Record on (Sport only, when
// several channels carry it). A programme already scheduled opens it as Change recording: its padding can change
// (C-M since 0444, `PUT recordings/scheduled/:id`; Finish late only once it records), and Cancel recording acts at
// once with the 10 s Undo. The choices are pure (`RecordPlan`, tested in RecordPageTests).

/// A team on the page's header (a Sport card's competitor) and the name "Every <team> game" follows.
nonisolated struct RecordTeam: Equatable, Sendable {
    let name: String
    /// A cached same-server logo, or nil (a monogram disc).
    var logo: String? = nil
}

/// What the record page records.
nonisolated struct RecordRequest: Identifiable, Sendable {
    /// One channel that carries it, on that channel's own times.
    struct Airing: Identifiable, Sendable {
        let channel: GuideChannel
        let programme: GuideProgramme
        var quality: SportQuality? = nil
        var id: String { channel.id }
    }

    let title: String
    /// The league (Sport), shown in the kicker.
    var league: String? = nil
    /// Best first; one for a guide programme.
    let airings: [Airing]
    /// C-M since 0440: the Sport card's game, sent with the schedule.
    var gameId: String? = nil
    var teams: [RecordTeam] = []
    /// The team a rule is for: the one the caller named (a follow's card, the hero's follow), else the one followed side;
    /// nil when neither or both sides are followed (#49: never the first match of two).
    var followedTeam: String? = nil
    /// Every followed side (both when the account follows both teams).
    var followedTeams: [String] = []

    /// "Record every <team> game"'s team: `followedTeam`, else (nobody followed) the first side, else nil: with both sides
    /// followed and no team named, the record page offers each (#49).
    var everyGameTeam: String? { followedTeam ?? (followedTeams.isEmpty ? teams.first?.name : nil) }
    /// The league's catalogue sport ("Football"), for a `team` rule.
    var sport: String? = nil
    var isGame = false
    /// Change recording: the active schedule this is.
    var schedule: ScheduledRecording? = nil
    /// Shown on opening (a quick Record from a menu that failed).
    var error: String? = nil
    /// The channel to start on (a channel row's "Record on <channel>"), by its id; else the best.
    var preferredChannel: String? = nil

    var id: String {
        "\(schedule.map { "s\($0.id)" } ?? "new")|\(airings.first?.id ?? "")|\(Int64(airings.first?.programme.startTime ?? 0))"
    }
}

/// The page's choices. Pure; tested.
nonisolated enum RecordPlan {
    enum What: Hashable, Sendable {
        case this
        case everyNewEpisode
        case everyEpisode
        case everyTeam(String)
        case everyLeague(String)
    }

    /// Start early and Finish late, in minutes; nil is the server's usual padding.
    static let startEarly: [Int?] = [nil, 0, 1, 2, 5, 10]
    static let finishLate: [Int?] = [nil, 0, 2, 5, 10, 15, 30]

    /// The What choices: this one, then the rules. A game: every game of the followed team
    /// (else of each side), then every game of its league. A programme: every new episode, every episode. Change
    /// recording has none (it is one schedule).
    static func whats(_ request: RecordRequest) -> [What] {
        guard request.schedule == nil else { return [] }
        var out: [What] = [.this]
        if request.isGame || request.league != nil {
            // #49: the team named or the one followed side; both sides when both (or neither) are followed.
            let teams = request.followedTeam.map { [$0] } ?? request.teams.prefix(2).map(\.name)
            out += teams.map(What.everyTeam)
            if let league = request.league?.trimmingCharacters(in: .whitespaces), !league.isEmpty,
               league.lowercased() != "sport" {
                out.append(.everyLeague(league))
            }
        } else {
            out += [.everyNewEpisode, .everyEpisode]
        }
        return out
    }

    /// A What tile's two lines.
    static func label(_ what: What, request: RecordRequest, leagueLabel: String? = nil, now: Date) -> (title: String, detail: String) {
        switch what {
        case .this:
            let when = request.airings.first.map { airing in
                "\(DetailText.day(airing.programme.start, now: now)) \(airing.programme.start.formatted(date: .omitted, time: .shortened))"
            } ?? ""
            return (request.isGame || request.league != nil ? "This game" : "This programme", when)
        case .everyNewEpisode:
            return ("Every new episode", "\(request.title) on \(request.airings.first?.channel.name ?? "this channel")")
        case .everyEpisode:
            return ("Every episode", "Repeats as well")
        case .everyTeam(let team):
            return ("Every \(team) game", "Never replays")
        case .everyLeague(let league):
            let name = leagueLabel ?? league
            return (request.teams.count == 2 ? "Every \(name) game" : "Everything in \(name)", "On your channels, never replays")
        }
    }

    /// The rule a What makes (nil for "this one").
    static func rule(_ what: What, request: RecordRequest, before: Int?, after: Int?) -> RuleBody? {
        let channel = request.airings.first?.channel
        switch what {
        case .this:
            return nil
        case .everyNewEpisode, .everyEpisode:
            return RuleBody(kind: "series", match: request.title, sourceId: channel?.sourceId, channelId: channel?.rawID,
                            channelName: channel?.name, preBufferMin: before, postBufferMin: after,
                            newOnly: what == .everyNewEpisode)
        case .everyTeam(let team):
            // C-M `team` (0414) needs the team's sport; without it, a keyword `sport` rule on the name.
            if let sport = request.sport, !sport.isEmpty {
                return RuleBody(kind: "team", match: team, preBufferMin: before, postBufferMin: after, sport: sport)
            }
            return RuleBody(kind: "sport", match: team, preBufferMin: before, postBufferMin: after)
        case .everyLeague(let league):
            return RuleBody(kind: "sport", match: league, preBufferMin: before, postBufferMin: after)
        }
    }

    /// The chips of one padding row: on Change recording the schedule's own value (added when it is not one of them)
    /// and never "Usual" (it has a value).
    static func chips(_ base: [Int?], current: Int?, changing: Bool) -> [Int?] {
        guard changing else { return base }
        var minutes = base.compactMap { $0 }
        if let current, !minutes.contains(current) { minutes.append(current); minutes.sort() }
        return minutes.map { Optional($0) }
    }

    static func chipTitle(_ minutes: Int?) -> String {
        guard let minutes else { return "Usual" }
        return minutes == 0 ? "On time" : "\(minutes) min"
    }

    /// Start early can change only before it records.
    static func canChangeStartEarly(_ schedule: ScheduledRecording) -> Bool { schedule.status != "recording" }

    /// What "Save changes" sends: only what changed (Start early not once it records); nil when nothing has.
    static func change(_ schedule: ScheduledRecording, before: Int?, after: Int?) -> ScheduleChangeBody? {
        var body = ScheduleChangeBody()
        if canChangeStartEarly(schedule), let before, before != schedule.startEarly { body.preBufferMin = before }
        if let after, after != schedule.finishLate { body.postBufferMin = after }
        return body == ScheduleChangeBody() ? nil : body
    }

    /// Codex 5a round 1 (medium): which schedule the page is about. A channel chosen explicitly (`preferred`) is that
    /// channel's schedule, or a new recording when it has none; otherwise the first channel that has one, and the page
    /// shows that channel (its id is returned), so Change recording never shows one channel and changes another.
    static func bind(schedules: [ScheduledRecording?], channels: [String], preferred: String?)
        -> (schedule: ScheduledRecording?, channel: String?) {
        if let preferred, let index = channels.firstIndex(of: preferred) {
            return (schedules.indices.contains(index) ? schedules[index] : nil, preferred)
        }
        for (index, schedule) in schedules.enumerated() where schedule != nil && channels.indices.contains(index) {
            return (schedule, channels[index])
        }
        return (nil, nil)
    }

    /// Codex 5a round 1 (medium): the schedule as the refreshed list has it now, while the page is open; nil once it has
    /// finished, been cancelled or gone (the page then changes nothing).
    static func live(_ opened: ScheduledRecording, in schedules: [ScheduledRecording]) -> ScheduledRecording? {
        schedules.first { $0.id == opened.id && $0.isActive }
    }

    static let goneText = "This recording has finished or no longer exists, so it cannot be changed."

    /// It stops when the game ends: a Sport card's game (its id is sent), or a schedule the server links to one.
    static func stopsWithGame(_ request: RecordRequest) -> Bool {
        if let schedule = request.schedule { return schedule.stopsWithEvent }
        return request.gameId != nil
    }

    /// When it stops, in words: the first line and the one under it.
    static func stopLines(_ request: RecordRequest, airing: RecordRequest.Airing?, now: Date) -> (title: String, detail: String) {
        let end = (airing?.programme.end).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        if stopsWithGame(request) {
            return ("When the game ends (ESPN)", "Else the guide end, \(end), + Finish late")
        }
        return ("When the guide says it ends", "\(end) + Finish late")
    }

    /// The primary button.
    static func primaryTitle(_ what: What, request: RecordRequest) -> String {
        if request.schedule != nil { return "Save changes" }
        switch what {
        case .this: return request.isGame || request.league != nil ? "Record game" : "Record programme"
        case .everyNewEpisode: return "Record every new episode"
        case .everyEpisode: return "Record every episode"
        case .everyTeam, .everyLeague: return "Record every game"
        }
    }

    /// When the recording needs a provider connection. #251: it said "PigTV has one provider stream" to every household,
    /// whatever its providers; a recording waits only when every connection of every provider is in use.
    static func streamNote(_ airing: RecordRequest.Airing?, before: Int?, now: Date) -> String {
        guard let programme = airing?.programme else { return "" }
        if programme.start <= now { return "It has started: only the rest of it is recorded." }
        let starts = programme.start.addingTimeInterval(-Double(before ?? 0) * 60)
        let at = before == nil ? "when it starts" : "at \(starts.formatted(date: .omitted, time: .shortened))"
        return "If every provider connection is in use \(at), the recording waits for one to free up."
    }

    /// Record on's second line for one channel.
    static func airingDetail(_ airing: RecordRequest.Airing, index: Int, first: RecordRequest.Airing?, now: Date) -> String {
        let times = "\(DetailText.day(airing.programme.start, now: now)) \(airing.programme.timeRange)"
        if index == 0 { return "Best channel · \(times)" }
        guard let first, first.programme.startTime == airing.programme.startTime,
              first.programme.endTime == airing.programme.endTime else { return times }
        return "Same times"
    }
}

// MARK: Building a request

extension BrowseModel {
    /// A guide programme on its channel: Record, or Change recording when it is scheduled.
    func recordRequest(channel: GuideChannel, programme: GuideProgramme) -> RecordRequest {
        RecordRequest(title: programme.title, airings: [.init(channel: channel, programme: programme, quality: quality(of: channel))],
                      schedule: activeSchedule(channel: channel, programme: programme))
    }

    /// A Sport event (with its C-O/C-R card when there is one: the game's id, its teams and their logos): every channel
    /// carrying it that has not ended, best first; Change recording on the channel that is scheduled (`RecordPlan.bind`),
    /// or on `preferredChannel` when it is, else a new recording there.
    func recordRequest(event: SportEvent, game: SportsGame? = nil, team: String? = nil, now: Date = Date(),
                       preferredChannel: String? = nil) -> RecordRequest? {
        let channels = SportFrontText.recordChoices(event, now: now)
        let airings = (channels.isEmpty ? event.best.map { [$0] } ?? [] : channels).map { channel in
            RecordRequest.Airing(channel: recordingRow(event, on: channel), programme: event.programme(on: channel),
                                 quality: channel.quality)
        }
        guard !airings.isEmpty else { return nil }
        let teams: [RecordTeam]
        if let game, game.competitors.count == 2 {
            teams = game.competitors.map { RecordTeam(name: $0.name, logo: $0.cachedLogo) }
        } else if game == nil {
            let league = event.league.trimmingCharacters(in: .whitespaces)
            teams = RuleChoices.sport(title: event.title, league: event.league)
                .filter { $0.caseInsensitiveCompare(league) != .orderedSame }.prefix(2).map { RecordTeam(name: $0) }
        } else {
            teams = []
        }
        let front = sportFront.front
        // #49: the followed sides, all of them; the team named by the caller wins, never a guess between two.
        let followedTeams = game.map { game in
            game.followed == true
                ? SportFrontLayout.followedSides(game, names: front?.follows.map(\.name) ?? []).map { game.competitors[$0].name }
                : []
        } ?? []
        // A named team counts only when it is a side of this game (Codex 7a round 2): a driver or player follow on a
        // session card (F1, no competitors) names nobody a team rule could ever match, so no "every <name>" rule.
        let named = team.flatMap { team -> String? in
            if let game {
                guard game.competitors.count == 2 else { return nil }
                return SportFrontLayout.followedSide(game, names: [team]).map { game.competitors[$0].name }
            }
            return teams.first { $0.name.caseInsensitiveCompare(team) == .orderedSame }?.name
        }
        let followed = named ?? (followedTeams.count == 1 ? followedTeams[0] : nil)
        let bound = RecordPlan.bind(schedules: airings.map { activeSchedule(channel: $0.channel, programme: $0.programme) },
                                    channels: airings.map(\.channel.id), preferred: preferredChannel)
        var request = RecordRequest(title: event.title, league: event.league, airings: airings, gameId: game?.id, teams: teams,
                             followedTeam: followed, followedTeams: followedTeams,
                             sport: front?.sports.first { $0.league == event.league }?.sport, isGame: true,
                             schedule: bound.schedule)
        request.preferredChannel = bound.channel
        return request
    }
}

extension BrowseModel {
    /// The event on one chosen channel only (the Sports dashboard's "Record on <channel>").
    func recordRequest(event: SportEvent, on channel: SportEventChannel) -> RecordRequest? {
        recordRequest(event: SportEvent(id: event.id, title: event.title, league: event.league, startTime: event.startTime,
                                        endTime: event.endTime, channels: [channel], kind: event.kind))
    }
}

extension AppModel {
    /// Opens the record page for a Sport event (its card when there is one) through the app's presentation layer.
    func record(_ event: SportEvent, game: SportsGame? = nil, team: String? = nil, error: String? = nil,
                onChannel channel: String? = nil) {
        guard let browse, var request = browse.recordRequest(event: event, game: game, team: team, preferredChannel: channel) else { return }
        request.error = error
        presenter.present(.record(request))
    }
}

// MARK: The page

struct RecordPage: View {
    /// Not observed (audit R05): the page draws the action state and the logos.
    let model: BrowseModel
    @ObservedObject private var actions: ActionState
    /// The schedules, so Change recording follows its schedule while open (it starts recording, or ends).
    @ObservedObject private var store: RecordingsStore
    let presenter: AppPresenter
    let request: RecordRequest
    let close: () -> Void

    @State private var what: RecordPlan.What = .this
    @State private var before: Int?
    @State private var after: Int?
    @State private var airingIndex = 0
    @State private var error: String?
    @State private var busy = false
    private enum Focus: Hashable { case primary, cancel }
    @FocusState private var focus: Focus?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(model: BrowseModel, presenter: AppPresenter, request: RecordRequest, close: @escaping () -> Void) {
        self.model = model
        _actions = ObservedObject(wrappedValue: model.actions)
        _store = ObservedObject(wrappedValue: model.recordingStore)
        self.presenter = presenter
        self.request = request
        self.close = close
        _before = State(initialValue: request.schedule?.startEarly)
        _after = State(initialValue: request.schedule?.finishLate)
        _error = State(initialValue: request.error)
        _airingIndex = State(initialValue: request.preferredChannel.flatMap { id in
            request.airings.firstIndex { $0.channel.id == id }
        } ?? 0)
    }

    private var airing: RecordRequest.Airing? {
        request.airings.indices.contains(airingIndex) ? request.airings[airingIndex] : request.airings.first
    }
    private var changing: Bool { request.schedule != nil }
    /// Change recording's schedule as it is now (nil: gone, or not Change recording).
    private var live: ScheduledRecording? { request.schedule.flatMap { RecordPlan.live($0, in: model.schedules) } }
    private var gone: Bool { changing && live == nil }
    /// Busy, or Change recording with nothing changed.
    private var saveOff: Bool {
        busy || (changing && live.flatMap { RecordPlan.change($0, before: before, after: after) } == nil)
    }
    private var leagueLabel: String? { request.league.flatMap { model.sportFront.labels[$0] } }

    var body: some View {
        let now = Date()
        ZStack {
            PigPageBackground().ignoresSafeArea()
            ScrollView {
                card(now: now)
                    .frame(maxWidth: Metrics.cardWidth)
                    .padding(Metrics.outer)
                    .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
        }
        #if os(tvOS)
        .buttonStyle(PigSecondaryButtonStyle())
        #endif
        .presentationBackground { PigPageBackground() }
        .interactiveDismissDisabled(busy)
        .defaultFocus($focus, changing ? .cancel : .primary)
        .accessibilityIdentifier("record.page")
        // Codex 5a round 1: once it records, Start early shows (and keeps) the schedule's own value, never an edit that
        // the server would refuse; the list is refreshed while Change recording is open.
        .onChange(of: live?.status) { _, status in
            if status == "recording" { before = live?.startEarly }
        }
        .task(id: changing) {
            guard changing, !model.isFixture else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await model.loadRecordingsIfStale(maxAge: 19, quietly: true) // #239: shared with any other page
            }
        }
    }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            header(now: now)
            let whats = RecordPlan.whats(request)
            if !whats.isEmpty { whatSection(whats, now: now) }
            stopSection(now: now)
            if !changing && request.airings.count > 1 { recordOn(now: now) }
            Text(changing ? changeNote : RecordPlan.streamNote(airing, before: before, now: now))
                .font(Metrics.note).foregroundStyle(Color.pigSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(Metrics.note.weight(.semibold)).foregroundStyle(Color.pigWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("record.error")
            }
            buttons
        }
        .padding(Metrics.padding)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .shadow(color: Color.pigShadow.opacity(0.5), radius: 40, y: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(changing ? "Change recording of \(request.title)" : "Record \(request.title)")
    }

    private var changeNote: String {
        guard changing else { return "" }
        guard let schedule = live else { return RecordPlan.goneText }
        return RecordPlan.canChangeStartEarly(schedule)
            ? "Changes apply to this recording only."
            : "It is recording: only Finish late can change."
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: Metrics.headerGap) {
            if request.teams.count == 2 {
                HStack(spacing: PigSpacing.s) {
                    ForEach(Array(request.teams.enumerated()), id: \.offset) { _, team in
                        SportBadge(name: team.name, logo: team.logo, league: request.league ?? "", client: model.client,
                                   size: Metrics.badge)
                    }
                }
                .accessibilityHidden(true)
            } else if let airing {
                ChannelLogoTile(logo: model.logo(for: airing.channel), client: model.client, name: airing.channel.name,
                                size: DetailMetrics.smallLogo)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                // Two lines on a narrow screen rather than "CHANGE RECORDING · RECOR…".
                Text(kicker).font(Metrics.kicker).tracking(2).foregroundStyle(Color.pigSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.title).font(Metrics.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let airing {
                    Text("\(DetailText.day(airing.programme.start, now: now)) · \(airing.programme.timeRange) · \(airing.channel.name)")
                        .font(Metrics.meta).foregroundStyle(Color.pigSecondary).monospacedDigit().fontDesign(.rounded)
                        .lineLimit(2)
                }
            }
        }
    }

    private var kicker: String {
        var parts = [changing ? "CHANGE RECORDING" : "RECORD"]
        if let schedule = live ?? request.schedule { parts.append(gone ? "ENDED" : schedule.statusWord.uppercased()) }
        if let league = leagueLabel ?? request.league { parts.append(league.uppercased()) }
        return parts.joined(separator: " · ")
    }

    // MARK: What

    private func whatSection(_ whats: [RecordPlan.What], now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            sectionTitle("What")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PigSpacing.m, alignment: .top), count: whatColumns(whats.count)),
                      alignment: .leading, spacing: PigSpacing.m) {
                ForEach(whats, id: \.self) { option in
                    let label = RecordPlan.label(option, request: request, leagueLabel: leagueLabel, now: now)
                    Button { what = option } label: {
                        VStack(alignment: .leading, spacing: PigSpacing.xs) {
                            Text(label.title).font(Metrics.choice).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(label.detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).lineLimit(2)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: Metrics.choiceHeight, alignment: .leading)
                        .modifier(Selected(on: what == option))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                    .accessibilityLabel("\(label.title), \(label.detail)")
                    .accessibilityAddTraits(what == option ? .isSelected : [])
                    .accessibilityIdentifier("record.what.\(whatID(option))")
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func whatColumns(_ count: Int) -> Int {
        #if os(tvOS)
        min(count, 4)
        #else
        sizeClass == .regular ? min(count, 3) : 1
        #endif
    }

    private func whatID(_ what: RecordPlan.What) -> String {
        switch what {
        case .this: "this"
        case .everyNewEpisode: "newEpisodes"
        case .everyEpisode: "episodes"
        case .everyTeam: "team"
        case .everyLeague: "league"
        }
    }

    // MARK: When it stops

    private func stopSection(now: Date) -> some View {
        let lines = RecordPlan.stopLines(request, airing: airing, now: now)
        return VStack(alignment: .leading, spacing: PigSpacing.s) {
            sectionTitle("When it stops")
            HStack(spacing: PigSpacing.m) {
                Circle().strokeBorder(Color.pigAccent, lineWidth: 3)
                    .overlay { Circle().fill(Color.pigAccent).padding(PigSpacing.xs) }
                    .frame(width: Metrics.radio, height: Metrics.radio)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(lines.title).font(Metrics.choice)
                    Text(lines.detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigAccent, lineWidth: 2) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("record.stop")
            let startLocked = changing && (live.map { !RecordPlan.canChangeStartEarly($0) } ?? true)
            chipRow("Start early", RecordPlan.chips(RecordPlan.startEarly, current: request.schedule?.startEarly, changing: changing),
                    selection: $before, id: "before", locked: startLocked)
            chipRow("Finish late", RecordPlan.chips(RecordPlan.finishLate, current: request.schedule?.finishLate, changing: changing),
                    selection: $after, id: "after", locked: gone)
        }
    }

    private func chipRow(_ title: String, _ options: [Int?], selection: Binding<Int?>, id: String, locked: Bool) -> some View {
        #if os(tvOS)
        let chips = ForEach(options, id: \.self) { minutes in
            Button { selection.wrappedValue = minutes } label: {
                Text(RecordPlan.chipTitle(minutes)).lineLimit(1).fixedSize().monospacedDigit()
            }
            .buttonStyle(GuideFilterStyle(selected: selection.wrappedValue == minutes))
            .disabled(locked)
            .accessibilityLabel("\(title): \(RecordPlan.chipTitle(minutes))")
            .accessibilityIdentifier("record.\(id).\(minutes.map(String.init) ?? "usual")")
            .id(chipID(id, minutes))
        }
        #endif
        return Group {
            #if os(tvOS)
            HStack(spacing: PigSpacing.s) {
                Text(title).font(Metrics.rowLabel).foregroundStyle(Color.pigSecondary).frame(width: 170, alignment: .leading)
                chips
            }
            .focusSection()
            #else
            // #253 (Mark, 8 Nov: a menu per row): one line each, the choice on the right; a sideways row of chips ran
            // past the card's edge on iPhone, and wrapping them looked cluttered.
            HStack {
                Text(title).font(Metrics.rowLabel).foregroundStyle(Color.pigSecondary)
                Spacer(minLength: PigSpacing.m)
                Menu {
                    Picker(title, selection: selection) {
                        ForEach(options, id: \.self) { minutes in
                            Text(RecordPlan.chipTitle(minutes)).tag(minutes)
                                .accessibilityIdentifier("record.\(id).\(minutes.map(String.init) ?? "usual")")
                        }
                    }
                } label: {
                    HStack(spacing: PigSpacing.xs) {
                        Text(RecordPlan.chipTitle(selection.wrappedValue)).monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    }
                    .font(Metrics.rowLabel)
                }
                .disabled(locked)
                .accessibilityLabel("\(title): \(RecordPlan.chipTitle(selection.wrappedValue))")
                .accessibilityIdentifier("record.\(id)")
            }
            .padding(.vertical, PigSpacing.xs)
            #endif
        }
        .opacity(locked ? 0.5 : 1)
    }

    private func chipID(_ row: String, _ minutes: Int?) -> String { "\(row).\(minutes.map(String.init) ?? "usual")" }

    // MARK: Record on

    private func recordOn(now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Record on")
                Spacer()
                Text("\(request.airings.count) channels in your guide carry it").font(Metrics.choiceDetail)
                    .foregroundStyle(Color.pigSecondary)
            }
            ForEach(Array(request.airings.enumerated()), id: \.element.id) { index, option in
                let on = index == airingIndex
                let detail = RecordPlan.airingDetail(option, index: index, first: request.airings.first, now: now)
                Button { airingIndex = index } label: {
                    HStack(spacing: PigSpacing.m) {
                        Circle().strokeBorder(on ? Color.pigAccent : Color.pigSecondary, lineWidth: 3)
                            .overlay { if on { Circle().fill(Color.pigAccent).padding(PigSpacing.xs) } }
                            .frame(width: Metrics.radio, height: Metrics.radio)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                            Text(option.channel.name).font(Metrics.choice).lineLimit(1)
                            Text(detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).monospacedDigit().lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let quality = option.quality {
                            Text(quality.rawValue).font(Metrics.badgeFont).tracking(1)
                                .foregroundStyle(quality == .uhd ? Color.pigOnAccent : Color.pigSecondary)
                                .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                                .background(quality == .uhd ? Color.pigAccent : Color.pigRaised,
                                            in: RoundedRectangle(cornerRadius: PigRadius.inner))
                        }
                    }
                    .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(Selected(on: on))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                .accessibilityLabel("\(option.channel.name), \(detail)\(option.quality.map { ", \($0.spoken)" } ?? "")")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("record.on.\(index)")
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: Buttons

    /// The actions: in a row, or stacked full width on a compact width (an upright iPhone), where a row wrapped.
    @ViewBuilder
    private var buttons: some View {
        #if os(tvOS)
        HStack(spacing: PigSpacing.m) { actionButtons(stacked: false) }
            .focusSection()
        #else
        if sizeClass == .regular {
            HStack(spacing: PigSpacing.l) { actionButtons(stacked: false) }
        } else {
            VStack(spacing: PigSpacing.m) { actionButtons(stacked: true) }
        }
        #endif
    }

    @ViewBuilder
    private func actionButtons(stacked: Bool) -> some View {
        Button { Task { await primary() } } label: {
            Label(RecordPlan.primaryTitle(what, request: request), systemImage: changing ? "checkmark.circle" : "record.circle")
                .lineLimit(1)
                .frame(maxWidth: stacked ? .infinity : nil)
        }
        .pigPrimaryButton()
        .disabled(saveOff)
        #if os(tvOS)
        // The tvOS primary style draws no disabled look of its own; the iOS glass button dims itself.
        .opacity(saveOff ? 0.45 : 1)
        #endif
        .focused($focus, equals: .primary)
        .accessibilityIdentifier("record.schedule")
        if changing {
            Button { if let live { cancel(live) } } label: {
                Label(live?.status == "recording" ? "Stop recording" : "Cancel recording", systemImage: "xmark.circle")
                    .lineLimit(1)
                    .frame(maxWidth: stacked ? .infinity : nil)
            }
            .foregroundStyle(Color.pigDanger)
            .disabled(busy || gone)
            .opacity(gone ? 0.45 : 1)
            .focused($focus, equals: .cancel)
            .accessibilityIdentifier("record.cancelRecording")
        }
        Button { close() } label: {
            Text(changing ? "Close" : "Cancel").lineLimit(1).frame(maxWidth: stacked ? .infinity : nil)
        }
        .disabled(busy)
        .accessibilityIdentifier("record.close")
        if busy { ProgressView() }
    }

    private func primary() async {
        busy = true
        error = nil
        defer { busy = false }
        if changing {
            guard let schedule = live else { error = RecordPlan.goneText; return }
            guard let change = RecordPlan.change(schedule, before: before, after: after) else { return }
            if await model.changeSchedule(schedule, change) { close() } else { error = model.actionError ?? "The recording could not be changed." }
            return
        }
        guard let airing else { return }
        if let rule = RecordPlan.rule(what, request: request, before: before, after: after) {
            if await model.addRule(rule) { close() } else { error = model.actionError ?? "The rule could not be added." }
            return
        }
        if await model.schedule(channel: airing.channel, programme: airing.programme, before: before, after: after,
                                gameId: request.gameId) {
            close()
        } else {
            error = model.actionError ?? "The recording could not be scheduled."
        }
    }

    /// At once, with Undo (D-44 point 9): the page closes, the schedule leaves the lists and the guide at once, and the
    /// cancel is sent when the Undo runs out, waiting for any change still in flight (`BrowseModel.cancelWithUndo`).
    private func cancel(_ schedule: ScheduledRecording) {
        let model = self.model
        let presenter = self.presenter
        close()
        model.cancelWithUndo(schedule, presenter: presenter)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Metrics.section).foregroundStyle(Color.pigSecondary).accessibilityAddTraits(.isHeader)
    }

    /// The selection (D-44 brand): a 14 % pink fill and a short bar on the leading edge, never a tick.
    private struct Selected: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content
                .background(on ? Color.pigAccent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
                .overlay(alignment: .leading) {
                    if on {
                        Capsule().fill(Color.pigAccent).frame(width: 4).padding(.vertical, PigSpacing.s)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private enum Metrics {
        #if os(tvOS)
        static let cardWidth: CGFloat = 1180
        static let outer: CGFloat = 36
        static let padding = EdgeInsets(top: 34, leading: 52, bottom: 34, trailing: 52)
        static let gap: CGFloat = 18
        static let section: Font = .system(size: PigType.secondary, weight: .bold)
        static let headerGap: CGFloat = 26
        static let badge: CGFloat = 64
        static let kicker: Font = .system(size: PigType.kicker, weight: .bold)
        static let title: Font = .system(size: PigType.display, weight: .heavy)
        static let meta: Font = .system(size: PigType.secondary)
        static let choice: Font = .system(size: PigType.body, weight: .bold)
        static let choiceDetail: Font = .system(size: PigType.caption)
        static let choiceHeight: CGFloat = 68
        static let rowLabel: Font = .system(size: PigType.secondary, weight: .semibold)
        static let note: Font = .system(size: PigType.caption)
        static let radio: CGFloat = 26
        static let badgeFont: Font = .system(size: PigType.caption, weight: .heavy)
        #else
        static let cardWidth: CGFloat = 760
        static let outer: CGFloat = 16
        static let padding = EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        static let gap: CGFloat = 16
        static let section: Font = .subheadline.weight(.bold)
        static let headerGap: CGFloat = 14
        static let badge: CGFloat = 40
        static let kicker: Font = .caption.weight(.bold)
        static let title: Font = .title2.weight(.heavy)
        static let meta: Font = .subheadline
        static let choice: Font = .subheadline.weight(.bold)
        static let choiceDetail: Font = .caption
        static let choiceHeight: CGFloat = 54
        static let rowLabel: Font = .caption.weight(.semibold)
        static let note: Font = .footnote
        static let radio: CGFloat = 20
        static let badgeFont: Font = .caption2.weight(.heavy)
        #endif
    }

}
