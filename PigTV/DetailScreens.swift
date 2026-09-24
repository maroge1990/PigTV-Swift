import SwiftUI

// Build 28 (Mark: "the programme information page is not really in line with
// the theming elsewhere"): Programme, Channel and Channel schedule screens in
// the app's language (DetailComponents.swift): a hero card over the channel's
// blurred logo colours, a row of the app's focusable buttons, guideCell rows.

// MARK: Programme

struct ProgrammeDetails: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let watch: () -> Void
    /// Opens the channel's schedule (the caller closes this page first);
    /// nil hides the button (e.g. when already inside the schedule).
    var openSchedule: (() -> Void)? = nil
    @State private var recordSheet = false
    @State private var scheduledHere = false
    private enum Control: Hashable { case watch, record }
    @FocusState private var focus: Control?

    private var schedule: ScheduledRecording? {
        let key = ScheduledRecording.key(channel: channel.name, start: programme.startTime)
        return model.schedules.first { $0.isActive && $0.guideKey == key }
    }

    private var recorded: Recording? {
        model.recordings.first { item in
            item.status == "completed" && item.title == programme.title && item.channel_name == channel.name
                && (item.started.map { $0 >= programme.start.addingTimeInterval(-900) && $0 < programme.end } ?? false)
        }
    }

    var body: some View {
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let live = programme.isLive(at: now)
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    hero(now: now, live: live)
                    if let description = programme.description, !description.isEmpty {
                        Text(description)
                            .font(DetailType.body).lineSpacing(6)
                            .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DetailActions {
                        if live {
                            Button("Watch live", systemImage: "play.fill", action: watch)
                                .pigPrimaryButton()
                                .focused($focus, equals: .watch)
                        }
                        if programme.end > now && schedule == nil && !scheduledHere {
                            Button("Record", systemImage: "record.circle") { recordSheet = true }
                                .disabled(model.mutationBusy)
                                .focused($focus, equals: .record)
                                .accessibilityIdentifier("details.record")
                        }
                        if let openSchedule {
                            Button("Channel schedule", systemImage: "list.bullet.rectangle", action: openSchedule)
                        }
                        FavouriteButton(model: model, channel: model.asChannel(channel))
                    }
                    .defaultFocus($focus, live ? .watch : .record)
                    if programme.end <= now {
                        Text("This programme has ended. Catch-up playback is not available.")
                            .font(DetailType.meta).foregroundStyle(.secondary)
                    }
                    if let message = model.actionMessage, scheduledHere {
                        Text(message).font(DetailType.meta).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.mutationBusy)
        .onAppear { model.actionError = nil; model.actionMessage = nil }
        .detailCover(isPresented: $recordSheet) {
            RecordSheet(model: model, channel: channel, programme: programme) { scheduled in
                if scheduled { scheduledHere = true }
                recordSheet = false
            }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "record" { recordSheet = true }
        }
        #endif
    }

    private func hero(now: Date, live: Bool) -> some View {
        DetailHero(logo: model.logo(for: channel), client: model.client) {
            HStack(alignment: .top) {
                ChannelLine(logo: model.logo(for: channel), client: model.client, name: channel.name,
                            number: model.number(for: channel))
                Spacer(minLength: 20)
                statusBadge(now: now)
            }
            .padding(.bottom, 12)
            Eyebrow(text: eyebrow(now: now, live: live), colour: programme.end <= now ? .secondary : .pigAccent)
            Text(programme.title).font(DetailType.title).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta(now: now, live: live)).font(DetailType.meta).foregroundStyle(.secondary)
            if live {
                HStack(spacing: 18) {
                    PigProgressBar(fraction: now.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start), height: 6)
                        .frame(maxWidth: 640)
                    Text("\(DetailText.duration(programme.end.timeIntervalSince(now).rounded(.up))) left")
                        .font(DetailType.meta).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(now: Date) -> some View {
        if let schedule {
            switch schedule.status {
            case "recording": StatusBadge(text: "Recording now", systemImage: "record.circle.fill", colour: .red)
            case "waiting": StatusBadge(text: "Waiting to record", systemImage: "hourglass", colour: .orange)
            default: StatusBadge(text: "Recording scheduled", systemImage: "record.circle", colour: .red)
            }
        } else if scheduledHere {
            StatusBadge(text: "Recording scheduled", systemImage: "record.circle", colour: .red)
        } else if recorded != nil {
            StatusBadge(text: "Recorded", systemImage: "checkmark.circle.fill")
        }
    }

    private func eyebrow(now: Date, live: Bool) -> String {
        if live { return "On now" }
        if programme.end <= now { return "Ended" }
        if programme.start.timeIntervalSince(now) <= 3600 { return "Starts \(HomeRows.countdown(to: programme.start, now: now))" }
        return DetailText.day(programme.start, now: now)
    }

    private func meta(now: Date, live: Bool) -> String {
        var parts = [programme.timeRange, programme.durationText]
        if !live, programme.end > now, programme.start.timeIntervalSince(now) <= 3600 {
            parts.insert(DetailText.day(programme.start, now: now), at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

/// Recording options: how early to start and how late to finish, then
/// Schedule. The sheet itself is the confirmation (it carries the one-stream
/// note the old dialog showed).
private struct RecordSheet: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let done: (Bool) -> Void
    @State private var before = 0
    @State private var after = 0
    @FocusState private var scheduleFocused: Bool

    var body: some View {
        DetailPage {
            DetailHero(logo: model.logo(for: channel), client: model.client) {
                Eyebrow(text: "Record")
                Text(programme.title).font(DetailType.title).lineLimit(2)
                Text("\(channel.name) · \(programme.isLive(at: Date()) ? "On now" : DetailText.day(programme.start, now: Date())) · \(programme.timeRange)")
                    .font(DetailType.meta).foregroundStyle(.secondary)
            }
            choice("Start early", options: [0, 1, 2, 5, 10], selection: $before)
            choice("Finish late", options: [0, 2, 5, 10, 15, 30], selection: $after)
            Text("PigTV has one provider stream, so recording may need live playback to stop. If the programme has already started, only the rest of it is recorded.")
                .font(DetailType.meta).foregroundStyle(.secondary)
                .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
            if model.mutationBusy { ProgressView("Scheduling…") }
            if let error = model.actionError {
                Text(error).font(DetailType.meta).foregroundStyle(.secondary)
                    .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
            }
            DetailActions {
                Button("Schedule recording", systemImage: "record.circle") {
                    Task {
                        let scheduled = await model.schedule(channel: channel, programme: programme, before: before, after: after)
                        if scheduled { done(true) }
                    }
                }
                .pigPrimaryButton()
                .disabled(model.mutationBusy)
                .focused($scheduleFocused)
                .accessibilityIdentifier("record.schedule")
                Button("Cancel") { done(false) }
            }
        }
        .interactiveDismissDisabled(model.mutationBusy)
        .defaultFocus($scheduleFocused, true)
    }

    private func choice(_ title: String, options: [Int], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PigSectionHeader(title: title)
            #if os(tvOS)
            HStack(spacing: 14) { chips(options, selection) }.focusSection()
            #else
            ScrollView(.horizontal) { HStack(spacing: 10) { chips(options, selection) } }.scrollIndicators(.hidden)
            #endif
        }
    }

    private func chips(_ options: [Int], _ selection: Binding<Int>) -> some View {
        ForEach(options, id: \.self) { minutes in
            Button { selection.wrappedValue = minutes } label: {
                Text(minutes == 0 ? "On time" : "\(minutes) min").lineLimit(1).fixedSize()
            }
                .buttonStyle(GuideFilterStyle(selected: selection.wrappedValue == minutes))
                .accessibilityAddTraits(selection.wrappedValue == minutes ? .isSelected : [])
        }
    }
}

// MARK: Channel schedule

/// Upcoming programmes grouped by day ("Today", "Tomorrow", …).
nonisolated enum ScheduleDays {
    struct Day: Equatable, Sendable {
        let title: String
        let programmes: [GuideProgramme]
    }

    /// Programmes not yet finished, one per start time, in order, grouped by
    /// the day they start (the one on now is under Today).
    static func group(_ programmes: [GuideProgramme], now: Date, calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for programme in GuideNavigation.ordered(programmes) where programme.end > now {
            let title = DetailText.day(max(programme.start, now), now: now, calendar: calendar)
            if days.last?.title == title {
                days[days.count - 1] = Day(title: title, programmes: days[days.count - 1].programmes + [programme])
            } else {
                days.append(Day(title: title, programmes: [programme]))
            }
        }
        return days
    }
}

// Every programme on one channel from now onwards, for picking something to
// watch or record without steering through the grid.
struct ChannelScheduleView: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let logo: String?
    let watch: () -> Void
    @State private var selection: ScheduleSelection?
    @FocusState private var watchFocused: Bool

    private struct ScheduleSelection: Identifiable {
        let programme: GuideProgramme
        var id: Double { programme.startTime }
    }

    var body: some View {
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let row = OnNowRow.make(programmes: channel.programmes, now: now)
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    DetailHero(logo: logo, client: model.client) {
                        ChannelLine(logo: logo, client: model.client, name: channel.name, number: model.number(for: channel),
                                    detail: "Schedule")
                            .padding(.bottom, 12)
                        if let current = row.current {
                            Eyebrow(text: "On now")
                            Text(current.title).font(DetailType.title).lineLimit(2)
                            Text("\(current.timeRange) · \(DetailText.duration(current.end.timeIntervalSince(now).rounded(.up))) left")
                                .font(DetailType.meta).foregroundStyle(.secondary)
                            PigProgressBar(fraction: row.progress, height: 6).frame(maxWidth: 640)
                        } else {
                            Text("No programme information right now").font(DetailType.meta).foregroundStyle(.secondary)
                        }
                    }
                    DetailActions {
                        Button("Watch live", systemImage: "play.fill", action: watch)
                            .pigPrimaryButton()
                            .focused($watchFocused)
                        FavouriteButton(model: model, channel: model.asChannel(channel))
                    }
                    .defaultFocus($watchFocused, true)
                    let days = ScheduleDays.group(channel.programmes, now: now)
                    if days.isEmpty {
                        Text("No programme information for this channel.").font(DetailType.meta).foregroundStyle(.secondary)
                    }
                    ForEach(days, id: \.title) { day in
                        VStack(alignment: .leading, spacing: 14) {
                            PigSectionHeader(title: day.title)
                            ForEach(day.programmes, id: \.startTime) { programme in
                                ScheduleRow(programme: programme, now: now,
                                            scheduled: model.scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime))) {
                                    selection = ScheduleSelection(programme: programme)
                                }
                            }
                        }
                        #if os(tvOS)
                        .focusSection()
                        #endif
                    }
                }
            }
        }
        .detailCover(item: $selection) { item in
            ProgrammeDetails(model: model, channel: channel, programme: item.programme) {
                selection = nil
                watch()
            }
        }
    }
}

