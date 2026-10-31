import SwiftUI

// C-S (#21, Apple 90): the Cricket page, opened from the Sport front page's Cricket tile and the Sport pages list when
// the server advertises `sportPageCricket`. Mark's mock-up ("Cricket · Apple TV"): a header with Following (the
// household's first followed cricket team) and the spoiler-free chip; the lead match on the left (kicker and LIVE pill
// or the next day's countdown, the title, venue and series line, a scores card per team with the batting note, the
// summary and who is at the crease, the day chips, then Watch live / Other channels / Record or Remind me / Record day
// N with the channel beside); the series on the right (every match with its date and result, the current one marked
// with its state); below, "Your other competitions · today and next" as cards (a live one plays on select).
// Spoiler-free draws `CricketPageText.visible`: no innings, summary, crease, series line, results, other scores or lines.
//
// The lead is a C-I event (`CricketPageText.event`): Watch, Remind me ("Watch when it starts"), Record and the channel
// picker are the Sport tab's own, on each channel's airing times (#20). iPad and iPhone stack it in one column.

private enum CricketMetrics {
    #if os(tvOS)
    static let title: Font = .system(size: 46, weight: .heavy)
    static let matchTitle: Font = .system(size: 46, weight: .heavy)
    static let kicker: Font = .system(size: 19, weight: .bold)
    static let cardTitle: Font = .system(size: 26, weight: .bold)
    static let team: Font = .system(size: 26, weight: .semibold)
    static let score: Font = .system(size: 30, weight: .heavy)
    static let detail: Font = .system(size: 20)
    static let meta: Font = .system(size: 22)
    static let chip: Font = .system(size: 22, weight: .medium)
    static let dayLabel: Font = .system(size: 18, weight: .bold)
    static let daySub: Font = .system(size: 16)
    static let otherTeam: Font = .system(size: 20, weight: .semibold)
    static let otherScore: Font = .system(size: 20, weight: .heavy)
    static let otherDetail: Font = .system(size: 17)
    static let spacing: CGFloat = 26
    static let columnGap: CGFloat = 44
    static let sideWidth: CGFloat = 560
    static let otherWidth: CGFloat = 380
    static let badge: CGFloat = 48
    static let radius: CGFloat = 20
    static let dayWidth: CGFloat = 132
    static let cardPadding = EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
    #else
    static let title: Font = .largeTitle.bold()
    static let matchTitle: Font = .title.bold()
    static let kicker: Font = .caption.weight(.bold)
    static let cardTitle: Font = .title3.bold()
    static let team: Font = .headline
    static let score: Font = .title3.bold()
    static let detail: Font = .subheadline
    static let meta: Font = .subheadline
    static let chip: Font = .subheadline
    static let dayLabel: Font = .caption.weight(.bold)
    static let daySub: Font = .caption2
    static let otherTeam: Font = .callout.weight(.semibold)
    static let otherScore: Font = .callout.weight(.heavy)
    static let otherDetail: Font = .footnote
    static let spacing: CGFloat = 18
    static let columnGap: CGFloat = 24
    static let sideWidth: CGFloat = 400
    static let otherWidth: CGFloat = 300
    static let badge: CGFloat = 34
    static let radius: CGFloat = 16
    static let dayWidth: CGFloat = 92
    static let cardPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    #endif
}

struct CricketPageView: View {
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject var model: CricketPageModel
    /// The household's preferences (spoiler-free, the followed teams), shared by every sport page.
    @ObservedObject var preferences: F1PageModel
    /// Observed for the bells (a pending "watch when it starts").
    @ObservedObject private var appState: AppModel
    @Environment(\.sportPresenter) private var presenter
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var recording: SportEvent?
    private enum Control: Hashable { case primary }
    @FocusState private var focus: Control?

    init(app: AppModel, browse: BrowseModel) {
        self.app = app
        self.browse = browse
        self.model = browse.cricketPage
        self.preferences = browse.f1Page
        _appState = ObservedObject(wrappedValue: app)
    }

