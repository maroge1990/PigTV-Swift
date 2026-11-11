import SwiftUI

// D-44 (Apple 106): the TV Guide's chrome above the grid (R5-Guide-TV, -iPad): a slim focus strip that reads the focused
// programme, then one row of filter chips and the tools (Now, Earlier, Later, Search, Jump to…). The grid itself and its
// focus model are unchanged (GuideGridView).

/// One filter chip: its filter id (the stored `pigtv.guide.filter`) and title.
nonisolated struct GuideChip: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

/// The chips the data has. Pure; tested (GuideChromeTests).
/// D-44: an iPhone (compact width) lists what is on now when upright and
/// becomes the grid when turned sideways (compact height), every model alike;
/// the iPad and the Apple TV always show the grid.
nonisolated enum GuideLayout {
    static func usesOnNowList(compactWidth: Bool, compactHeight: Bool) -> Bool {
        compactWidth && !compactHeight
    }
}

nonisolated enum GuideChips {
    /// Every category an admin marked as sport (C-H), as one chip.
    static let sport = "sport"

    /// All, Favourites, Sport (when the data has a sport category), then the categories. A lone sport category is the
    /// Sport chip itself, so it is not listed twice; several stay listed one by one after it.
    static func make(categories: [Category]) -> [GuideChip] {
        let sport = categories.filter(\.sport)
        var chips = [GuideChip(id: "all", title: "All"), GuideChip(id: "favourites", title: "Favourites")]
        if !sport.isEmpty { chips.append(GuideChip(id: Self.sport, title: "Sport")) }
        let listed = sport.count == 1 ? categories.filter { !$0.sport } : categories
        return chips + listed.map { GuideChip(id: $0.id, title: $0.name) }
    }

    /// The categories a filter shows (nil: no category filter, as for All and Favourites).
    static func categories(for filter: String, in categories: [Category]) -> [Category]? {
        if filter == sport { return categories.filter(\.sport) }
        return categories.first { $0.id == filter }.map { [$0] }
    }

    /// Whether `chip` is the selected one: a stored filter naming the lone sport category selects the Sport chip.
    static func isSelected(_ chip: GuideChip, filter: String, in categories: [Category]) -> Bool {
        if chip.id == filter { return true }
        let sport = categories.filter(\.sport)
        return chip.id == Self.sport && sport.count == 1 && sport[0].id == filter
    }
}

/// What the focus strip says about the focused programme (or channel tile). Pure; tested (GuideChromeTests).
nonisolated struct GuideStripText: Equatable, Sendable {
    let title: String
    /// "9:30 pm – 5:30 am", or "Tomorrow 9:30 pm – 10:00 pm"; nil when nothing is focused.
    let times: String?
    /// After the times: channel and number, the status word, the description.
    let detail: String
    /// A recording is scheduled or running: the red dot, always beside a word in `detail`.
    let recording: Bool

    static func make(channel: String?, number: Int?, programme: GuideProgramme?, current: GuideProgramme? = nil,
                     scheduled: Bool, recordingNow: Bool, now: Date, hint: String,
                     calendar: Calendar = .current) -> GuideStripText {
        guard let channel else { return GuideStripText(title: "Choose a programme", times: nil, detail: hint, recording: false) }
        let channelText = [channel, number.map { String($0) }].compactMap { $0 }.joined(separator: " ")
        guard let programme else {
            // The channel tile: what is on it now.
            guard let current else {
                return GuideStripText(title: channel, times: nil, detail: "No programme information", recording: false)
            }
            return GuideStripText(title: channel, times: current.timeRange,
                                  detail: ["On now", current.title].joined(separator: " · "), recording: false)
        }
        let live = programme.isLive(at: now)
        var times = programme.timeRange
        if !calendar.isDate(programme.start, inSameDayAs: now) {
            times = "\(DetailText.day(programme.start, now: now, calendar: calendar)) \(times)"
        }
        let status: String?
        if scheduled && recordingNow && live { status = "Recording" }
        else if scheduled { status = "Recording scheduled" }
        else if live { status = "On now" }
        else if programme.end <= now { status = "Ended" }
        else { status = nil }
        let description = programme.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [channelText, status, description?.isEmpty == false ? description : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return GuideStripText(title: programme.title, times: times, detail: detail, recording: scheduled)
    }
}

/// The slim strip above the grid: title (with the red dot and a word when it records), times, channel, status and a
/// short description on one line, then the options hint and Details.
struct GuideFocusStrip<Trailing: View>: View {
    let text: GuideStripText
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Self.spacing) {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                HStack(spacing: PigSpacing.s) {
                    if text.recording {
                        Circle().fill(Color.pigDanger).frame(width: Self.dot, height: Self.dot)
                            .accessibilityHidden(true)
                    }
                    Text(text.title).font(Self.titleFont).lineLimit(1).truncationMode(.tail)
                }
                detailLine.font(Self.detailFont).foregroundStyle(Color.pigSecondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.title)
            .accessibilityValue([text.times, text.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("guide.strip")
            trailing
        }
        .padding(.horizontal, Self.padding)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color.pigSurface, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
    }

    private var detailLine: Text {
        guard let times = text.times else { return Text(text.detail) }
        return Text(times).pigFigures() + Text(" · \(text.detail)")
    }

    #if os(tvOS)
    static var height: CGFloat { 110 }
    static var padding: CGFloat { 28 }
    static var spacing: CGFloat { PigSpacing.l }
    static var dot: CGFloat { 12 }
    static var titleFont: Font { .system(size: PigType.sectionTitle, weight: .heavy) }
    static var detailFont: Font { .system(size: PigType.secondary) }
    #else
    static var height: CGFloat { 64 }
    static var padding: CGFloat { 16 }
    static var spacing: CGFloat { PigSpacing.m }
    static var dot: CGFloat { 9 }
    static var titleFont: Font { .headline.weight(.heavy) }
    static var detailFont: Font { .caption }
    #endif
}

/// A tool beside the chips (Now, Earlier, Later, Search, Jump to…): the chip look without a selection.
struct GuideToolLabel: View {
    let title: String
    let systemImage: String
    var trailingIcon = false
    var body: some View {
        HStack(spacing: PigSpacing.s) {
            if !trailingIcon { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title).fixedSize()
            if trailingIcon { Image(systemName: systemImage).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