private struct ScheduleRow: View {
    let programme: GuideProgramme
    let now: Date
    let scheduled: Bool
    let action: () -> Void

    var body: some View {
        let live = programme.isLive(at: now)
        Button(action: action) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(programme.start.formatted(date: .omitted, time: .shortened))
                        .font(DetailType.rowTitle.monospacedDigit())
                    Text(programme.durationText).font(DetailType.rowDetail).foregroundStyle(.secondary)
                }
                #if os(tvOS)
                .frame(width: 170, alignment: .leading)
                #else
                .frame(width: 84, alignment: .leading)
                #endif
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        Text(programme.title).font(DetailType.rowTitle).lineLimit(1)
                        if live { StatusBadge(text: "On now") }
                        if scheduled { StatusBadge(text: "REC", systemImage: "record.circle.fill", colour: .red) }
                    }
                    if let description = programme.description, !description.isEmpty {
                        Text(description).font(DetailType.rowDetail).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if live {
                        PigProgressBar(fraction: now.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start))
                            .frame(maxWidth: 520)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(DetailType.rowDetail).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, 28).padding(.vertical, 20)
            #else
            .padding(14)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 18))
        .accessibilityLabel("\(programme.start.formatted(date: .omitted, time: .shortened)), \(programme.title)\(live ? ", on now" : "")\(scheduled ? ", recording scheduled" : "")")
    }
}

