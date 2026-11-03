import SwiftUI

// D-44 (Apple 107): the one long-press menu (R5-Menu-TV, -iPad, -iPhone). A card beside the focused programme on the
// Apple TV and the iPad; the system context menu, with a preview, on the iPhone. RECORD first (this programme, every
// new episode or every game, More options…), then Watch from start, Programme details, Channel schedule and the
// channel's favourite. Its items are pure (`ProgrammeMenu.items`, tested in ProgrammeMenuTests); the screen that opens
// it (the Guide now, Sport cards next) supplies what each one does (`ProgrammeMenuActions`).

/// One menu item.
nonisolated enum ProgrammeMenuItem: Equatable, Identifiable, Sendable {
    /// `game`: a Sport card's ("Record this game").
    case recordThis(times: String, game: Bool = false)
    /// D-44 batch 5 (Apple 114): already scheduled or recording: the record page as "Change recording" (its times, and
    /// Cancel recording with Undo). Replaces batch 4's "Cancel this recording".
    case changeRecording(status: String)
    /// "Record every new episode" (a series rule) or, for sport, "Record every game".
    case recordEvery(title: String, detail: String)
    case moreOptions
    case watchFromStart
    case details
    case schedule
    case favourite(channel: String, isFavourite: Bool)

    var id: String {
        switch self {
        case .recordThis: "recordThis"
        case .changeRecording: "changeRecording"
        case .recordEvery: "recordEvery"
        case .moreOptions: "moreOptions"
        case .watchFromStart: "watchFromStart"
        case .details: "details"
        case .schedule: "schedule"
        case .favourite: "favourite"
        }
    }

    var title: String {
        switch self {
        case .recordThis(_, let game): game ? "Record this game" : "Record this programme"
        case .changeRecording: "Change recording"
        case .recordEvery(let title, _): title
        case .moreOptions: "More options…"
        case .watchFromStart: "Watch from start"
        case .details: "Programme details"
        case .schedule: "Channel schedule"
        case .favourite(let channel, let isFavourite): isFavourite ? "Remove \(channel) from favourites" : "Add \(channel) to favourites"
        }
    }

    /// The second line of a RECORD item.
    var detail: String? {
        switch self {
        case .recordThis(let times, _): "\(times), with the usual padding"
        case .changeRecording(let status): status
        case .recordEvery(_, let detail): detail
        case .moreOptions: "Start early, finish late"
        default: nil
        }
    }

    var isRecordSection: Bool {
        switch self {
        case .recordThis, .changeRecording, .recordEvery, .moreOptions: true
        default: false
        }
    }

    var systemImage: String {
        switch self {
        case .recordThis: "record.circle"
        case .changeRecording: "record.circle.fill"
        case .recordEvery: "repeat.circle"
        case .moreOptions: "slider.horizontal.3"
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
    var rulesAvailable = false
    /// Sport (Apple 115): the team "Record every <team> game" follows, instead of a series rule; nil: no team rule.
    var everyGameTeam: String? = nil
    /// A Sport card's menu: "Record this game".
    var isGame = false
    var canWatchFromStart = false
    var isFavourite = false

    /// "ABC TV · 10:20 pm – 11:20 pm" under the menu's title.
    var subtitle: String { [channelName, programme?.timeRange].compactMap { $0 }.joined(separator: " · ") }
    var title: String { programme?.title ?? channelName }
}

nonisolated enum ProgrammeMenu {
    static func items(_ subject: ProgrammeMenuSubject, now: Date) -> [ProgrammeMenuItem] {
        var items: [ProgrammeMenuItem] = []
        if let programme = subject.programme, programme.end > now {
            if let status = subject.recordingStatus {
                items.append(.changeRecording(status: status))
            } else {
                items.append(.recordThis(times: programme.timeRange, game: subject.isGame))
            }
            if subject.isGame {
                if let team = subject.everyGameTeam, subject.rulesAvailable {
                    items.append(.recordEvery(title: "Record every \(team) game", detail: "Every game of the team, never replays"))
                }
            } else if subject.rulesAvailable {
                items.append(.recordEvery(title: "Record every new episode", detail: "\(programme.title) on \(subject.channelName)"))
            }
            items.append(.moreOptions)
        }
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
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(subject.title).font(Self.titleFont).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(subject.subtitle).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary)
                    .monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
            let record = items.filter(\.isRecordSection)
            if !record.isEmpty {
                Text("RECORD").font(Self.sectionFont).tracking(1.4).foregroundStyle(Color.pigSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(record) { item in row(item) }
                Rectangle().fill(Color.pigBorder).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
            ForEach(items.filter { !$0.isRecordSection }) { item in row(item) }
            if let error {
                Text(error).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 18, bottom: 18, trailing: 18))
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

    private func row(_ item: ProgrammeMenuItem) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 14) {
                if item.isRecordSection {
                    Circle().fill(item.id == "recordThis" ? Color.pigDanger : Color.clear)
                        .frame(width: Self.dot, height: Self.dot).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(item.isRecordSection ? Self.itemFont : Self.moreFont)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail {
                        Text(detail).font(Self.subtitleFont).foregroundStyle(Color.pigSecondary).monospacedDigit()
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if busy == item { ProgressView() }
            }
            .padding(.horizontal, 16).padding(.vertical, item.isRecordSection ? 14 : 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigMenuRowStyle())
        .focused($focus, equals: item.id)
        .disabled(busy != nil)
        .accessibilityIdentifier("menu.\(item.id)")
    }

    #if os(tvOS)
    static let width: CGFloat = 520
    static let dot: CGFloat = 14
    static let titleFont: Font = .system(size: 28, weight: .heavy)
    static let subtitleFont: Font = .system(size: 18)
    static let sectionFont: Font = .system(size: 15, weight: .bold)
    static let itemFont: Font = .system(size: 22, weight: .bold)
    static let moreFont: Font = .system(size: 21, weight: .semibold)
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
    static func origin(card: CGSize, beside anchor: CGRect, in bounds: CGSize, gap: CGFloat = 20, margin: CGFloat = 24) -> CGPoint {
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

extension BrowseModel {
    /// The active schedule recording this programme, if any.
    func activeSchedule(channel: GuideChannel, programme: GuideProgramme) -> ScheduledRecording? {
        let key = ScheduledRecording.key(channel: channel.name, start: programme.startTime)
        return schedules.first { $0.isActive && $0.guideKey == key }
    }

    /// C-L: the recording this programme's schedule is making, when it can be watched from its start.
    func recordingInProgress(channel: GuideChannel, programme: GuideProgramme) -> Recording? {
        guard client.info?.features.recordingWatchLive == true,
              let schedule = activeSchedule(channel: channel, programme: programme), schedule.status == "recording" else { return nil }
        return recordings.first { item in
            item.canWatchFromStart && (schedule.recording_id.map { $0 == item.id }
                ?? (item.channel_name == channel.name && item.title == programme.title))
        }
    }
}
