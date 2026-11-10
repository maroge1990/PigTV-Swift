import SwiftUI

// A4.4: iPhone (compact width) guide. A vertical "On now" list replaces the
// one-hour grid: logo, number, channel name, the programme on now with its
// progress, and what is next. Tap plays; the trailing info button opens the
// channel's schedule. Filters and search are GuideView's, unchanged.

/// One row's programme data, computed per visible row (the guide holds
/// ~18 000 channels, so nothing is precomputed for the whole list).
nonisolated struct OnNowRow: Equatable, Sendable {
    let current: GuideProgramme?
    let next: GuideProgramme?
    /// 0…1 through `current` (0 without one).
    let progress: Double

    static func make(programmes: [GuideProgramme], now: Date) -> OnNowRow {
        let current = GuideNavigation.programme(in: programmes, at: now)
        let next = programmes
            .filter { $0.end > $0.start && $0.start >= (current?.end ?? now) }
            .min { $0.start < $1.start }
        var progress = 0.0
        if let current {
            let length = current.end.timeIntervalSince(current.start)
            progress = length > 0 ? min(1, max(0, now.timeIntervalSince(current.start) / length)) : 0
        }
        return OnNowRow(current: current, next: next, progress: progress)
    }
}

#if os(iOS)
struct OnNowList: View {
    let rows: [GuideChannel]
    let model: BrowseModel
    let clock: Date
    let play: (GuideChannel) -> Void
    let info: (GuideChannel) -> Void
    /// D-44 (Apple 107): the long-press menu, as the system context menu with a preview (R5-Menu-iPhone).
    var menu: (GuideChannel) -> ProgrammeMenuSubject = { ProgrammeMenuSubject(channelName: $0.name, programme: nil) }
    /// The programme is the one the menu showed (Codex, batch 4 medium): never recomputed when an item is chosen.
    var choose: (GuideChannel, GuideProgramme?, ProgrammeMenuItem) -> Void = { _, _, _ in }

    var body: some View {
        List(rows) { channel in
            OnNowRowView(channel: channel, model: model, clock: clock, play: { play(channel) }, info: { info(channel) })
                .contextMenu {
                    let subject = menu(channel)
                    let items = ProgrammeMenu.items(subject, now: Date())
                    let record = items.filter(\.isRecordSection)
                    if !record.isEmpty {
                        Section("Record") {
                            ForEach(record) { item in menuButton(channel, subject.programme, item) }
                        }
                    }
                    Section {
                        ForEach(items.filter { !$0.isRecordSection }) { item in menuButton(channel, subject.programme, item) }
                    }
                } preview: {
                    OnNowMenuPreview(subject: menu(channel), clock: clock)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("guide.onNow")
    }

    /// A chosen item acts on the programme its menu was built with.
    func select(_ channel: GuideChannel, _ programme: GuideProgramme?, _ item: ProgrammeMenuItem) {
        choose(channel, programme, item)
    }

    private func menuButton(_ channel: GuideChannel, _ programme: GuideProgramme?, _ item: ProgrammeMenuItem) -> some View {
        Button { select(channel, programme, item) } label: {
            Label {
                Text(item.title)
                if let detail = item.detail { Text(detail) }
            } icon: { Image(systemName: item.systemImage) }
        }
    }
}

/// The lifted card above the iPhone's menu: when, which channel, the title and its times.
private struct OnNowMenuPreview: View {
    let subject: ProgrammeMenuSubject
    let clock: Date
    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            Text(eyebrow).font(.caption.weight(.bold)).tracking(1).foregroundStyle(Color.pigAccentText)
            Text(subject.title).font(.title3.weight(.heavy)).lineLimit(3)
            if let programme = subject.programme {
                Text(programme.timeRange).font(.subheadline).foregroundStyle(Color.pigSecondary).monospacedDigit().fontDesign(.rounded)
            }
        }
        .padding(PigSpacing.xl)
        .frame(width: 320, alignment: .leading)
        .background(Color.pigSurface)
    }

    private var eyebrow: String {
        guard let programme = subject.programme else { return subject.channelName.uppercased() }
        let when = programme.isLive(at: clock) ? "On now" : "Starts \(Countdown.text(to: programme.start, now: clock))"
        return "\(when) · \(subject.channelName)".uppercased()
    }
}

private struct OnNowRowView: View {
    let channel: GuideChannel
    /// Not observed (audit R05): a row draws nothing that publishes.
    let model: BrowseModel
    let clock: Date
    let play: () -> Void
    let info: () -> Void

    init(channel: GuideChannel, model: BrowseModel, clock: Date, play: @escaping () -> Void, info: @escaping () -> Void) {
        self.channel = channel
        self.model = model
        self.clock = clock
        self.play = play
        self.info = info
    }

    var body: some View {
        let row = OnNowRow.make(programmes: channel.programmes, now: clock)
        let number = model.number(for: channel).map { String($0) }
        HStack(spacing: PigSpacing.m) {
            Button(action: play) {
                HStack(spacing: PigSpacing.m) {
                    ChannelTile(name: channel.name, logo: model.logo(for: channel), client: model.client)
                        .frame(width: 76, height: 48)
                    VStack(alignment: .leading, spacing: PigSpacing.xs) {
                        HStack(spacing: PigSpacing.s) {
                            Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let number { ChannelNumberText(number: number, font: .caption2) }
                            if let quality = model.guideQuality(of: channel) { GuideQualityBadge(quality: quality) }
                            if model.isFlaky(channel) {
                                Circle().fill(Color.pigWarning).frame(width: 8, height: 8)
                                    .accessibilityLabel("Unreliable channel")
                            }
                        }
                        Text(row.current?.title ?? "No programme information")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        if row.current != nil {
                            ProgressView(value: row.progress).tint(Color.pigAccent)
                                .accessibilityHidden(true)
                        }
                        if let next = row.next {
                            Text("\(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([number, channel.name].compactMap { $0 }.joined(separator: " "))
            .accessibilityValue([row.current.map { "Now: \($0.title)" }, row.next.map { "Next: \($0.title)" }]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Plays the channel")
            Button(action: info) {
                Image(systemName: "info.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Schedule for \(channel.name)")
        }
    }
}
#endif