// MARK: Channel

/// "Channel and favourites" (the guide's long-press menu): what is on now
/// and next from the loaded guide, Watch live, favourite, schedule.
struct ChannelDetails: View {
    let channel: Channel
    var browse: BrowseModel? = nil
    let watch: () -> Void
    var openSchedule: (() -> Void)? = nil
    @FocusState private var watchFocused: Bool

    /// The guide's day for this channel; the server's now/next otherwise.
    private var programmes: [GuideProgramme] {
        let guide = browse?.programmes(for: channel) ?? []
        if !guide.isEmpty { return guide }
        return [channel.now, channel.next].compactMap { $0 }.map {
            GuideProgramme(title: $0.title, description: nil, startTime: $0.startTime, endTime: $0.endTime)
        }
    }

    var body: some View {
        let logo = browse?.logo(for: channel) ?? channel.logo
        DetailPage {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let row = OnNowRow.make(programmes: programmes, now: now)
                VStack(alignment: .leading, spacing: DetailMetrics.spacing) {
                    DetailHero(logo: logo, client: browse?.client) {
                        ChannelLine(logo: logo, client: browse?.client, name: channel.name, number: channel.number,
                                    detail: "Channel")
                            .padding(.bottom, 12)
                        if let current = row.current {
                            Eyebrow(text: "On now")
                            Text(current.title).font(DetailType.title).lineLimit(2)
                            Text("\(current.timeRange) · \(DetailText.duration(current.end.timeIntervalSince(now).rounded(.up))) left")
                                .font(DetailType.meta).foregroundStyle(.secondary)
                            PigProgressBar(fraction: row.progress, height: 6).frame(maxWidth: 640)
                        } else {
                            Text("Programme information unavailable").font(DetailType.meta).foregroundStyle(.secondary)
                        }
                    }
                    if let description = row.current?.description, !description.isEmpty {
                        Text(description).font(DetailType.body).lineSpacing(6).lineLimit(4)
                            .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
                    }
                    DetailActions {
                        Button("Watch live", systemImage: "play.fill", action: watch)
                            .pigPrimaryButton()
                            .focused($watchFocused)
                        if let browse { FavouriteButton(model: browse, channel: channel) }
                        if let openSchedule {
                            Button("Channel schedule", systemImage: "list.bullet.rectangle", action: openSchedule)
                        }
                    }
                    .defaultFocus($watchFocused, true)
                    if let next = row.next {
                        PigSectionHeader(title: "Up next")
                        UpNextCard(programme: next, now: now)
                    }
                }
            }
        }
    }
}

private struct UpNextCard: View {
    let programme: GuideProgramme
    let now: Date
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text(programme.start.formatted(date: .omitted, time: .shortened)).font(DetailType.rowTitle.monospacedDigit())
                Text(HomeRows.countdown(to: programme.start, now: now)).font(DetailType.rowDetail).foregroundStyle(Color.pigAccent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(programme.title).font(DetailType.rowTitle)
                Text("\(programme.timeRange) · \(programme.durationText)").font(DetailType.rowDetail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        #if os(tvOS)
        .padding(.horizontal, 28).padding(.vertical, 20)
        #else
        .padding(14)
        #endif
        .frame(maxWidth: DetailMetrics.readingWidth, alignment: .leading)
        .background(Color.guideCell(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
