import SwiftUI

// D-44 batch 5 (Apple 114), remade to Mark's final design (#358, 20 Nov 2026; the web's Record window, server 0882): the
// one record page, opened from the long-press menu's More options… (the TV Guide and Sport alike) and from every Record
// button. A centred sheet on Apple TV and iPad, a half-height sheet on iPhone. Its main page: the header (the date and
// time once), What (this one, or a rule: every new episode / every episode; every <team> game / every <league> game) as a
// switch, then two rows: Channel (a page of the channels that carry it) and Extra time (a page of two steppers, Start
// early and Finish late), then Record and Cancel. A programme already scheduled opens as "Set to record": its padding can
// change (C-M since 0444, `PUT recordings/scheduled/:id`; Finish late only once it records) with Done, and Cancel
// recording acts at once with the 10 s Undo. The choices are pure (`RecordPlan`, tested in RecordPageTests and
// RecordSheetTests).

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

    /// A What choice's words on the switch (#358: the date and time are the header's alone). `short`: the iPhone's
    /// narrow switch ("All Bulls", "All NBA", Mark's iPhone design).
    static func title(_ what: What, request: RecordRequest, leagueLabel: String? = nil, short: Bool = false) -> String {
        switch what {
        case .this:
            return request.isGame || request.league != nil ? "This game" : "This programme"
        case .everyNewEpisode:
            return "Every new episode"
        case .everyEpisode:
            return "Every episode"
        case .everyTeam(let team):
            return short ? "All \(team)" : "Every \(team) game"
        case .everyLeague(let league):
            let name = leagueLabel ?? league
            if short { return "All \(name)" }
            return request.teams.count == 2 ? "Every \(name) game" : "Everything in \(name)"
        }
    }

    /// The header's one date line (#358: shown once, never under the rows): the chosen airing's day and times, or a game
    /// the guide does not list yet's day and start.
    static func when(_ request: RecordRequest, airing: RecordRequest.Airing?, now: Date) -> String? {
        if let airing {
            return "\(DetailText.day(airing.programme.start, now: now)) · \(airing.programme.timeRange)"
        }
        guard let listing = request.listing else { return nil }
        let start = SportFrontText.date(listing.game.start)
        return "\(DetailText.day(start, now: now)) · \(start.formatted(date: .omitted, time: .shortened))"
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

    // MARK: Extra time (#358)

    /// The server's ranges (C-M since 0444: whole minutes, 0-60 and 0-180, as a rule's).
    static let maxStartEarly = 60
    static let maxFinishLate = 180

    /// The usual Start early and Finish late: what the server applies when the page sends none; nil while not known.
    struct Usual: Equatable, Sendable {
        var before: Int?
        var after: Int?
    }

    /// Settings' padding as the server has it (`GET /api/settings`, C-M #358: `defaultPreBufferMin`, `defaultPostBufferMin`;
    /// any signed-in user or paired device may read it). Codex review of 366 (high): the steppers started from the
    /// server's shipped 1 and 5, so with Settings' Finish late 30 one + sent 6 and shortened the recording.
    struct PadDefaults: Equatable, Sendable {
        let before: Int
        let after: Int

        /// The two fields from the settings answer: whole minutes within the server's ranges, else nil (not known).
        static func decode(_ data: Data) -> PadDefaults? {
            struct Body: Decodable {
                let defaultPreBufferMin: Lenient<Double>?
                let defaultPostBufferMin: Lenient<Double>?
            }
            guard let body = try? JSONDecoder().decode(Body.self, from: data),
                  let pre = body.defaultPreBufferMin?.value, let post = body.defaultPostBufferMin?.value,
                  pre.isFinite, post.isFinite, pre == pre.rounded(), post == post.rounded(),
                  (0...Double(maxStartEarly)).contains(pre), (0...Double(maxFinishLate)).contains(post) else { return nil }
            return PadDefaults(before: Int(pre), after: Int(post))
        }
    }

    /// #358 (C-M "a game's usual Finish late is 0"): what the server stops at ESPN's end, with no Finish late, when the
    /// page sends none: a Sport card's game recorded on its own (its id is sent; a game the guide does not list yet is its
    /// `game` rule), a `team` rule's games, and a schedule made for a game. A keyword `sport` rule (a league, a team whose
    /// sport is not known) and a guide programme keep Settings' Finish late.
    static func followsGame(_ what: What, request: RecordRequest) -> Bool {
        if let schedule = request.schedule { return schedule.game != nil }
        switch what {
        case .this: return request.gameId != nil
        case .everyTeam: return rule(what, request: request, before: nil, after: nil)?.kind == "team"
        case .everyNewEpisode, .everyEpisode, .everyLeague: return false
        }
    }

    /// The usual padding for this choice: Settings' Start early, and Finish late 0 for a game ESPN follows, else Settings';
    /// nil where it depends on Settings and they are not known (the stepper waits).
    static func usual(_ what: What, request: RecordRequest, settings: PadDefaults?) -> Usual {
        Usual(before: settings?.before, after: followsGame(what, request: request) ? 0 : settings?.after)
    }

    /// The Extra time row's value: "Usual" while both are the usual, else "2 min early, 8 min late" (the web's words).
    /// `before`/`after`: the values shown (the edit, the schedule's, or the usual), nil while not known; a side not
    /// known is left out.
    static func extraWords(before: Int?, after: Int?, usual: Usual) -> String {
        let early = before ?? usual.before, late = after ?? usual.after
        if early == usual.before && late == usual.after { return "Usual" }
        return [early.map { "\($0) min early" }, late.map { "\($0) min late" }].compactMap { $0 }.joined(separator: ", ")
    }

    /// A stepper's value in words ("8 min").
    static func minutes(_ value: Int) -> String { "\(value) min" }

    /// One press of − or + (`delta` ±1): the new value, within 0 and `limit`. A new recording's value that comes back to
    /// the usual is nil again, so nothing is sent and a later switch to a rule with another usual follows that rule
    /// (Codex on the web window, #358); Change recording keeps the number (it is compared with the schedule's).
    /// `shown`: the value the stepper shows (nil while none is known: nothing changes).
    static func stepped(_ shown: Int?, by delta: Int, usual: Int?, limit: Int, keepsValue: Bool) -> Int? {
        guard let shown else { return nil }
        let next = min(limit, max(0, shown + delta))
        return !keepsValue && next == usual ? nil : next
    }

    /// Whether − (`delta` < 0) or + can still move the value shown (never while it is not known).
    static func canStep(_ shown: Int?, by delta: Int, limit: Int) -> Bool {
        guard let shown else { return false }
        return delta < 0 ? shown > 0 : shown < limit
    }

    /// The Extra time draft: what the person changed, per field (nil: untouched). Codex review of 366 (high): Set to
    /// record's draft was seeded from the schedule as the page opened, so once the list refreshed (another device changed
    /// Finish late) every difference counted as an edit and Done sent the old value back. Now nothing is seeded: an
    /// untouched field shows the schedule as the list has it now and is never sent.
    struct PadDraft: Equatable, Sendable {
        var before: Int? = nil
        var after: Int? = nil

        /// The draft a page opens with, a new recording and Set to record alike: nothing changed.
        static func opening(_ request: RecordRequest) -> PadDraft { PadDraft() }

        /// A stepper's value: the person's edit, else the schedule's as the list has it now (Set to record), else the
        /// usual; nil while none is known.
        static func shown(_ edit: Int?, schedule: Int?, usual: Int?) -> Int? { edit ?? schedule ?? usual }

        /// What Done sends: only the fields the person changed, and of those only what differs from the schedule now.
        func change(_ live: ScheduledRecording) -> ScheduleChangeBody? { RecordPlan.change(live, before: before, after: after) }
    }

    /// Start early can change only before it records.
    static func canChangeStartEarly(_ schedule: ScheduledRecording) -> Bool { schedule.status != "recording" }

    /// What Done sends: only what changed (Start early not once it records); nil when nothing has.
    static func change(_ schedule: ScheduledRecording, before: Int?, after: Int?) -> ScheduleChangeBody? {
        var body = ScheduleChangeBody()
        if canChangeStartEarly(schedule), let before, before != schedule.startEarly { body.preBufferMin = before }
        if let after, after != schedule.finishLate { body.postBufferMin = after }
        return body == ScheduleChangeBody() ? nil : body
    }

    /// The line where What is when it is already set to record (the web's words).
    static func stateWords(_ schedule: ScheduledRecording?, gone: Bool) -> String {
        if gone { return "Ended" }
        switch schedule?.status {
        case "recording": return "Recording now"
        case "waiting": return "Waiting to record"
        default: return "Set to record"
        }
    }

    // MARK: Channel (#358)

    /// Whether the Channel row opens the Channel page: when there is more than one airing to choose. Set to record, it
    /// records where it was set; a sport request's airings stay choosable while one of them is set to record (Codex review
    /// of #347: another day of a Test stays recordable), as before.
    static func channelChoosable(_ opened: RecordRequest, changing: Bool) -> Bool {
        opened.airings.count > 1 && (!changing || opened.airingSchedules != nil)
    }

    /// Whether the airings differ in time (a Test's two days, a later showing): only then does the Channel page show each
    /// row's day and times.
    static func channelsTimed(_ request: RecordRequest) -> Bool {
        guard let first = request.airings.first else { return false }
        return request.airings.contains {
            $0.programme.startTime != first.programme.startTime || $0.programme.endTime != first.programme.endTime
        }
    }

    /// A Channel page row's second line: its day and times when the airings differ in time, else nothing.
    static func channelDetail(_ airing: RecordRequest.Airing, timed: Bool, now: Date) -> String? {
        timed ? "\(DetailText.day(airing.programme.start, now: now)) \(airing.programme.timeRange)" : nil
    }

    /// The copy a Channel page row shows and selects: the chosen one when it is in the row, else the row's best. Codex
    /// review of 366 (medium): the row showed the chosen copy (a later HD airing, the bound schedule) but selected the
    /// row's best (an earlier UHD airing), so pressing the ticked row switched airing and turned Set to record into Record.
    static func rowCopy(_ group: ChannelNameGroup<Int>, chosen: Int) -> Int {
        group.indices.contains(chosen) ? chosen : group.best.copy
    }

    /// D-65 (#266): the Channel page's rows: one per channel name, its copies' qualities as chips (best first; copies with
    /// the same name and quality fold into one chip). Each copy is its index in `request.airings`; a chip selects its first.
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

    // MARK: Binding the page to its schedule

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

    /// #345: the note under a game the guide does not list yet (the words of #234's question).
    /// #341: only the offer to record says anything; a game already set to record has no note.
    static func listingNote(_ listing: RecordRequest.Listing) -> String? {
        listing.offer == .record
            ? "It isn't in the TV guide yet. PigTV records it on its best channel as soon as it's listed."
            : nil
    }

    /// The primary button.
    static func primaryTitle(_ what: What, request: RecordRequest) -> String {
        if request.schedule != nil { return "Done" }
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

    /// #358: the main page, or one of the two pages its rows open (inside the same sheet, with Back).
    enum Screen: Hashable { case main, channel, extra }

    @State private var screen: Screen = .main
    @State private var what: RecordPlan.What = .this
    /// What the person changed in Extra time, per field (nil: untouched, never sent).
    @State private var draft: RecordPlan.PadDraft
    /// Settings' padding as this opening read it (`BrowseModel.loadRecordDefaults`); nil until then: the steppers that
    /// depend on it wait (never a copy from an earlier page).
    @State private var defaults: RecordPlan.PadDefaults?
    @State private var airingIndex = 0
    @State private var error: String?
    @State private var busy = false
    private enum Focus: Hashable { case primary, cancel, channelRow, extraRow, channel(Int), before, after }
    @FocusState private var focus: Focus?

    init(model: BrowseModel, presenter: AppPresenter, request: RecordRequest, close: @escaping () -> Void) {
        self.model = model
        _actions = ObservedObject(wrappedValue: model.actions)
        _store = ObservedObject(wrappedValue: model.recordingStore)
        self.presenter = presenter
        self.opened = request
        self.close = close
        _draft = State(initialValue: .opening(request))
        _error = State(initialValue: request.error)
        _airingIndex = State(initialValue: RecordPlan.openingAiring(request))
        #if DEBUG
        // T3 screenshots: PIGTV_UI_TEST_RECORD_PAGE=channel | extra opens the page on the Channel or Extra time page.
        switch ProcessInfo.processInfo.environment["PIGTV_UI_TEST_RECORD_PAGE"] {
        case "channel": _screen = State(initialValue: .channel)
        case "extra": _screen = State(initialValue: .extra)
        default: break
        }
        #endif
    }

    private var airing: RecordRequest.Airing? {
        request.airings.indices.contains(airingIndex) ? request.airings[airingIndex] : request.airings.first
    }
    private var changing: Bool { request.schedule != nil }
    /// Change recording's schedule as it is now (nil: gone, or not Change recording).
    private var live: ScheduledRecording? { request.schedule.flatMap { RecordPlan.live($0, in: model.schedules) } }
    private var gone: Bool { changing && live == nil }
    private var primaryOff: Bool { busy }
    private var leagueLabel: String? { request.league.flatMap { model.sportFront.labels[$0] } }
    /// #345: "Don't record it" (a game set to record once listed): nothing to pad.
    private var stopsWaiting: Bool { what == .this && request.listing?.offer != nil && request.listing?.offer != .record }
    private var usual: RecordPlan.Usual { RecordPlan.usual(what, request: request, settings: defaults) }
    /// The schedule as the list has it now (Set to record), else as it opened.
    private var scheduleNow: ScheduledRecording? { live ?? request.schedule }
    private var shownBefore: Int? { RecordPlan.PadDraft.shown(draft.before, schedule: scheduleNow?.startEarly, usual: usual.before) }
    private var shownAfter: Int? { RecordPlan.PadDraft.shown(draft.after, schedule: scheduleNow?.finishLate, usual: usual.after) }
    /// Start early cannot change once it records, nor anything once the schedule has gone.
    private var startLocked: Bool { changing && (live.map { !RecordPlan.canChangeStartEarly($0) } ?? true) }
    private var started: Bool { changing && live?.status == "recording" }
    /// The iPhone's layout (Mark's iPhone design). By the device, not the size class: inside the iPad's form sheet the
    /// width is compact too, and the iPad keeps its own design (full words, the kicker, the actions side by side).
    private var compact: Bool {
        #if os(tvOS)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    var body: some View {
        let now = Date()
        ZStack {
            PigPageBackground().ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack {
                        card(now: now)
                            .frame(maxWidth: Metrics.cardWidth)
                            .padding(Metrics.outer)
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.centred ? geometry.size.height : nil,
                           alignment: Metrics.centred ? .center : .top)
                }
                .scrollClipDisabled()
            }
        }
        #if os(tvOS)
        .buttonStyle(PigSecondaryButtonStyle())
        // Back (Menu) on the Channel or Extra time page returns to the main page; on the main page it closes the sheet.
        .onExitCommand(perform: screen == .main ? nil : { show(.main) })
        #endif
        .presentationBackground { PigPageBackground() }
        .modifier(SheetSize(screen: screen, compact: compact))
        .interactiveDismissDisabled(busy)
        .defaultFocus($focus, .primary)
        .accessibilityIdentifier("record.page")
        // Codex 5a round 1: once it records, Start early shows (and keeps) the schedule's own value, never an edit that
        // the server would refuse; the list is refreshed while Change recording is open.
        // Codex sign-off of #347: a card listing cancellations waits for a newer scheduled-list read; while open, every
        // accepted read is published to it, even one with the same rows.
        .onAppear { if opened.serverCancelling != nil { store.readWaiters += 1 } }
        .onDisappear { if opened.serverCancelling != nil { store.readWaiters = max(0, store.readWaiters - 1) } }
        // Another airing chosen: nothing changed on it yet (its own schedule's padding, else the usual), and "This game".
        .onChange(of: airingIndex) {
            draft = .opening(request)
            what = .this
        }
        // Codex review of 366 and sign-off of 368 (high): Settings' padding, read each time the page opens; the steppers
        // wait for it (a failed read leaves them off, and Record still works with the padding untouched, so the server
        // applies its own).
        .task { defaults = await model.loadRecordDefaults() }
        .task(id: changing) {
            guard changing, !model.isFixture else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await model.loadRecordingsIfStale(maxAge: 19, quietly: true) // #239: shared with any other page
            }
        }
    }

    /// Opens a page of the sheet and puts focus where it belongs: on a page, its chosen row; back on the main page, the
    /// row that opened it (the web's window does the same).
    private func show(_ next: Screen) {
        let from = screen
        screen = next
        let target: Focus?
        switch next {
        case .main: target = from == .channel ? .channelRow : from == .extra ? .extraRow : .primary
        case .channel: target = .channel(airingIndex)
        case .extra: target = startLocked ? .after : .before
        }
        Task { @MainActor in focus = target }
    }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            switch screen {
            case .main: mainPage(now: now)
            case .channel: channelPage(now: now)
            case .extra: extraPage
            }
        }
        .padding(Metrics.padding)
        // #340: flat, as the rest of the app: no drop shadow. On iPhone and iPad the sheet itself is the surface (Mark's
        // designs); the television's cover draws the card.
        .background(Metrics.cardFill, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(changing ? "Change recording of \(request.title)" : "Record \(request.title)")
    }

    // MARK: Main page

    @ViewBuilder
    private func mainPage(now: Date) -> some View {
        header(now: now)
        if changing {
            stateLine
        } else {
            let whats = RecordPlan.whats(request)
            if whats.count > 1 { whatSwitch(whats) }
        }
        rows
        if let note = cardNote(now: now) {
            Text(note).font(Metrics.note).foregroundStyle(Color.pigSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        errorText
        buttons
    }

    /// The one note under the rows, if any (#341).
    private func cardNote(now: Date) -> String? {
        if changing { return gone ? RecordPlan.goneText : nil }
        if let listing = request.listing { return RecordPlan.listingNote(listing) }
        return RecordPlan.streamNote(airing, now: now)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error {
            Text(error).font(Metrics.note.weight(.semibold)).foregroundStyle(Color.pigWarning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("record.error")
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: Metrics.headerGap) {
            if request.teams.count == 2 {
                HStack(spacing: compact ? -PigSpacing.s : PigSpacing.s) {
                    ForEach(Array(request.teams.enumerated()), id: \.offset) { _, team in
                        SportBadge(name: team.name, logo: team.logo, league: request.league ?? "", client: model.client,
                                   size: Metrics.badge)
                    }
                }
                .accessibilityHidden(true)
            } else if let airing {
                ChannelLogoTile(logo: model.logo(for: airing.channel), client: model.client, name: airing.channel.name,
                                size: Metrics.logo)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                // Mark's iPhone design: no kicker line; the league leads the date line.
                if !compact {
                    Text(kicker).font(Metrics.kicker).tracking(2).foregroundStyle(Color.pigSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(request.title).font(Metrics.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let when = metaLine(now: now) {
                    Text(when).font(Metrics.meta).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(2)
                        .accessibilityIdentifier("record.when")
                }
            }
        }
    }

    private var kicker: String {
        ["RECORD", (leagueLabel ?? request.league)?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    private func metaLine(now: Date) -> String? {
        guard let when = RecordPlan.when(request, airing: airing, now: now) else { return nil }
        guard compact, let league = leagueLabel ?? request.league else { return when }
        return "\(league) · \(when)"
    }

    /// Set to record: its state where What is (Recording now, Waiting to record, Ended).
    private var stateLine: some View {
        HStack(spacing: PigSpacing.s) {
            Circle().fill(gone ? Color.pigSecondary : Color.pigAccent).frame(width: Metrics.dot, height: Metrics.dot)
                .accessibilityHidden(true)
            Text(RecordPlan.stateWords(live ?? request.schedule, gone: gone))
                .font(Metrics.state).foregroundStyle(gone ? Color.pigSecondary : Color.pigAccentText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.state")
    }

    // MARK: What

    /// What as a switch: one choice per segment (#358, Mark's design A).
    private func whatSwitch(_ whats: [RecordPlan.What]) -> some View {
        HStack(spacing: PigSpacing.xs) {
            ForEach(whats, id: \.self) { option in
                let words = RecordPlan.title(option, request: request, leagueLabel: leagueLabel, short: compact)
                let on = what == option
                Button { what = option } label: {
                    Text(words).font(on ? Metrics.segmentOn : Metrics.segment)
                        .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(on ? Metrics.segmentOnText : Color.pigText)
                        .padding(.horizontal, PigSpacing.xs).padding(.vertical, Metrics.segmentPad)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(on ? Metrics.segmentOnFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
                        .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: PigRadius.compact, lift: .control))
                #else
                .buttonStyle(PigPressStyle())
                #endif
                .accessibilityLabel(words)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("record.what.\(whatID(option))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(PigSpacing.xs)
        .background(Metrics.segmentTrack, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        #if os(tvOS)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What to record")
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

    // MARK: The two rows

    /// Channel (only for this one: a rule records each on its own channel; none for a game the guide does not list yet)
    /// and Extra time (not for "Don't record it").
    @ViewBuilder
    private var rows: some View {
        let showsChannel = what == .this && airing != nil
        if showsChannel || !stopsWaiting {
            VStack(spacing: 0) {
                if showsChannel, let shown = airing {
                    row("Channel", id: "channel", opens: RecordPlan.channelChoosable(opened, changing: changing), focus: .channelRow,
                        label: "Channel, \(shown.channel.name)\(shown.chip.map { ", \($0.spoken)" } ?? "")") {
                        Text(shown.channel.name).font(Metrics.rowValue).lineLimit(1)
                        if let chip = shown.chip { QualityBadge(chip: chip, font: Metrics.badgeFont) }
                    } action: { show(.channel) }
                }
                if showsChannel && !stopsWaiting { divider }
                if !stopsWaiting {
                    let words = RecordPlan.extraWords(before: shownBefore, after: shownAfter, usual: usual)
                    row("Extra time", id: "extra", opens: !gone, focus: .extraRow, label: "Extra time, \(words)") {
                        Text(words).font(Metrics.rowValue).lineLimit(1).pigFigures()
                    } action: { show(.extra) }
                }
            }
            .background(Metrics.groupFill, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .overlay {
                if Metrics.groupBorder {
                    RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigBorder, lineWidth: 1)
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.pigBorder).frame(height: 1).padding(.leading, Metrics.rowInsets.leading)
            .accessibilityHidden(true)
    }

    /// A row of the main page: its name, its value, and › when it opens a page; otherwise plain words.
    @ViewBuilder
    private func row<Value: View>(_ name: String, id: String, opens: Bool, focus target: Focus, label: String,
                                  @ViewBuilder value: () -> Value, action: @escaping () -> Void) -> some View {
        let content = HStack(spacing: Metrics.rowGap) {
            Text(name).font(Metrics.rowName).foregroundStyle(Color.pigSecondary)
                .frame(width: Metrics.rowNameWidth, alignment: .leading)
            HStack(spacing: PigSpacing.s) { value() }
            Spacer(minLength: 0)
            if opens {
                Image(systemName: "chevron.right").font(Metrics.chevron).foregroundStyle(Color.pigSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(Metrics.rowInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        if opens {
            Button(action: action) { content.contentShape(Rectangle()) }
                #if os(tvOS)
                .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: PigRadius.card, lift: .row))
                #else
                .buttonStyle(PigPressStyle())
                .pigTouchTarget()
                #endif
                .focused($focus, equals: target)
                .accessibilityLabel(label)
                .accessibilityIdentifier("record.row.\(id)")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier("record.row.\(id)")
        }
    }

    // MARK: Channel page

    private func subHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            #if os(tvOS)
            // Menu is Back on the television; the line says where it goes.
            Label(request.title, systemImage: "chevron.left").font(Metrics.back).foregroundStyle(Color.pigSecondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            #else
            Button { show(.main) } label: {
                Label("Back", systemImage: "chevron.left").font(Metrics.back).foregroundStyle(Color.pigAccentText)
            }
            .buttonStyle(PigPressStyle())
            .pigTouchTarget(alignment: .leading)
            .accessibilityIdentifier("record.back")
            #endif
            Text(title).font(Metrics.pageTitle).accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func channelPage(now: Date) -> some View {
        subHeader("Channel")
        let groups = RecordPlan.channelGroups(request)
        let timed = RecordPlan.channelsTimed(request)
        VStack(alignment: .leading, spacing: Metrics.channelGap) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                channelRow(group, index: index, last: index == groups.count - 1, timed: timed, now: now)
            }
        }
        .background(Metrics.listFill, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay {
            if Metrics.groupBorder {
                RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigBorder, lineWidth: 1)
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    /// One channel name: a tick on the chosen one, BEST on the first, its quality (D-65: a name carried in several
    /// qualities has a chip per quality to choose from); its day and times only when the airings differ in time.
    /// Choosing returns to the main page.
    @ViewBuilder
    private func channelRow(_ group: ChannelNameGroup<Int>, index: Int, last: Bool, timed: Bool, now: Date) -> some View {
        let on = group.indices.contains(airingIndex)
        // The row's words and its action follow the copy chosen in it, else its best; other airings stay their chips.
        let copy = RecordPlan.rowCopy(group, chosen: airingIndex)
        let option = request.airings[copy]
        let detail = RecordPlan.channelDetail(option, timed: timed, now: now)
        let name = group.choosesQuality ? group.name : option.channel.name
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            Button { choose(copy) } label: {
                HStack(spacing: Metrics.rowGap) {
                    Image(systemName: "checkmark").font(Metrics.tick).foregroundStyle(Color.pigAccentText)
                        .opacity(on ? 1 : 0)
                        .frame(width: Metrics.tickWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                        Text(name).font(Metrics.channelName).lineLimit(1)
                        if let detail {
                            Text(detail).font(Metrics.note).foregroundStyle(Color.pigSecondary).pigFigures().lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if index == 0 {
                        Text("BEST").font(Metrics.best).tracking(1).foregroundStyle(Color.pigSecondary)
                    }
                    if !group.choosesQuality, let chip = option.chip { QualityBadge(chip: chip, font: Metrics.badgeFont) }
                }
                .padding(Metrics.rowInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            #if os(tvOS)
            .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card, lift: .row,
                                               restingFill: on ? Color.pigSelection : Color.pigRaised))
            #else
            .buttonStyle(PigPressStyle())
            .pigTouchTarget()
            #endif
            .focused($focus, equals: .channel(copy))
            .accessibilityLabel([name, detail, index == 0 ? "best" : nil, group.choosesQuality ? nil : option.chip?.spoken]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("record.on.\(index)")
            if group.choosesQuality { qualityChips(group, index: index, name: name) }
        }
        if !last && Metrics.listDividers { divider }
    }

    /// D-65 (#266): a channel name carried in several qualities: a chip per quality (best first) that chooses that copy.
    private func qualityChips(_ group: ChannelNameGroup<Int>, index: Int, name: String) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: PigSpacing.s) {
                ForEach(Array(group.choices.enumerated()), id: \.element.id) { chipIndex, choice in
                    let picked = choice.indices.contains(airingIndex)
                    let starts = group.startsDifferently(choice)
                        ? request.airings[choice.copy].programme.start.formatted(date: .omitted, time: .shortened) : nil
                    Button { choose(choice.copy) } label: {
                        HStack(spacing: PigSpacing.xs) {
                            if let chip = choice.chip {
                                QualityBadge(chip: chip, font: Metrics.badgeFont)
                            } else {
                                Text("Other").font(Metrics.badgeFont).foregroundStyle(Color.pigSecondary)
                            }
                            // A copy airing at another time than the row's shows its start.
                            if let starts {
                                Text(starts).font(Metrics.note).foregroundStyle(Color.pigSecondary).pigFigures()
                            }
                        }
                        .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                        .background(picked ? Color.pigSelection : .clear,
                                    in: RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.compact, lift: .control))
                    .accessibilityLabel("\(name), \(choice.chip?.spoken ?? "other quality")" + (starts.map { ", starts \($0)" } ?? ""))
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    .accessibilityIdentifier("record.on.\(index).\(chipIndex)")
                }
            }
            .padding(.leading, Metrics.rowInsets.leading + Metrics.tickWidth + Metrics.rowGap)
            .padding(.vertical, PigSpacing.xxs)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func choose(_ copy: Int) {
        airingIndex = copy
        error = nil
        show(.main)
    }

    // MARK: Extra time page

    @ViewBuilder
    private var extraPage: some View {
        subHeader("Extra time")
        VStack(spacing: Metrics.stepperGap) {
            stepper("Start early", id: "before", value: $draft.before, base: shownBefore, usual: usual.before,
                    limit: RecordPlan.maxStartEarly, locked: startLocked, lockedWords: started ? "Started" : nil, target: .before)
            stepper("Finish late", id: "after", value: $draft.after, base: shownAfter, usual: usual.after,
                    limit: RecordPlan.maxFinishLate, locked: gone, lockedWords: nil, target: .after)
        }
        errorText
    }

    /// Start early or Finish late: − value +, one minute per press (held: repeats), within the server's range, no words
    /// besides (Mark's design). On the television the row is one focusable item: left and right change it, select
    /// does nothing. Locked (Start early once it records, both once it has gone): the value alone ("Started"), dimmed.
    @ViewBuilder
    /// `value`: the person's edit (nil: untouched); `base`: the value shown (the edit, the schedule's now, or the usual);
    /// `usual`: what a new recording's edit clears back to.
    private func stepper(_ name: String, id: String, value: Binding<Int?>, base: Int?, usual: Int?, limit: Int, locked: Bool,
                         lockedWords: String?, target: Focus) -> some View {
        let words = lockedWords ?? base.map(RecordPlan.minutes) ?? "—"
        let less = !locked && RecordPlan.canStep(base, by: -1, limit: limit)
        let more = !locked && RecordPlan.canStep(base, by: 1, limit: limit)
        let step = { (delta: Int) in
            guard !locked, RecordPlan.canStep(base, by: delta, limit: limit) else { return }
            value.wrappedValue = RecordPlan.stepped(base, by: delta, usual: usual, limit: limit, keepsValue: changing)
        }
        let valueText = Text(words).font(Metrics.stepperValue).pigFigures().lineLimit(1)
            .frame(minWidth: Metrics.stepperValueWidth)
            .accessibilityIdentifier("record.\(id).value")
        #if os(tvOS)
        let content = HStack(spacing: Metrics.rowGap) {
            Text(name).font(Metrics.channelName)
            Spacer(minLength: 0)
            if !locked { sign("minus", on: less) }
            valueText
            if !locked { sign("plus", on: more) }
        }
        .padding(Metrics.rowInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        if locked {
            content
                .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
                .opacity(0.45)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(words)")
                .accessibilityIdentifier("record.\(id)")
        } else {
            Button {} label: { content }
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: PigRadius.card, lift: .row, restingFill: Color.pigRaised))
                .focused($focus, equals: target)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: step(-1)
                    case .right: step(1)
                    default: break
                    }
                }
                .accessibilityLabel("\(name), \(words)")
                .accessibilityIdentifier("record.\(id)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
        }
        #else
        HStack(spacing: PigSpacing.m) {
            Text(name).font(Metrics.channelName)
            Spacer(minLength: 0)
            if !locked {
                stepButton("minus", on: less, label: "\(name): one minute less", id: "record.\(id).less") { step(-1) }
            }
            valueText
            if !locked {
                stepButton("plus", on: more, label: "\(name): one minute more", id: "record.\(id).more") { step(1) }
            }
        }
        .padding(Metrics.rowInsets)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous).strokeBorder(Color.pigBorder, lineWidth: 1) }
        .opacity(locked ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record.\(id)")
        #endif
    }

    #if os(tvOS)
    /// − or + drawn in its disc on the television's stepper row (the row takes the presses).
    private func sign(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(Metrics.sign).foregroundStyle(Color.pigAccentText)
            .frame(width: Metrics.signDisc, height: Metrics.signDisc)
            .background(Color.pigCanvas, in: Circle())
            .opacity(on ? 1 : 0.35)
            .accessibilityHidden(true)
    }
    #else
    private func stepButton(_ symbol: String, on: Bool, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Metrics.sign).foregroundStyle(Color.pigAccentText)
                .frame(width: Metrics.signDisc, height: Metrics.signDisc)
                .background(Color.pigRaised, in: Circle())
        }
        .buttonStyle(PigPressStyle())
        .buttonRepeatBehavior(.enabled)
        .pigTouchTarget()
        .disabled(!on)
        .opacity(on ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
    #endif

    // MARK: Buttons

    /// Record and Cancel (Set to record: Done and Cancel recording). Television: centred, Record first; iPad: side by side,
    /// Cancel first; iPhone: stacked full width, the second a plain line under it (Mark's designs).
    @ViewBuilder
    private var buttons: some View {
        #if os(tvOS)
        HStack(spacing: PigSpacing.l) {
            primaryButton(stretched: false)
            secondaryButton(stretched: false)
            if busy { ProgressView() }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
        #else
        if compact {
            VStack(spacing: PigSpacing.s) {
                primaryButton(stretched: true)
                secondaryButton(stretched: true)
                if busy { ProgressView() }
            }
        } else {
            HStack(spacing: PigSpacing.m) {
                secondaryButton(stretched: true)
                primaryButton(stretched: true)
            }
            .overlay { if busy { ProgressView() } }
        }
        #endif
    }

    /// Mark, 19 Nov 2026: an earlier recording of this (the game, or this channel's overlapping airing) is being
    /// cancelled: Record waits until its outcome is known.
    /// The chosen airing waits (C-R #353: other airings, another day of a Test, stay recordable).
    private var cancelling: Bool { airing.map { model.cancellingEarlier(request, airing: $0) } ?? false }

    @ViewBuilder
    private func primaryButton(stretched: Bool) -> some View {
        if cancelling {
            Button {} label: {
                Label(PageWords.cancelling, systemImage: "hourglass").lineLimit(1).frame(maxWidth: stretched ? .infinity : nil)
            }
            .pigSecondaryButton()
            .disabled(true)
            #if os(tvOS)
            .opacity(0.45)
            #endif
            .accessibilityLabel(PageWords.cancellingLabel)
            .accessibilityIdentifier("record.cancelling")
        } else {
            Button { Task { await primary() } } label: {
                Label(RecordPlan.primaryTitle(what, request: request), systemImage: changing ? "checkmark.circle" : "record.circle")
                    .lineLimit(1)
                    .frame(maxWidth: stretched ? .infinity : nil)
            }
            .pigPrimaryButton()
            .disabled(primaryOff)
            #if os(tvOS)
            // The tvOS primary style draws no disabled look of its own; the iOS glass button dims itself.
            .opacity(primaryOff ? 0.45 : 1)
            #endif
            .focused($focus, equals: .primary)
            .accessibilityIdentifier("record.schedule")
        }
    }

    @ViewBuilder
    private func secondaryButton(stretched: Bool) -> some View {
        if changing {
            let button = Button {
                guard let live else { return }
                if model.stillBinds(live, request) { cancel(live) } else { error = PageWords.bindingChangedText }
            } label: {
                Text(live?.status == "recording" ? "Stop recording" : "Cancel recording")
                    .lineLimit(1)
                    .frame(maxWidth: stretched ? .infinity : nil)
            }
            .foregroundStyle(Color.pigDanger)
            .disabled(busy || gone)
            .opacity(gone ? 0.45 : 1)
            .focused($focus, equals: .cancel)
            .accessibilityIdentifier("record.cancelRecording")
            if compact { button.buttonStyle(PigPressStyle()).pigTouchTarget() } else { button }
        } else {
            let button = Button { close() } label: {
                Text("Cancel").lineLimit(1).frame(maxWidth: stretched ? .infinity : nil)
            }
            .disabled(busy)
            .focused($focus, equals: .cancel)
            .accessibilityIdentifier("record.close")
            if compact { button.buttonStyle(PigPressStyle()).foregroundStyle(Color.pigAccentText).pigTouchTarget() } else { button }
        }
    }

    private func primary() async {
        busy = true
        error = nil
        defer { busy = false }
        if changing {
            // Done: the change, when there is one; else (or once the schedule has gone) it only closes.
            guard let schedule = live, let change = draft.change(schedule) else {
                close()
                return
            }
            guard model.stillBinds(schedule, request) else { error = PageWords.bindingChangedText; return }
            if await model.changeSchedule(schedule, change) { close() } else { error = model.actionError ?? "The recording could not be changed." }
            return
        }
        if let rule = RecordPlan.rule(what, request: request, before: draft.before, after: draft.after) {
            if await model.addRule(rule) { close() } else { error = model.actionError ?? "The rule could not be added." }
            return
        }
        if let listing = request.listing {
            // #345 (#234): the game's `game` rule, added or removed; the cards say so at once.
            switch listing.offer {
            case .record:
                guard let rule = await model.addGameRule(listing.game, before: draft.before, after: draft.after) else {
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
        // Codex review and sign-off of #347: the scheduled list read fresh, the page's per-airing check, then the write.
        if await model.record(request, airing: airing, before: draft.before, after: draft.after) {
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

    /// iPhone (#358, Mark's iPhone design): a half-height sheet for the main and Extra time pages, the full height for the
    /// Channel page; iPad: the centred form sheet. The television's cover is the whole screen.
    private struct SheetSize: ViewModifier {
        let screen: Screen
        let compact: Bool
        func body(content: Content) -> some View {
            #if os(tvOS)
            content
            #else
            if compact {
                content
                    .presentationDetents(Set<PresentationDetent>([screen == .channel ? .large : .medium]))
                    .presentationDragIndicator(.visible)
            } else if #available(iOS 18.0, *) {
                content.presentationSizing(.form)
            } else {
                content
            }
            #endif
        }
    }

    private enum Metrics {
        #if os(tvOS)
        static let centred = true
        static let cardFill = Color.pigSurface
        static let cardWidth: CGFloat = 1120
        static let outer: CGFloat = 36
        static let padding = EdgeInsets(top: 56, leading: 72, bottom: 52, trailing: 72)
        static let gap: CGFloat = 32
        static let headerGap: CGFloat = 30
        static let badge: CGFloat = 96
        static let logo = DetailMetrics.smallLogo
        static let kicker: Font = .system(size: PigType.kicker, weight: .bold)
        static let title: Font = .system(size: PigType.pageTitle, weight: .heavy)
        static let meta: Font = .system(size: PigType.cardTitle)
        static let state: Font = .system(size: PigType.sectionTitle, weight: .bold)
        static let dot: CGFloat = 24
        static let segment: Font = .system(size: PigType.cardTitle, weight: .semibold)
        static let segmentOn: Font = .system(size: PigType.cardTitle, weight: .bold)
        static let segmentPad: CGFloat = 18
        static let segmentTrack = Color.pigCanvas
        static let segmentOnFill = Color.pigText
        static let segmentOnText = Color.pigCanvas
        static let groupFill = Color.pigRaised
        static let groupBorder = false
        static let listFill = Color.clear
        static let listDividers = false
        static let rowInsets = EdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32)
        static let rowGap: CGFloat = 24
        static let rowName: Font = .system(size: PigType.cardTitle)
        static let rowNameWidth: CGFloat = 200
        static let rowValue: Font = .system(size: PigType.cardTitle, weight: .semibold)
        static let chevron: Font = .system(size: PigType.cardTitle, weight: .semibold)
        static let back: Font = .system(size: PigType.secondary, weight: .semibold)
        static let pageTitle: Font = .system(size: PigType.pageTitle, weight: .heavy)
        static let channelGap: CGFloat = 12
        static let channelName: Font = .system(size: PigType.sectionTitle, weight: .semibold)
        static let tick: Font = .system(size: PigType.cardTitle, weight: .bold)
        static let tickWidth: CGFloat = 32
        static let best: Font = .system(size: PigType.caption, weight: .bold)
        static let stepperGap: CGFloat = 18
        static let stepperValue: Font = .system(size: PigType.display, weight: .heavy)
        static let stepperValueWidth: CGFloat = 150
        static let sign: Font = .system(size: PigType.cardTitle, weight: .bold)
        static let signDisc: CGFloat = 64
        static let note: Font = .system(size: PigType.caption)
        static let badgeFont: Font = .system(size: PigType.caption, weight: .heavy)
        #else
        static let centred = false
        static let cardFill = Color.clear
        static let cardWidth: CGFloat = 600
        static let outer: CGFloat = 16
        static let padding = EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        static let gap: CGFloat = 16
        static let headerGap: CGFloat = 12
        static let badge: CGFloat = 44
        static let logo = DetailMetrics.smallLogo
        static let kicker: Font = .caption.weight(.bold)
        static let title: Font = .title3.weight(.heavy)
        static let meta: Font = .subheadline
        static let state: Font = .headline
        static let dot: CGFloat = 12
        static let segment: Font = .subheadline.weight(.medium)
        static let segmentOn: Font = .subheadline.weight(.bold)
        static let segmentPad: CGFloat = 9
        static let segmentTrack = Color.pigRaised
        static let segmentOnFill = Color.pigSurface
        static let segmentOnText = Color.pigText
        static let groupFill = Color.pigSurface
        static let groupBorder = true
        static let listFill = Color.pigSurface
        static let listDividers = true
        static let rowInsets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        static let rowGap: CGFloat = 12
        static let rowName: Font = .body
        static let rowNameWidth: CGFloat = 92
        static let rowValue: Font = .body.weight(.semibold)
        static let chevron: Font = .footnote.weight(.semibold)
        static let back: Font = .body.weight(.semibold)
        static let pageTitle: Font = .title2.weight(.heavy)
        static let channelGap: CGFloat = 0
        static let channelName: Font = .body.weight(.semibold)
        static let tick: Font = .body.weight(.bold)
        static let tickWidth: CGFloat = 20
        static let best: Font = .caption2.weight(.bold)
        static let stepperGap: CGFloat = 12
        static let stepperValue: Font = .title3.weight(.heavy)
        static let stepperValueWidth: CGFloat = 80
        static let sign: Font = .body.weight(.bold)
        static let signDisc: CGFloat = 40
        static let note: Font = .footnote
        static let badgeFont: Font = .caption2.weight(.heavy)
        #endif
    }
}
