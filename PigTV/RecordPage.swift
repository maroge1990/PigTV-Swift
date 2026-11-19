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
        /// D-65 (#265): the measured quality, else nil (the badge then comes from `quality`).
        var measured: MeasuredQuality? = nil
        /// D-65 (#266): the server's name key, else nil (grouped on the name).
        var nameKey: String? = nil
        /// C-R #353: the airing's own guide end when the card's `end` is rolled on (an overrun); nil: the programme's end.
        var guideEnd: Double? = nil
        /// A channel can carry several airings (a Test's two days, C-R `slots`): each is its own choice.
        var id: String { "\(channel.id)@\(Int64(programme.startTime))" }
        var chip: QualityChip? { QualityChip.make(measured: measured, quality: quality) }
        /// Its guide bounds (C-R #353): what schedules and cancellations are matched by, never the rolled end.
        var guideBounds: (start: Double, end: Double) { (programme.startTime, guideEnd ?? programme.endTime) }
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
    /// C-R #353: the card's `recordingCancelling` (its game's schedules being cancelled, with their guide slots); nil when
    /// the card has none or the server is older (then the client's own inference decides Cancelling…).
    var serverCancelling: [SportsGame.CancellingSlot]? = nil
    /// When the request was built (its card's `recordingCancelling` is that old, or older).
    var builtAt = Date()
    /// Shown on opening (a quick Record from a menu that failed).
    var error: String? = nil
    /// The channel to start on (a channel row's "Record on <channel>"), by its id; else the best.
    var preferredChannel: String? = nil
    /// A sport request's bound schedule per airing (`Airing.id`), when it has several: the page is Change recording for
    /// a chosen airing that has one and Record for one that has none (Codex review of #347). Nil: `schedule` is the
    /// whole request's (a guide programme).
    var airingSchedules: [String: ScheduledRecording]? = nil
    /// The airing to start on (`Airing.id`: its channel and guide start), when the bound schedule is one of several
    /// airings of that channel (C-R `slots`); else the first airing of `preferredChannel`.
    var preferredAiring: String? = nil
    /// #345: a game to come that the guide does not list yet (#234), with no airings: "This game" is its `game` rule.
    var listing: Listing? = nil

    /// #345: Record when it's listed (or Don't record it, once set) on the record page, as the card's question did.
    struct Listing: Sendable {
        let game: SportsGame
        let offer: SportFutureRecord.Offer
        /// This device's answer, so the cards say it at once: the rule added, or nil once removed (`SportPresenter`).
        var answered: @MainActor @Sendable (Int?) -> Void = { _ in }
    }

    var id: String {
        if let listing { return "listing|\(listing.game.id)" }
        return "\(schedule.map { "s\($0.id)" } ?? "new")|\(airings.first?.id ?? "")|\(Int64(airings.first?.programme.startTime ?? 0))"
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

    /// A What tile's lines: its title and, for the one-off choices, the time or what repeats.
    static func label(_ what: What, request: RecordRequest, leagueLabel: String? = nil, now: Date) -> (title: String, detail: String?) {
        switch what {
        case .this:
            let start = request.airings.first?.programme.start ?? request.listing.map { SportFrontText.date($0.game.start) }
            let when = start.map { "\(DetailText.day($0, now: now)) \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return (request.isGame || request.league != nil ? "This game" : "This programme", when)
        case .everyNewEpisode:
            return ("Every new episode", nil)
        case .everyEpisode:
            return ("Every episode", "Repeats as well")
        case .everyTeam(let team):
            return ("Every \(team) game", nil)
        case .everyLeague(let league):
            let name = leagueLabel ?? league
            return (request.teams.count == 2 ? "Every \(name) game" : "Everything in \(name)", nil)
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
    /// A channel can carry several airings (C-R `slots`): the airing returned (`index`) is the one whose schedule is bound,
    /// so the page opens on it (a Test's scheduled day two, not day one), matched by channel plus guide start.
    static func bind(schedules: [ScheduledRecording?], channels: [String], preferred: String?)
        -> (schedule: ScheduledRecording?, channel: String?, index: Int?) {
        if let preferred {
            let indices = channels.indices.filter { channels[$0] == preferred }
            if let first = indices.first {
                let index = indices.first { schedules.indices.contains($0) && schedules[$0] != nil } ?? first
                return (schedules.indices.contains(index) ? schedules[index] : nil, preferred, index)
            }
        }
        for (index, schedule) in schedules.enumerated() where schedule != nil && channels.indices.contains(index) {
            return (schedule, channels[index], index)
        }
        return (nil, nil, nil)
    }

    /// The request as the page shows it for the airing at `index` (Codex review of #347): with several airings, Change
    /// recording when that airing has its schedule, else Record (another day of a Test stays recordable while one day is
    /// set to record); a guide programme's request as it is.
    static func forAiring(_ opened: RecordRequest, _ index: Int) -> RecordRequest {
        guard let perAiring = opened.airingSchedules, opened.airings.indices.contains(index) else { return opened }
        var shown = opened
        shown.schedule = perAiring[opened.airings[index].id]
        return shown
    }

    /// The airing the page opens on: the bound airing (`preferredAiring`), else the first of `preferredChannel`, else the best.
    static func openingAiring(_ request: RecordRequest) -> Int {
        request.preferredAiring.flatMap { id in request.airings.firstIndex { $0.id == id } }
            ?? request.preferredChannel.flatMap { id in request.airings.firstIndex { $0.channel.id == id } }
            ?? 0
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

    /// When it stops, in words (#341: one line; the guide end and Finish late are not repeated under it).
    static func stopTitle(_ request: RecordRequest) -> String {
        stopsWithGame(request) ? "When the game ends (ESPN)" : "When the guide says it ends"
    }

    /// #345: the note under a game the guide does not list yet (the words of #234's question).
    /// #341: only the offer to record says anything; a game already set to record has no note.
    static func listingNote(_ listing: RecordRequest.Listing) -> String? {
        listing.offer == .record
            ? "It isn't in the TV guide yet. PigTV records it on its best channel as soon as it's listed."
            : nil
    }

    /// The primary button.
    static func primaryTitle(_ what: What, request: RecordRequest) -> String {
        if request.schedule != nil { return "Save changes" }
        if what == .this, let listing = request.listing {
            return listing.offer == .record ? SportFutureRecord.recordTitle : SportFutureRecord.cancelTitle
        }
        switch what {
        case .this: return request.isGame || request.league != nil ? "Record game" : "Record programme"
        case .everyNewEpisode: return "Record every new episode"
        case .everyEpisode: return "Record every episode"
        case .everyTeam, .everyLeague: return "Record every game"
        }
    }

    /// A programme already on air: only the rest of it is recorded. #341: no line about waiting for a provider connection.
    static func streamNote(_ airing: RecordRequest.Airing?, now: Date) -> String? {
        guard let programme = airing?.programme, programme.start <= now else { return nil }
        return "It has started: only the rest of it is recorded."
    }

    /// D-65 (#266): Record on's rows: one per channel name, its copies' qualities as chips (best first; copies with the
    /// same name and quality fold into one chip). Each copy is its index in `request.airings`; a chip selects its first.
    static func channelGroups(_ request: RecordRequest) -> [ChannelNameGroup<Int>] {
        // C-R #353 `slots`: a channel with several airings (a Test's two days) is a row per airing, each with its day.
        let repeated = Set(Dictionary(grouping: request.airings, by: \.channel.id).filter { $0.value.count > 1 }.keys)
        return ChannelGrouping.group(Array(request.airings.indices), name: { request.airings[$0].channel.name },
                              serverKey: { index in
                                  let airing = request.airings[index]
                                  guard repeated.contains(airing.channel.id) else { return airing.nameKey }
                                  return "\(airing.nameKey ?? airing.channel.name)@\(Int64(airing.programme.startTime))"
                              },
                              airing: { (start: request.airings[$0].programme.startTime, end: request.airings[$0].programme.endTime) },
                              chip: { request.airings[$0].chip })
    }

    /// Record on's note: one channel's qualities; nil when several channels carry it (#341: the count is not said).
    static func recordOnNote(_ groups: [ChannelNameGroup<Int>]) -> String? {
        guard groups.count == 1 else { return nil }
        let qualities = groups[0].choices.count
        return qualities > 1 ? "1 channel in your guide carries it, in \(qualities) qualities" : "1 channel in your guide carries it"
    }

    /// Record on's second line for one channel: its times, unless they are the first channel's (#341: no "Best channel",
    /// no "Same times").
    static func airingDetail(_ airing: RecordRequest.Airing, index: Int, first: RecordRequest.Airing?, now: Date) -> String? {
        let times = "\(DetailText.day(airing.programme.start, now: now)) \(airing.programme.timeRange)"
        if index == 0 { return times }
        guard let first, first.programme.startTime == airing.programme.startTime,
              first.programme.endTime == airing.programme.endTime else { return times }
        return nil
    }
}

// MARK: Building a request

extension BrowseModel {
    /// A guide programme on its channel: Record, or Change recording when it is scheduled.
    func recordRequest(channel: GuideChannel, programme: GuideProgramme) -> RecordRequest {
        RecordRequest(title: programme.title, airings: [.init(channel: channel, programme: programme, quality: quality(of: channel),
                                                              measured: channel.measured?.known, nameKey: channel.nameKey)],
                      // Never Change recording of a schedule whose cancellation is in progress: the page shows
                      // Cancelling… then (Codex check of 320).
                      schedule: bindableSchedule(channel: channel, programme: programme))
    }

    /// A Sport event (with its C-O/C-R card when there is one: the game's id, its teams and their logos): every channel
    /// carrying it that has not ended, best first; Change recording on the channel that is scheduled (`RecordPlan.bind`),
    /// or on `preferredChannel` when it is, else a new recording there.
    /// `card` (#347): a sport page item's front card id, the recording's game when there is no card (`game`) itself.
    func recordRequest(event: SportEvent, game: SportsGame? = nil, team: String? = nil, now: Date = Date(),
                       preferredChannel: String? = nil, card: String? = nil) -> RecordRequest? {
        // C-R #353: the card's `slots` (each later airing of its channels too, a Test's day two), else its channels.
        let offered = game.flatMap { $0.slots?.value }.flatMap { $0.isEmpty ? nil : $0 }
            .map { SportEvent(id: event.id, title: event.title, league: event.league, startTime: event.startTime,
                              endTime: event.endTime, channels: $0, kind: event.kind, serverEventID: event.serverEventID) } ?? event
        let channels = SportFrontText.recordChoices(offered, now: now)
        let airings = (channels.isEmpty ? offered.best.map { [$0] } ?? [] : channels).map { channel in
            RecordRequest.Airing(channel: recordingRow(offered, on: channel), programme: offered.programme(on: channel),
                                 quality: channel.quality, measured: channel.measured, nameKey: channel.nameKey,
                                 guideEnd: channel.guideEndTime)
        }
        guard !airings.isEmpty else { return nil }
        let sides = recordSides(title: event.title, league: event.league, game: game, team: team)
        // A schedule whose cancellation is in progress is never bound as Change recording (the page waits with
        // Cancelling… until its outcome is known, Mark, 19 Nov 2026).
        // The card's game binds first (Codex review of #347, high): a row naming another game is never this one's.
        let gameId = game?.id ?? card
        let perAiring = airings.map { bindableSchedule(channel: $0.channel, programme: $0.programme, gameId: gameId) }
        let bound = RecordPlan.bind(schedules: perAiring,
                                    channels: airings.map(\.channel.id), preferred: preferredChannel)
        var request = RecordRequest(title: event.title, league: event.league, airings: airings, gameId: gameId,
                                    teams: sides.teams, followedTeam: sides.followed, followedTeams: sides.followedTeams,
                                    sport: sportFront.front?.sports.first { $0.league == event.league }?.sport, isGame: true,
                                    schedule: bound.schedule)
        request.preferredChannel = bound.channel
        request.preferredAiring = bound.index.map { airings[$0].id }
        if airings.count > 1 {
            request.airingSchedules = Dictionary(zip(airings, perAiring).compactMap { airing, schedule in
                schedule.map { (airing.id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        request.serverCancelling = game?.recordingCancelling?.value
        return request
    }

    /// #345: a game to come that the guide does not list yet (#234): the page with no airings, "This game" its `game`
    /// rule. Nil when there is nothing to offer (it has a listing, has started, or is not a two-sided game).
    func recordRequest(listing game: SportsGame, team: String? = nil, answered: SportFutureRecord.Answer? = nil,
                       now: Date = Date(), note: @escaping @MainActor @Sendable (Int?) -> Void = { _ in }) -> RecordRequest? {
        guard let offer = SportFutureRecord.offer(game, now: now, answered: answered) else { return nil }
        let sides = recordSides(title: game.title, league: game.league, game: game, team: team)
        return RecordRequest(title: game.title, league: game.league, airings: [], gameId: game.id, teams: sides.teams,
                             followedTeam: sides.followed, followedTeams: sides.followedTeams,
                             sport: sportFront.front?.sports.first { $0.league == game.league }?.sport, isGame: true,
                             listing: .init(game: game, offer: offer, answered: note))
    }

    /// A game's teams for the header and the team rules, and the team those rules follow (#49).
    private func recordSides(title: String, league: String, game: SportsGame?, team: String?)
        -> (teams: [RecordTeam], followed: String?, followedTeams: [String]) {
        let teams: [RecordTeam]
        if let game, game.competitors.count == 2 {
            teams = game.competitors.map { RecordTeam(name: $0.name, logo: $0.cachedLogo) }
        } else if game == nil {
            let trimmed = league.trimmingCharacters(in: .whitespaces)
            teams = RuleChoices.sport(title: title, league: league)
                .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }.prefix(2).map { RecordTeam(name: $0) }
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
        return (teams, followed, followedTeams)
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
    /// `card` (#347): a sport page item's front card id (an F1 session, a fixture, a cricket match), sent as its `gameId`.
    func record(_ event: SportEvent, game: SportsGame? = nil, team: String? = nil, error: String? = nil,
                onChannel channel: String? = nil, card: String? = nil) {
        guard let browse, var request = browse.recordRequest(event: event, game: game, team: team, preferredChannel: channel,
                                                             card: card) else { return }
        request.error = error
        presenter.present(.record(request))
    }

    /// #345: the record page of a game the guide does not list yet (Record when it's listed); the Sport screen's
    /// presenter hears the answer, so its cards change at once (Apple 154).
    func recordWhenListed(_ game: SportsGame, team: String? = nil, presenter sport: SportPresenter?) {
        guard let browse,
              let request = browse.recordRequest(listing: game, team: team, answered: sport?.futureAnswer(game),
                                                 note: { [weak sport] rule in sport?.noteFuture(game, rule: rule) })
        else { return }
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
    /// The request as opened; `request` is it for the chosen airing (`RecordPlan.forAiring`).
    let opened: RecordRequest
    let close: () -> Void
    private var request: RecordRequest { RecordPlan.forAiring(opened, airingIndex) }

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
        self.opened = request
        self.close = close
        _before = State(initialValue: request.schedule?.startEarly)
        _after = State(initialValue: request.schedule?.finishLate)
        _error = State(initialValue: request.error)
        _airingIndex = State(initialValue: RecordPlan.openingAiring(request))
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
    /// #345: "Don't record it" (a game set to record once listed): nothing to pad.
    private var stopsWaiting: Bool { what == .this && request.listing?.offer != nil && request.listing?.offer != .record }

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
        // Another airing chosen: its own schedule's padding (Change recording), else the usual, and "This game".
        .onChange(of: airingIndex) {
            before = request.schedule?.startEarly
            after = request.schedule?.finishLate
            what = .this
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
            if !stopsWaiting { stopSection(now: now) }
            // Codex review of #347: a sport request's airings stay choosable while one of them is set to record.
            if request.airings.count > 1 && (!changing || opened.airingSchedules != nil) { recordOn(now: now) }
            if let note = cardNote(now: now) {
                Text(note).font(Metrics.note).foregroundStyle(Color.pigSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(Metrics.note.weight(.semibold)).foregroundStyle(Color.pigWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("record.error")
            }
            buttons
        }
        .padding(Metrics.padding)
        // #340: flat, as the rest of the app: no drop shadow, and on a compact iPhone the page itself is the surface
        // (the raised card inside the full-screen sheet read as a second, shadowed layer).
        .background(sizeClass == .compact ? Color.clear : Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(changing ? "Change recording of \(request.title)" : "Record \(request.title)")
    }

    /// The one note under the choices, if any (#341).
    private func cardNote(now: Date) -> String? {
        if changing { return changeNote }
        if let listing = request.listing { return RecordPlan.listingNote(listing) }
        return RecordPlan.streamNote(airing, now: now)
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
                        .font(Metrics.meta).foregroundStyle(Color.pigSecondary).pigFigures()
                        .lineLimit(2)
                } else if let listing = request.listing {
                    let start = SportFrontText.date(listing.game.start)
                    Text("\(DetailText.day(start, now: now)) · \(start.formatted(date: .omitted, time: .shortened)) · \(SportFrontText.channelLine(listing.game))")
                        .font(Metrics.meta).foregroundStyle(Color.pigSecondary).pigFigures()
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
                            if let detail = label.detail {
                                Text(detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).lineLimit(2)
                                    .pigFigures()
                            }
                        }
                        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: Metrics.choiceHeight, alignment: .leading)
                        .modifier(Selected(on: what == option))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                    .accessibilityLabel(label.detail.map { "\(label.title), \($0)" } ?? label.title)
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
        return VStack(alignment: .leading, spacing: PigSpacing.s) {
            sectionTitle("When it stops")
            HStack(spacing: PigSpacing.m) {
                Circle().strokeBorder(Color.pigAccent, lineWidth: 3)
                    .overlay { Circle().fill(Color.pigAccent).padding(PigSpacing.xs) }
                    .frame(width: Metrics.radio, height: Metrics.radio)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(RecordPlan.stopTitle(request)).font(Metrics.choice)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
            .background(Color.pigSelection, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
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
                Text(RecordPlan.chipTitle(minutes)).lineLimit(1).fixedSize().pigFigures()
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
                        Text(RecordPlan.chipTitle(selection.wrappedValue)).pigFigures()
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
            let groups = RecordPlan.channelGroups(request)
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Record on")
                Spacer()
                if let note = RecordPlan.recordOnNote(groups) {
                    Text(note).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary)
                }
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                let on = group.indices.contains(airingIndex)
                // The row's words follow the copy chosen in it, else its best.
                let shown = on ? airingIndex : group.best.copy
                let option = request.airings[shown]
                let detail = RecordPlan.airingDetail(option, index: index, first: request.airings.first, now: now)
                if group.choosesQuality {
                    recordOnChips(group, index: index, option: option, detail: detail, on: on)
                } else {
                    Button { airingIndex = group.best.copy } label: {
                        HStack(spacing: PigSpacing.m) {
                            radio(on)
                            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                                Text(option.channel.name).font(Metrics.choice).lineLimit(1)
                                if let detail {
                                    Text(detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if let chip = option.chip { QualityBadge(chip: chip, font: Metrics.badgeFont) }
                        }
                        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(Selected(on: on))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card))
                    .accessibilityLabel("\(option.channel.name)\(detail.map { ", \($0)" } ?? "")\(option.chip.map { ", \($0.spoken)" } ?? "")")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("record.on.\(index)")
                }
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func radio(_ on: Bool) -> some View {
        Circle().strokeBorder(on ? Color.pigAccent : Color.pigSecondary, lineWidth: 3)
            .overlay { if on { Circle().fill(Color.pigAccent).padding(PigSpacing.xs) } }
            .frame(width: Metrics.radio, height: Metrics.radio)
            .accessibilityHidden(true)
    }

    /// D-65 (#266): a channel name carried in several qualities: one row, a chip per quality (best first) that chooses
    /// that copy; the radio shows whether any of its copies is the one chosen.
    private func recordOnChips(_ group: ChannelNameGroup<Int>, index: Int, option: RecordRequest.Airing, detail: String?,
                               on: Bool) -> some View {
        HStack(spacing: PigSpacing.m) {
            radio(on)
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                Text(option.channel.name).font(Metrics.choice).lineLimit(1)
                if let detail {
                    Text(detail).font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(1)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: PigSpacing.s) {
                        ForEach(Array(group.choices.enumerated()), id: \.element.id) { chipIndex, choice in
                            let picked = choice.indices.contains(airingIndex)
                            Button { airingIndex = choice.copy } label: {
                                HStack(spacing: PigSpacing.xs) {
                                    if let chip = choice.chip {
                                        QualityBadge(chip: chip, font: Metrics.badgeFont)
                                    } else {
                                        Text("Other").font(Metrics.badgeFont).foregroundStyle(Color.pigSecondary)
                                    }
                                    // A copy airing at another time than the row's shows its start.
                                    if group.startsDifferently(choice) {
                                        Text(request.airings[choice.copy].programme.start.formatted(date: .omitted, time: .shortened))
                                            .font(Metrics.choiceDetail).foregroundStyle(Color.pigSecondary).pigFigures()
                                    }
                                }
                                .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                                .background(picked ? Color.pigSelection : .clear,
                                            in: RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.compact, lift: .control))
                            .accessibilityLabel("\(option.channel.name), \(choice.chip?.spoken ?? "other quality")"
                                                + (group.startsDifferently(choice)
                                                   ? ", starts \(request.airings[choice.copy].programme.start.formatted(date: .omitted, time: .shortened))" : ""))
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .accessibilityIdentifier("record.on.\(index).\(chipIndex)")
                        }
                    }
                    .padding(.vertical, PigSpacing.xxs)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Selected(on: on))
        #if os(tvOS)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record.on.\(index)")
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

    /// Mark, 19 Nov 2026: an earlier recording of this (the game, or this channel's overlapping airing) is being
    /// cancelled: Record and Change recording wait until its outcome is known.
    /// The chosen airing waits (C-R #353: other airings, another day of a Test, stay recordable).
    private var cancelling: Bool { airing.map { model.cancellingEarlier(request, airing: $0) } ?? false }

    @ViewBuilder
    private func actionButtons(stacked: Bool) -> some View {
        if cancelling {
            Button {} label: {
                Label(PageWords.cancelling, systemImage: "hourglass").lineLimit(1).frame(maxWidth: stacked ? .infinity : nil)
            }
            .pigSecondaryButton()
            .disabled(true)
            #if os(tvOS)
            .opacity(0.45)
            #endif
            .accessibilityLabel(PageWords.cancellingLabel)
            .accessibilityIdentifier("record.cancelling")
        } else {
            primaryButton(stacked: stacked)
        }
        secondaryButtons(stacked: stacked)
    }

    @ViewBuilder
    private func primaryButton(stacked: Bool) -> some View {
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
    }

    @ViewBuilder
    private func secondaryButtons(stacked: Bool) -> some View {
        if changing {
            Button {
                guard let live else { return }
                if model.stillBinds(live, request) { cancel(live) } else { error = PageWords.bindingChangedText }
            } label: {
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
            guard model.stillBinds(schedule, request) else { error = PageWords.bindingChangedText; return }
            guard let change = RecordPlan.change(schedule, before: before, after: after) else { return }
            if await model.changeSchedule(schedule, change) { close() } else { error = model.actionError ?? "The recording could not be changed." }
            return
        }
        if let rule = RecordPlan.rule(what, request: request, before: before, after: after) {
            if await model.addRule(rule) { close() } else { error = model.actionError ?? "The rule could not be added." }
            return
        }
        if let listing = request.listing {
            // #345 (#234): the game's `game` rule, added or removed; the cards say so at once.
            switch listing.offer {
            case .record:
                guard let rule = await model.addGameRule(listing.game, before: before, after: after) else {
                    error = model.actionError ?? PageWords.recordWhenListedFailed
                    return
                }
                listing.answered(rule)
            case .cancel(let id):
                guard await model.deleteRule(id: id) else { error = model.actionError ?? "It couldn't be changed. Try again."; return }
                listing.answered(nil)
            }
            close()
            return
        }
        guard let airing else { return }
        // Codex review of #347: the same current per-airing check as the page's Cancelling…, at the press.
        if model.cancellingEarlier(request, airing: airing) { error = PageWords.cancellingEarlierText; return }
        if await model.schedule(channel: airing.channel, programme: airing.programme, guideEnd: airing.guideEnd,
                                before: before, after: after,
                                gameId: request.gameId, context: (request, airing)) {
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

    /// The selection (D-44 brand): a 14 % pink fill alone (no line), never a tick.
    private struct Selected: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content
                .background(on ? Color.pigSelection : .clear,
                            in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
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
