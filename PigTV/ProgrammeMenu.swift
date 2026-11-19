import SwiftUI

// D-44 (Apple 107): the one long-press menu (R5-Menu-TV, -iPad, -iPhone). A card beside the focused programme on the
// Apple TV and the iPad; the system context menu, with a preview, on the iPhone. RECORD first (this programme, every
// new episode or every game, More options…), then Watch from start, Programme details, Channel schedule and the
// channel's favourite. Its items are pure (`ProgrammeMenu.items`, tested in ProgrammeMenuTests); the screen that opens
// it (the Guide now, Sport cards next) supplies what each one does (`ProgrammeMenuActions`).

/// One menu item.
nonisolated enum ProgrammeMenuItem: Equatable, Identifiable, Sendable {
    /// `game`: a Sport card's ("Record this game").
    case recordThis(game: Bool = false)
    /// D-44 batch 5 (Apple 114): already scheduled or recording: the record page as "Change recording" (its times, and
    /// Cancel recording with Undo). Replaces batch 4's "Cancel this recording".
    case changeRecording(status: String)
    /// "Record every new episode" (a series rule) or, for sport, "Record every game".
    case recordEvery(title: String)
    case moreOptions
    /// #257 (Mark, 8 Nov): a live event carried by several channels: choose which to watch, before the player opens.
    case watchOn(channels: Int)
    case watchFromStart
    case details
    case schedule
    case favourite(channel: String, isFavourite: Bool)
    /// Mark, 19 Nov 2026: an earlier recording of this is being cancelled: the RECORD section is this, disabled.
    case cancelling

    var id: String {
        switch self {
        case .cancelling: "cancelling"
        case .recordThis: "recordThis"
        case .changeRecording: "changeRecording"
        case .recordEvery: "recordEvery"
        case .moreOptions: "moreOptions"
        case .watchOn: "watchOn"
        case .watchFromStart: "watchFromStart"
        case .details: "details"
        case .schedule: "schedule"
        case .favourite: "favourite"
        }
    }

    var title: String {
        switch self {
        case .cancelling: PageWords.cancelling
        case .recordThis(let game): game ? "Record this game" : "Record this programme"
        case .changeRecording: "Change recording"
        case .recordEvery(let title): title
        case .moreOptions: "More options…"
        case .watchOn(let channels): "Watch on… (\(channels) channels)"
        case .watchFromStart: "Watch from start"
        case .details: "Programme details"
        case .schedule: "Channel schedule"
        case .favourite(let channel, let isFavourite): isFavourite ? "Remove \(channel) from favourites" : "Add \(channel) to favourites"
        }
    }

    /// The second line of a RECORD item (#341: only a scheduled recording's state; the others say it in their title).
    var detail: String? {
        switch self {
        case .changeRecording(let status): status
        default: nil
        }
    }

    /// Whether choosing it does anything: Cancelling… (an earlier recording of this being cancelled) is shown disabled,
    /// in every menu that draws these items (ProgrammeMenuCard, the iPhone's On Now menu).
    var isAvailable: Bool { self != .cancelling }
    /// VoiceOver's label for it.
    var accessibilityTitle: String { self == .cancelling ? PageWords.cancellingLabel : title }

    var isRecordSection: Bool {
        switch self {
        case .recordThis, .changeRecording, .recordEvery, .moreOptions, .cancelling: true
        default: false
        }
    }

    var systemImage: String {
        switch self {
        case .cancelling: "hourglass"
        case .recordThis: "record.circle"
        case .changeRecording: "record.circle.fill"
        case .recordEvery: "repeat.circle"
        case .moreOptions: "slider.horizontal.3"
        case .watchOn: "play.rectangle.on.rectangle"
        case .watchFromStart: "backward.end.fill"
        case .details: "info.circle"
        case .schedule: "list.bullet.rectangle"
        case .favourite(_, let isFavourite): isFavourite ? "heart.slash" : "heart"
        }
    }
}

/// What the menu is about.
nonisolated struct ProgrammeMenuSubject: Equatable, Sendable {
    let channelName: String
    /// nil for the channel tile (its menu has no RECORD section).
    let programme: GuideProgramme?
    /// The active schedule's state, when this programme is scheduled ("Recording scheduled", "Recording now").
    var recordingStatus: String? = nil
    /// Sport (Apple 115): the team "Record every <team> game" follows, instead of a series rule; nil: no team rule.
    var everyGameTeam: String? = nil
    /// A Sport card's menu: "Record this game".
    var isGame = false
    var canWatchFromStart = false
    var isFavourite = false
    /// #257: how many channels carry this live event (0 or 1: no Watch on…).
    var watchOnChannels = 0
    /// Mark, 19 Nov 2026: an earlier recording of this is being cancelled (`BrowseModel.cancellingEarlier`).
    var cancelling = false

    /// "ABC TV · 10:20 pm – 11:20 pm" under the menu's title.
    var subtitle: String { [channelName, programme?.timeRange].compactMap { $0 }.joined(separator: " · ") }
    var title: String { programme?.title ?? channelName }
}