    private var wide: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop()
        #if os(iOS)
        .navigationTitle("Cricket")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .whileVisible { await model.keepFresh(preferences: preferences) }
        .detailCover(item: $recording) { event in
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme(on: best)) { _ in
                    recording = nil
                }
            }
        }
        .accessibilityIdentifier("cricket.page")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let spoilerFree = preferences.hidesSpoilers
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: CricketMetrics.spacing) {
                header
                if let raw = model.page, raw.available, raw.lead != nil || !raw.others.isEmpty {
                    let page = CricketPageText.visible(raw, spoilerFree: spoilerFree)
                    if wide {
                        HStack(alignment: .top, spacing: CricketMetrics.columnGap) {
                            leadBlock(page, now: now, spoilerFree: spoilerFree).frame(maxWidth: .infinity, alignment: .topLeading)
                            if let series = page.series, !series.matches.isEmpty {
                                seriesPanel(series, lead: page.lead, now: now, spoilerFree: spoilerFree).frame(width: CricketMetrics.sideWidth)
                            }
                        }
                    } else {
                        leadBlock(page, now: now, spoilerFree: spoilerFree)
                        if let series = page.series, !series.matches.isEmpty {
                            seriesPanel(series, lead: page.lead, now: now, spoilerFree: spoilerFree)
                        }
                    }
                    if !page.others.isEmpty { others(page.others, now: now) }
                } else if !model.loaded || model.page?.available == false {
                    ProgressView("Loading cricket…").frame(maxWidth: .infinity).padding(.top, 80)
                } else if model.page != nil {
                    nothingOn
                } else {
                    unavailable
                }
                if let error = preferences.saveError {
                    Text(error).font(CricketMetrics.detail).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .padding(wide ? 32 : 16)
            #endif
        }
        .scrollClipDisabled()
        .defaultFocus($focus, .primary)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            #if os(tvOS)
            Text("Cricket").font(CricketMetrics.title).accessibilityAddTraits(.isHeader)
            #else
            if wide { Text("Cricket").font(CricketMetrics.title).accessibilityAddTraits(.isHeader) }
            #endif
            Spacer(minLength: 0)
            if let team = preferences.preferences.teams["Cricket"]?.first {
                Label("Following \(team)", systemImage: "star.fill").font(CricketMetrics.chip).lineLimit(1)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color.pigRaised, in: Capsule())
                    .accessibilityIdentifier("cricket.following")
            }
            Button { Task { await preferences.setSpoilerFree(!preferences.preferences.spoilerFree) } } label: {
                Label(preferences.preferences.spoilerFree ? "Spoiler-free on" : "Scores shown",
                      systemImage: preferences.preferences.spoilerFree ? "eye.slash" : "eye")
                    .font(CricketMetrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: preferences.preferences.spoilerFree))
            .disabled(!preferences.preferencesKnown)
            .accessibilityLabel(preferences.preferences.spoilerFree ? "Spoiler-free is on" : "Scores are shown")
            .accessibilityHint("Changes it for every device")
            .accessibilityIdentifier("cricket.spoilers")
        }
        .tvFocusSection()
    }

    // MARK: The lead

    @ViewBuilder
    private func leadBlock(_ page: CricketPage, now: Date, spoilerFree: Bool) -> some View {
        if let lead = page.lead {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text(CricketPageText.kicker(lead)).font(CricketMetrics.kicker).tracking(2).foregroundStyle(.secondary)
                    pill(lead, now: now)
                }
                Text(CricketPageText.title(lead.teams)).font(CricketMetrics.matchTitle).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("cricket.lead.title")
                Text(CricketPageText.venueLine(lead)).font(CricketMetrics.meta).foregroundStyle(.secondary)
                scores(lead, spoilerFree: spoilerFree).padding(.top, 10)
                days(lead, now: now).padding(.top, 6)
                actions(lead, now: now).padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No match to lead with").font(CricketMetrics.cardTitle)
                Text("Nothing is live or coming up for the teams you follow.").font(CricketMetrics.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func pill(_ lead: CricketLead, now: Date) -> some View {
        let text = CricketPageText.pill(lead, now: now)
        let live = lead.status == .live
        return Text(text).font(CricketMetrics.kicker).tracking(1)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .foregroundStyle(live ? Color.white : lead.status == .done ? Color.secondary : Color.pigAccentText)
            .background {
                if live { Capsule().fill(Color.pigDanger) }
                else if lead.status == .done { Capsule().fill(Color.pigRaised) }
                else { Capsule().strokeBorder(Color.pigAccentText, lineWidth: 2) }
            }
            .accessibilityIdentifier("cricket.lead.pill")
    }

    private func scores(_ lead: CricketLead, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lead.teams.enumerated()), id: \.offset) { index, team in
                let list = index < lead.innings.count ? lead.innings[index] : []
                let batting = list.contains(where: \.current)
                HStack(spacing: 16) {
                    SportBadge(name: team.name, logo: team.logo, league: "Cricket", client: browse.client, size: CricketMetrics.badge)
                    Text(team.name).font(CricketMetrics.team.weight(batting && !spoilerFree ? .heavy : .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if !spoilerFree {
                        if let note = CricketPageText.battingNote(list, status: lead.status) {
                            Text(note).font(CricketMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let score = CricketPageText.innings(list) {
                            Text(score).font(CricketMetrics.score).monospacedDigit().lineLimit(1)
                                .accessibilityIdentifier("cricket.lead.score.\(index)")
                        }
                    }
                }
                .frame(minHeight: CricketMetrics.badge)
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(Color.pigBorder)
            if spoilerFree {
                Label("Scores hidden · spoiler-free is on", systemImage: "eye.slash").font(CricketMetrics.detail)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cricket.lead.hidden")
            } else if lead.summary != nil || lead.crease != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let summary = lead.summary { Text(summary).font(CricketMetrics.detail.weight(.bold)) }
                    Spacer(minLength: 12)
                    if let crease = CricketPageText.crease(lead.crease) {
                        Text(crease).font(CricketMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(CricketMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: CricketMetrics.radius, style: .continuous))
    }

    @ViewBuilder
    private func days(_ lead: CricketLead, now: Date) -> some View {
        if lead.days.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(lead.days) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Day \(day.number)").font(CricketMetrics.dayLabel)
                            Text(CricketPageText.daySub(day, lead: lead, now: now)).font(CricketMetrics.daySub)
                                .foregroundStyle(day.state == .live ? Color.white : Color.secondary).lineLimit(1)
                        }
                        .foregroundStyle(day.state == .live ? Color.white : Color("PigText"))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .frame(minWidth: CricketMetrics.dayWidth, alignment: .leading)
                        .background { dayBackground(day.state) }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("cricket.day.\(day.number).\(day.state.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .accessibilityLabel("Match days")
        }
    }

    @ViewBuilder
    private func dayBackground(_ state: CricketDay.State) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch state {
        case .live: shape.fill(Color.pigDanger)
        case .next: shape.strokeBorder(Color.pigAccentText, lineWidth: 2)
        case .done: shape.fill(Color.pigRaised)
        case .later: shape.fill(Color.pigSurface)
        }
    }

    @ViewBuilder
    private func actions(_ lead: CricketLead, now: Date) -> some View {
        let event = CricketPageText.event(lead)
        let offered = CricketPageText.actions(lead, now: now, pendingEventID: appState.pendingWatch?.eventID)
            .filter { $0 != .otherChannels || presenter != nil }
        // iPhone: one under the other (the labels would not fit side by side).
        let layout = wide ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        layout {
            ForEach(Array(offered.enumerated()), id: \.offset) { index, action in
                actionButton(action, lead: lead, event: event, primary: index == 0)
            }
            Text(CricketPageText.channelLine(lead, now: now)).font(CricketMetrics.detail).foregroundStyle(.secondary)
                .lineLimit(1).padding(.leading, wide ? 8 : 0)
        }
        .tvFocusSection()
    }

    @ViewBuilder
    private func actionButton(_ action: CricketPageText.Action, lead: CricketLead, event: SportEvent, primary: Bool) -> some View {
        let button = Button(CricketPageText.label(action), systemImage: icon(action)) {
            switch action {
            case .watchLive:
                // Decided again at the press: the page may have been open since before the airing ended.
                if let current = model.page?.lead, CricketPageText.actions(current, now: Date(), pendingEventID: nil).contains(.watchLive) {
                    play(CricketPageText.event(current))
                }
            case .otherChannels: presenter?.open(event, .channels)
            case .remind: app.watchWhenStarts(event, now: Date())
            case .cancelRemind: app.cancelPendingWatch()
            case .record: recording = event
            }
        }
        .accessibilityIdentifier("cricket.action.\(identifier(action))")
        if primary {
            button.pigPrimaryButton().focused($focus, equals: .primary)
        } else {
            button
        }
    }

    private func icon(_ action: CricketPageText.Action) -> String {
        switch action {
        case .watchLive: return "play.fill"
        case .otherChannels: return "list.bullet"
        case .remind: return "bell"
        case .cancelRemind: return "bell.slash"
        case .record: return "record.circle"
        }
    }

    private func identifier(_ action: CricketPageText.Action) -> String {
        switch action {
        case .watchLive: return "watch"
        case .otherChannels: return "channels"
        case .remind: return "remind"
        case .cancelRemind: return "cancelRemind"
        case .record: return "record"
        }
    }

    private func play(_ event: SportEvent) {
        if let presenter { presenter.play(event) } else { app.playSportEvent(event) }
    }

    // MARK: The series

    private func seriesPanel(_ series: CricketSeries, lead: CricketLead?, now: Date, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.name ?? "Series").font(CricketMetrics.cardTitle).lineLimit(1)
                Spacer(minLength: 8)
                if let season = series.season {
                    Text(season.replacingOccurrences(of: "/", with: "–")).font(CricketMetrics.detail).foregroundStyle(.secondary)
                }
            }
            ForEach(series.matches) { match in
                let text = CricketPageText.seriesResult(match, lead: lead, spoilerFree: spoilerFree, now: now)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.label ?? "Match").font(CricketMetrics.detail.weight(.bold)).lineLimit(1)
                        if let when = CricketPageText.span(start: match.start, end: match.end) {
                            Text(when).font(CricketMetrics.otherDetail).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if match.current {
                        Text(text).font(CricketMetrics.otherDetail.weight(.heavy))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .foregroundStyle(lead?.status == .live ? Color.white : Color.pigAccentText)
                            .background {
                                if lead?.status == .live { Capsule().fill(Color.pigDanger) }
                                else { Capsule().strokeBorder(Color.pigAccentText, lineWidth: 2) }
                            }
                    } else {
                        Text(text).font(CricketMetrics.otherDetail.weight(.semibold)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).lineLimit(2)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
                .background(match.current ? Color.pigDanger.opacity(0.08) : .clear)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.pigBorder).frame(height: 1) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cricket.series.\(match.id)")
            }
        }
        .padding(CricketMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: CricketMetrics.radius + 4, style: .continuous))
    }

    // MARK: Other competitions

    private func others(_ list: [CricketOther], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your other competitions · today and next").font(CricketMetrics.cardTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if wide {
                    Text(competitions(list)).font(CricketMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: CricketMetrics.otherWidth), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(list) { other in otherCard(other, now: now) }
            }
            .tvFocusSection()
        }
    }

    private func competitions(_ list: [CricketOther]) -> String {
        var seen: [String] = []
        for name in list.compactMap(\.competition) where !seen.contains(name) { seen.append(name) }
        return seen.joined(separator: " · ")
    }

    private func otherCard(_ other: CricketOther, now: Date) -> some View {
        let event = CricketPageText.event(other)
        let live = other.status == .live
        return Button { select(other) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text((other.competition ?? "Cricket").uppercased()).font(CricketMetrics.otherDetail.weight(.bold)).tracking(1.2)
                    .foregroundStyle(.secondary).lineLimit(1)
                ForEach(Array(other.teams.enumerated()), id: \.offset) { index, team in
                    HStack(spacing: 10) {
                        Text(team.name).font(CricketMetrics.otherTeam).lineLimit(1)
                        Spacer(minLength: 6)
                        if index < other.scores.count, let score = other.scores[index] {
                            Text(score).font(CricketMetrics.otherScore).monospacedDigit().lineLimit(1)
                        }
                    }
                }
                if let line = other.line {
                    Text(line).font(CricketMetrics.otherDetail).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(CricketPageText.otherStatus(other, now: now)).font(CricketMetrics.otherDetail.weight(live ? .heavy : .semibold))
                        .foregroundStyle(live ? Color.pigDanger : other.status == .scheduled ? Color.pigAccentText : Color.secondary)
                    Spacer(minLength: 6)
                    Text(event.best?.name ?? (other.status == .done ? "" : "Not in guide yet")).font(CricketMetrics.otherDetail)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(CricketMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: CricketMetrics.radius, style: .continuous)
                    .strokeBorder(live ? Color.pigDanger.opacity(0.35) : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(PigSurfaceButtonStyle(cornerRadius: CricketMetrics.radius))
        .accessibilityIdentifier("cricket.other.\(other.id)")
    }

    /// A card plays when its channel airs it now (decided at the press), else opens the event page (Record, Remind me,
    /// the channels) when the guide carries it.
    private func select(_ other: CricketOther) {
        let event = CricketPageText.event(other)
        if CricketPageText.othersPlaysNow(other, now: Date()) { play(event) }
        else if event.best != nil, other.status != .done { presenter?.open(event, .details) }
    }

    // MARK: States

    private var nothingOn: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.cricket").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("No cricket today or tomorrow").font(DetailType.title).multilineTextAlignment(.center)
        }
        .padding(.vertical, 70).frame(maxWidth: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.cricket").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("Cricket is unavailable right now").font(DetailType.title).multilineTextAlignment(.center)
            Text(model.error ?? "The match data could not be reached. The guide and playback are not affected.")
                .font(DetailType.meta).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
        }
        .padding(.vertical, 70).frame(maxWidth: .infinity)
    }
}
