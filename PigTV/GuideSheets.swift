import SwiftUI

// The guide's Search and Jump to… sheets (build 28 consistency pass): the
// app's page, section headings, surface rows and selection chips instead of
// stock Form rows on tvOS.

struct GuideSearchSheet: View {
    @ObservedObject var model: BrowseModel
    @Binding var search: String
    @Binding var programmeSearch: String
    /// Closes the sheet (the channel filter applies as typed).
    let done: () -> Void
    /// A programme result was chosen: its details open once the sheet closes.
    let choose: (GuideChannel, GuideProgramme) -> Void
    let refresh: () -> Void

    var body: some View {
        DetailPage(title: "Search") {
            VStack(alignment: .leading, spacing: 14) {
                PigSectionHeader(title: "Channels")
                HStack(spacing: 20) {
                    TextField("Channel name", text: $search)
                        .autocorrectionDisabled()
                        .pigField()
                        .frame(maxWidth: 720)
                    Button("Show channels", systemImage: "line.3.horizontal.decrease", action: done)
                    if !search.isEmpty {
                        Button("Clear", systemImage: "xmark") { search = ""; done() }
                    }
                }
                #if os(tvOS)
                .font(DetailType.button)
                .focusSection()
                #endif
                Text(search.isEmpty ? "Filters the guide's rows by channel name." : "The guide shows channels matching “\(search)”.")
                    .font(DetailType.rowDetail).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                PigSectionHeader(title: "Programmes")
                TextField("Programme title", text: $programmeSearch)
                    .autocorrectionDisabled()
                    .pigField()
                    .frame(maxWidth: 720)
                let results = model.searchProgrammes(programmeSearch)
                if programmeSearch.count >= 2 && results.isEmpty {
                    Text("No upcoming programmes match.").font(DetailType.meta).foregroundStyle(.secondary)
                } else if programmeSearch.count < 2 {
                    Text("Type at least two letters to search the next 24 hours.")
                        .font(DetailType.rowDetail).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, hit in
                        SearchResultRow(model: model, channel: hit.channel, programme: hit.programme) {
                            choose(hit.channel, hit.programme)
                        }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            Button("Refresh guide", systemImage: "arrow.clockwise", action: refresh)
                #if os(tvOS)
                .font(DetailType.button)
                #endif
        }
    }
}

private struct SearchResultRow: View {
    @ObservedObject var model: BrowseModel
    let channel: GuideChannel
    let programme: GuideProgramme
    let action: () -> Void

    var body: some View {
        let now = Date()
        let live = programme.isLive(at: now)
        Button(action: action) {
            HStack(spacing: 24) {
                #if os(tvOS)
                ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                                size: CGSize(width: 136, height: 76))
                #else
                ChannelLogoTile(logo: model.logo(for: channel), client: model.client, name: channel.name,
                                size: CGSize(width: 72, height: 40))
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(programme.title).font(DetailType.rowTitle).lineLimit(1)
                        if live { StatusBadge(text: "On now") }
                    }
                    Text("\(channel.name) · \(live ? programme.timeRange : "\(DetailText.day(programme.start, now: now)) · \(programme.timeRange)")")
                        .font(DetailType.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(DetailType.rowDetail).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            #if os(tvOS)
            .padding(.horizontal, 22).padding(.vertical, 16)
            #else
            .padding(10)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 18))
        .accessibilityLabel("\(programme.title), \(channel.name), \(DetailText.day(programme.start, now: now)) \(programme.timeRange)")
    }
}

/// Jump to a day and hour of the guide. tvOS: day and hour chips; iOS: a
/// date picker.
struct GuideJumpSheet: View {
    @Binding var date: Date
    let show: (Date) -> Void
    let cancel: () -> Void
    @FocusState private var showFocused: Bool

    var body: some View {
        DetailPage(title: "Jump to…") {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 14) {
                PigSectionHeader(title: "Day")
                HStack(spacing: 14) {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
                        Button(dayTitle(day, offset: offset)) { setDay(day) }
                            .buttonStyle(GuideFilterStyle(selected: Calendar.current.isDate(day, inSameDayAs: date)))
                    }
                }
                .focusSection()
            }
            VStack(alignment: .leading, spacing: 14) {
                PigSectionHeader(title: "Time")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(160), spacing: 14), count: 8), alignment: .leading, spacing: 14) {
                    ForEach(0..<24, id: \.self) { hour in
                        Button(hourTitle(hour)) { setHour(hour) }
                            .buttonStyle(GuideFilterStyle(selected: Calendar.current.component(.hour, from: date) == hour))
                    }
                }
                .focusSection()
            }
            #else
            DatePicker("Date and time", selection: $date)
                .datePickerStyle(.graphical)
            #endif
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                .font(DetailType.meta).foregroundStyle(.secondary)
            DetailActions {
                Button("Show guide", systemImage: "calendar") { show(date) }
                    .pigPrimaryButton()
                    .focused($showFocused)
                Button("Cancel", action: cancel)
            }
        }
    }

    private func dayTitle(_ day: Date, offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return day.formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    private func hourTitle(_ hour: Int) -> String {
        let at = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return at.formatted(date: .omitted, time: .shortened)
    }

    private func setDay(_ day: Date) {
        let hour = Calendar.current.component(.hour, from: date)
        date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private func setHour(_ hour: Int) {
        date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    }
}