nonisolated enum ProgrammeMenu {
    static func items(_ subject: ProgrammeMenuSubject, now: Date) -> [ProgrammeMenuItem] {
        var items: [ProgrammeMenuItem] = []
        if let programme = subject.programme, programme.end > now, subject.cancelling {
            items.append(.cancelling)
        } else if let programme = subject.programme, programme.end > now {
            if let status = subject.recordingStatus {
                items.append(.changeRecording(status: status))
            } else {
                items.append(.recordThis(game: subject.isGame))
            }
            if subject.isGame {
                if let team = subject.everyGameTeam {
                    items.append(.recordEvery(title: "Record every \(team) game"))
                }
            } else {
                items.append(.recordEvery(title: "Record every new episode"))
            }
            items.append(.moreOptions)
        }
        if subject.watchOnChannels > 1 { items.append(.watchOn(channels: subject.watchOnChannels)) }
        if subject.canWatchFromStart { items.append(.watchFromStart) }
        if subject.programme != nil { items.append(.details) }
        items.append(.schedule)
        items.append(.favourite(channel: subject.channelName, isFavourite: subject.isFavourite))
        return items
    }
}

/// What each item does, supplied by the screen that opens the menu. `run` answers nil when it worked (the screen then
/// closes the menu) or the error to show in the card.
struct ProgrammeMenuActions {
    var run: (ProgrammeMenuItem) async -> String?
}

/// The card (Apple TV, iPad): the programme's title and channel, RECORD with its three items, a divider, then the rest.
/// Back (Menu) closes it; focus starts on its first item.
struct ProgrammeMenuCard: View {
    let subject: ProgrammeMenuSubject
    let items: [ProgrammeMenuItem]
    let choose: (ProgrammeMenuItem) -> Void
    let close: () -> Void
    var busy: ProgrammeMenuItem? = nil
    var error: String? = nil
    @FocusState private var focus: String?

    var body: some View {
        fitted
        .padding(EdgeInsets(top: PigSpacing.l, leading: PigSpacing.m, bottom: PigSpacing.m, trailing: PigSpacing.m))
        .frame(width: Self.width, alignment: .leading)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .shadow(color: Color.pigShadow.opacity(0.7), radius: 50, y: 40)
        #if os(tvOS)
        .focusSection()
        .defaultFocus($focus, items.first?.id)
        .onExitCommand(perform: close)
        #endif
        .onAppear { focus = items.first?.id }
    }

    /// #255: on a short screen (iPhone landscape) the card is capped by its overlay and its rows scroll; they ran off the
    /// bottom of the screen. When they fit, nothing changes.
    @ViewBuilder
    private var fitted: some View {
        #if os(tvOS)
        content
        #else
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollIndicators(.visible).accessibilityIdentifier("menu.scroll")
        }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                Text(subject.title).font(Self.titleFont).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                #if os(tvOS)
                // #279: at 23 pt on the television the channel and times can need a second line.
                Text(subject.subtitle).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary)
                    .pigFigures().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                #else
                Text(subject.subtitle).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary)
                    .pigFigures().lineLimit(1)
                #endif
            }
            .padding(.horizontal, PigSpacing.s).padding(.bottom, PigSpacing.s)
            .accessibilityElement(children: .combine)
            let record = items.filter(\.isRecordSection)
            if !record.isEmpty {
                Text("RECORD").font(Self.sectionFont).tracking(1.4).foregroundStyle(Color.pigSecondary)
                    .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                    .accessibilityAddTraits(.isHeader)
                ForEach(record) { item in row(item) }
                Rectangle().fill(Color.pigBorder).frame(height: 1).padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.s)
                    .accessibilityHidden(true)
            }
            ForEach(items.filter { !$0.isRecordSection }) { item in row(item) }
            if let error {
                Text(error).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, PigSpacing.s).padding(.top, PigSpacing.xs)
            }
        }
    }

    private func row(_ item: ProgrammeMenuItem) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: PigSpacing.m) {
                if item.isRecordSection {
                    Circle().fill(item.id == "recordThis" ? Color.pigDanger : Color.clear)
                        .frame(width: Self.dot, height: Self.dot).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(item.title).font(item.isRecordSection ? Self.itemFont : Self.moreFont)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail {
                        Text(detail).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary).pigFigures()
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if busy == item { ProgressView() }
            }
            .padding(.horizontal, PigSpacing.m).padding(.vertical, item.isRecordSection ? PigSpacing.m : PigSpacing.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigMenuRowStyle())
        .focused($focus, equals: item.id)
        .disabled(busy != nil || !item.isAvailable)
        .opacity(item.isAvailable ? 1 : 0.45)
        .accessibilityLabel(item.accessibilityTitle)
        .accessibilityIdentifier("menu.\(item.id)")
    }

    #if os(tvOS)
    static let width: CGFloat = 520
    static let dot: CGFloat = 14
    static let titleFont: Font = .system(size: PigType.cardTitle, weight: .heavy)
    static let subtitleFont: Font = .system(size: PigType.caption)
    static let sectionFont: Font = .system(size: PigType.caption, weight: .bold)
    static let itemFont: Font = .system(size: PigType.body, weight: .bold)
    static let moreFont: Font = .system(size: PigType.secondary, weight: .semibold)
    #else
    static let width: CGFloat = 360
    static let dot: CGFloat = 10
    static let titleFont: Font = .title3.weight(.heavy)
    static let subtitleFont: Font = .footnote
    static let sectionFont: Font = .caption2.weight(.bold)
    static let itemFont: Font = .body.weight(.bold)
    static let moreFont: Font = .body.weight(.semibold)
    #endif
}

