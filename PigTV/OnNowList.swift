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

    var body: some View {
        List(rows) { channel in
            OnNowRowView(channel: channel, model: model, clock: clock, play: { play(channel) }, info: { info(channel) })
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("guide.onNow")
    }
}

private struct OnNowRowView: View {
    let channel: GuideChannel
    /// Not observed (audit R05): a row draws the EPG logo fallback and
    /// nothing else that publishes, so only that store is watched.
    let model: BrowseModel
    @ObservedObject private var artwork: ArtworkStore
    let clock: Date
    let play: () -> Void
    let info: () -> Void

    init(channel: GuideChannel, model: BrowseModel, clock: Date, play: @escaping () -> Void, info: @escaping () -> Void) {
        self.channel = channel
        self.model = model
        _artwork = ObservedObject(wrappedValue: model.artwork)
        self.clock = clock
        self.play = play
        self.info = info
    }

    var body: some View {
        let row = OnNowRow.make(programmes: channel.programmes, now: clock)
        let number = model.number(for: channel).map { String($0) }
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ChannelTile(name: channel.name, logo: model.logo(for: channel), client: model.client)
                        .frame(width: 76, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let number { ChannelNumberText(number: number, font: .caption2) }
                            if model.isFlaky(channel) {
                                Circle().fill(Color.orange).frame(width: 8, height: 8)
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