/// The card's place beside the focused programme: on its right when the programme is in the left half of the screen,
/// else on its left, vertically centred on it and kept on screen. Pure; tested.
nonisolated enum ProgrammeMenuPlacement {
    static let margin: CGFloat = 24

    static func origin(card: CGSize, beside anchor: CGRect, in bounds: CGSize, gap: CGFloat = 20, margin: CGFloat = margin) -> CGPoint {
        var x = anchor.midX < bounds.width / 2 ? anchor.maxX + gap : anchor.minX - gap - card.width
        x = min(max(margin, x), max(margin, bounds.width - margin - card.width))
        var y = anchor.midY - card.height / 2
        y = min(max(margin, y), max(margin, bounds.height - margin - card.height))
        return CGPoint(x: x, y: y)
    }
}

/// The menu over a screen: the screen dimmed, the card beside `anchor` (window coordinates). Tapping outside closes it
/// on touch; Menu closes it on the TV.
struct ProgrammeMenuOverlay: View {
    let subject: ProgrammeMenuSubject
    let anchor: CGRect
    let now: Date
    let actions: ProgrammeMenuActions
    let close: () -> Void
    @State private var size = CGSize(width: ProgrammeMenuCard.width, height: 400)
    @State private var busy: ProgrammeMenuItem?
    @State private var error: String?

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let local = anchor.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let origin = ProgrammeMenuPlacement.origin(card: size, beside: local, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.pigCanvas.opacity(0.7)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)
                ProgrammeMenuCard(subject: subject, items: ProgrammeMenu.items(subject, now: now), choose: choose,
                                  close: close, busy: busy, error: error)
                    // #255: never taller than the screen less the placement's margins (its rows scroll instead).
                    .frame(maxHeight: max(200, geometry.size.height - 2 * ProgrammeMenuPlacement.margin))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func choose(_ item: ProgrammeMenuItem) {
        busy = item
        error = nil
        Task {
            let failure = await actions.run(item)
            busy = nil
            error = failure
        }
    }
}

extension ScheduledRecording {
    /// The menu's and the pages' word for an active schedule.
    nonisolated var statusWord: String {
        switch status {
        case "recording": "Recording now"
        case "waiting": "Waiting to record"
        default: "Recording scheduled"
        }
    }
}

/// Programme details' recording action (`BrowseModel.programmeRecordAction`).
enum ProgrammeRecordAction: Equatable { case change, record, cancelling, nothing }

extension BrowseModel {
    /// The active schedule recording this programme, if any: at its start, on this channel by the server's identity
    /// (`sameChannel`, the rule a cancellation in progress is matched by). Codex check of 320 (high): by name and start
    /// it could be another channel's of the same name, and Change recording or Cancel then changed that one. A row
    /// matched by name only (no item or stable id: an older server) is bound only when nothing else could be meant: it is
    /// the only such row, the guide's whole channel list has loaded (Codex sign-off of #347, high: while it still pages, a
    /// channel of the same name on a later page is not known yet), and no other guide channel has that name.
    /// `gameId` (Codex review of #347, high): the sport request's game. A row that names another game is never this
    /// one's (the guide may have put game B in the slot game A's schedule was made for); a row naming this game comes
    /// first; a row naming none binds by the guarded channel-and-start rule.
    func activeSchedule(channel: GuideChannel, programme: GuideProgramme, gameId: String? = nil) -> ScheduledRecording? {
        let start = Int64(programme.startTime)
        // A row whose cancellation the server has confirmed (tombstoned) is gone, though the list it is still in has not
        // been read again yet: it is never bound (Change recording would edit what no longer exists).
        let matches = schedules.filter {
            $0.isActive && Int64($0.program_start) == start && Self.sameChannel($0, channel)
                && recordingStore.tombstones[PendingRemoval.key(.cancelSchedule, $0.id)] == nil
                && !(gameId != nil && $0.game != nil && $0.game != gameId)
        }
        if let gameId, let named = matches.first(where: { $0.game == gameId }) { return named }
        if let identified = matches.first(where: { Self.identifiesChannel($0, channel) }) { return identified }
        guard matches.count == 1, let byName = matches.first, guideChannelsComplete else { return nil }
        let namesake = guide.contains { other in
            other.id != channel.id && other.name == channel.name && byName.source_id.map { $0 == other.sourceId } != false
        }
        return namesake ? nil : byName
    }

    /// The schedule names its channel by the server's identity (stable id where both have one, else its item), not only
    /// by the display name (`sameChannel`'s last resort).
    nonisolated static func identifiesChannel(_ schedule: ScheduledRecording, _ channel: GuideChannel) -> Bool {
        guard let source = schedule.source_id, source == channel.sourceId else { return false }
        if let stable = schedule.channel_stable_id, !stable.isEmpty, let mine = channel.stableId, !mine.isEmpty {
            return stable == mine
        }
        guard let item = schedule.channel_item_id, !item.isEmpty else { return false }
        return item == channel.rawID
    }

    /// Every guide channel is loaded: no page in flight or to come (`guideHasMore` is also the cursor of a paging that
    /// stopped on a failure: the list is not whole then either).
    var guideChannelsComplete: Bool { !guide.isEmpty && !guideHasMore && !guidePagingActive }

    /// A record page's bound schedule is still the one its airings bind to now (Codex sign-off of #347, high): checked
    /// again before Save changes or Cancel recording, so a binding made on a partial or since-changed guide is never acted on.
    func stillBinds(_ schedule: ScheduledRecording, _ request: RecordRequest) -> Bool {
        request.airings.contains { activeSchedule(channel: $0.channel, programme: $0.programme, gameId: request.gameId)?.id == schedule.id }
    }

    /// The active schedule a sport record request binds to (Change recording): never one whose cancellation is in
    /// progress (`cancellationInProgress`; its page shows Cancelling… instead, Mark, 19 Nov 2026).
    func bindableSchedule(channel: GuideChannel, programme: GuideProgramme, gameId: String? = nil) -> ScheduledRecording? {
        activeSchedule(channel: channel, programme: programme, gameId: gameId).flatMap { cancellationInProgress($0) ? nil : $0 }
    }

    /// Programme details' recording action: Change recording of its schedule, Record while it has not ended, nothing
    /// after; Cancelling… (disabled) instead of either while an earlier recording of it is being cancelled, by the
    /// record page's own check (`cancellingEarlier`): its Undo open, sent with no answer yet, or listed "cancelling" by
    /// the server (Mark, 19 Nov 2026, D-72; Codex check of 320: the details page still offered Record or Change
    /// recording then).
    func programmeRecordAction(channel: GuideChannel, programme: GuideProgramme, now: Date) -> ProgrammeRecordAction {
        let scheduled = activeSchedule(channel: channel, programme: programme) != nil
        guard scheduled || programme.end > now else { return .nothing }
        if cancellingEarlier(gameId: nil, channel: channel, start: programme.startTime, end: programme.endTime) { return .cancelling }
        return scheduled ? .change : .record
    }

    /// C-L: the recording this programme's schedule is making, when it can be watched from its start.
    func recordingInProgress(channel: GuideChannel, programme: GuideProgramme) -> Recording? {
        guard let schedule = activeSchedule(channel: channel, programme: programme), schedule.status == "recording" else { return nil }
        return recordings.first { item in
            item.canWatchFromStart && (schedule.recording_id.map { $0 == item.id }
                ?? (item.channel_name == channel.name && item.title == programme.title))
        }
    }
}
