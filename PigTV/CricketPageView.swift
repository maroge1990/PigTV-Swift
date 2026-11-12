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
    static let title: Font = .system(size: PigType.pageTitle, weight: .heavy)
    static let matchTitle: Font = .system(size: PigType.pageTitle, weight: .heavy)
    static let kicker: Font = .system(size: PigType.secondary, weight: .bold)
    static let cardTitle: Font = .system(size: PigType.cardTitle, weight: .bold)
    static let team: Font = .system(size: PigType.cardTitle, weight: .semibold)
    static let score: Font = .system(size: PigType.sectionTitle, weight: .heavy)
    static let detail: Font = .system(size: PigType.secondary)
    static let meta: Font = .system(size: PigType.body)
    static let chip: Font = .system(size: PigType.body, weight: .medium)
    static let dayLabel: Font = .system(size: PigType.caption, weight: .bold)
    static let daySub: Font = .system(size: PigType.caption)
    static let otherTeam: Font = .system(size: PigType.secondary, weight: .semibold)
    static let otherScore: Font = .system(size: PigType.secondary, weight: .heavy)
    static let otherDetail: Font = .system(size: PigType.caption)
    static let spacing: CGFloat = PigSpacing.l
    static let columnGap: CGFloat = 44
    static let sideWidth: CGFloat = SportCricketMetrics.sideWidth
    static let otherWidth: CGFloat = 380
    static let badge: CGFloat = 48
    static let radius: CGFloat = 20
    static let dayWidth: CGFloat = 132
    static let cardPadding = EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
    #else
    static var title: Font { PigPageHeaderMetrics.title } // #226: the tabs' title style
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
    static let spacing: CGFloat = PigSpacing.l
    static let columnGap: CGFloat = 24
    static let sideWidth: CGFloat = SportCricketMetrics.sideWidth
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
    /// #278 (audit D5): the Hide scores chip, saved through Settings › Sport's model.
    @ObservedObject private var hideScores: HideScoresChip
    /// Observed for the bells (a pending "watch when it starts").
    @ObservedObject private var appState: AppModel
    @Environment(\.sportPresenter) private var presenter
    @Environment(\.sportNarrow) private var narrow
    @Environment(\.sportHidesSpoilers) private var pageHidesSpoilers
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private enum Control: Hashable { case primary }
    @FocusState private var focus: Control?
    /// D-43: under a sport page's banner: no header, no scroll view of its own.
    let embedded: Bool
    /// D-43: the league the sport page's banner selected (its lead, tour and matches first; the other leagues' below).
    let scope: CricketLeagueScope?
    /// What shows when the page has nothing for that league: its C-R games.
    let fallback: AnyView?

    init(app: AppModel, browse: BrowseModel, embedded: Bool = false, scope: CricketLeagueScope? = nil, fallback: AnyView? = nil) {
        self.app = app
        self.browse = browse
        self.embedded = embedded
        self.scope = scope
        self.fallback = fallback
        self.model = browse.cricketPage
        self.preferences = browse.f1Page
        _hideScores = ObservedObject(wrappedValue: browse.hideScores)
        _appState = ObservedObject(wrappedValue: app)
    }

    private var wide: Bool {
        #if os(tvOS)
        !narrow
        #else
        sizeClass == .regular && !narrow
        #endif
    }

    /// The iPhone: the scoreboard's columns and the actions fit its width.
    private var compact: Bool {
        #if os(tvOS)
        false
        #else
        sizeClass == .compact
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop(unless: embedded)
        #if os(iOS)
        .navigationTitle("Cricket")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .whileVisible { await model.keepFresh(preferences: preferences) }
        .accessibilityIdentifier("cricket.page")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if embedded {
            // A container, so the page's identifier is not copied onto each of its texts (the sport page names it).
            stack(now: now).accessibilityElement(children: .contain)
        } else {
            ScrollView(.vertical) { stack(now: now) }
                .scrollClipDisabled()
                .defaultFocus($focus, .primary)
        }
    }

    @ViewBuilder
    private func stack(now: Date) -> some View {
        let spoilerFree = SportSpoilers.hidden(preference: preferences.hidesSpoilers, answer: nil, page: pageHidesSpoilers)
        // #280: the page's state; `available: false` is "not available right now" (before, it spun for ever).
        let state = model.state(label: "Cricket")
        VStack(alignment: .leading, spacing: CricketMetrics.spacing) {
            if !embedded { header }
            if state.isStale {
                PigStaleNotice(since: state.staleSince, retry: retry, identifier: "cricket.stale")
            }
            if case .loading = state {
                SportLeaguePlaceholder(kind: .cricket)
            } else if let failure = state.failure {
                PigErrorState(failure: failure, retry: retry, identifier: "cricket.error", schedule: model.schedule)
            } else if let scope, let raw = model.page, raw.available {
                scoped(CricketLeagueFilter.apply(CricketPageText.visible(raw, spoilerFree: spoilerFree), scope: scope),
                       scope: scope, now: now, spoilerFree: spoilerFree)
            } else if let raw = model.page, raw.available, raw.lead != nil || !raw.others.isEmpty {
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
            } else {
                nothingOn
            }
            // #280: plain words, never the error's own text.
            if hideScores.notSaved {
                Text(PageWords.notSaved).font(CricketMetrics.detail).foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .padding(wide ? PigSpacing.section : PigSpacing.l)
        #endif
    }

    // MARK: One league (D-43)

    /// The selected league: its lead's scoreboard (innings by column) and days beside its tour, then its other matches; its
    /// C-R games when the page has nothing for it. Never another league's matches (#212).
    @ViewBuilder
    private func scoped(_ page: CricketLeagueFilter.Scoped, scope: CricketLeagueScope, now: Date, spoilerFree: Bool) -> some View {
        let label = SportLabels.label(scope.league, in: scope.labels)
        if let lead = page.lead {
            SportColumns.layout(narrow: !wide, spacing: CricketMetrics.columnGap).callAsFunction {
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    // #211: the whole line (it wraps to a second line rather than cutting the series words).
                    HStack(alignment: .firstTextBaseline, spacing: PigSpacing.m) {
                        Text([lead.label ?? lead.competition ?? label, lead.venue, spoilerFree ? nil : lead.seriesLine]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(CricketMetrics.cardTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cricket.lead.title")
                        pill(lead, now: now).fixedSize()
                    }
                    scoreboard(lead, spoilerFree: spoilerFree)
                    days(lead, now: now)
                    actions(lead, now: now)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if let series = page.series, !series.matches.isEmpty {
                    seriesPanel(series, lead: lead, now: now, spoilerFree: spoilerFree)
                        .sportSideWidth(CricketMetrics.sideWidth, narrow: !wide)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cricket.lead.\(lead.id)")
        }
        if !page.mine.isEmpty { matches(page.lead == nil ? label : "More \(label)", page.mine, now: now) }
        if page.isEmpty {
            if let fallback { fallback } else { nothingOn }
        }
    }

    private func matches(_ title: String, _ list: [CricketOther], now: Date) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            Text(title).font(CricketMetrics.cardTitle).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: CricketMetrics.otherWidth), spacing: PigSpacing.m, alignment: .top)], alignment: .leading, spacing: PigSpacing.m) {
                ForEach(list) { other in otherCard(other, now: now) }
            }
            .tvFocusSection()
        }
    }

    /// The lead's teams with their innings in columns and the open innings' overs (V2-Cricket-1); spoiler-free: the teams.
    private func scoreboard(_ lead: CricketLead, spoilerFree: Bool) -> some View {
        let board = CricketPageText.scoreboard(lead)
        return VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(Array(board.headers.enumerated()), id: \.offset) { _, header in
                    Text(header).font(CricketMetrics.otherDetail.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                        .frame(width: compact ? 62 : 150, alignment: .trailing)
                }
            }
            ForEach(Array(lead.teams.enumerated()), id: \.offset) { index, team in
                let list = index < lead.innings.count ? lead.innings[index] : []
                let batting = !spoilerFree && list.contains(where: \.current) && lead.status == .live
                HStack(spacing: compact ? PigSpacing.s : PigSpacing.m) {
                    SportBadge(name: team.name, logo: team.logo, league: "Cricket", client: browse.client,
                               size: compact ? 28 : CricketMetrics.badge)
                    if isFollowed(team.name) {
                        Image(systemName: "star.fill").foregroundStyle(Color.pigAccentText).accessibilityLabel("Your team")
                    }
                    Text(team.name).font(CricketMetrics.team.weight(batting ? .heavy : .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if !spoilerFree, index < board.rows.count {
                        HStack(spacing: 0) {
                            ForEach(Array(board.rows[index].enumerated()), id: \.offset) { column, text in
                                Text(text ?? "").font(column == board.rows[index].count - 1 ? CricketMetrics.detail : CricketMetrics.score)
                                    .foregroundStyle(column == board.rows[index].count - 1 ? Color.secondary : Color.primary)
                                    .pigFigures().lineLimit(1).frame(width: compact ? 62 : 150, alignment: .trailing)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("cricket.lead.score.\(index)")
                    }
                }
                .padding(.horizontal, PigSpacing.s)
                .frame(minHeight: CricketMetrics.badge + 6)
                .background(isFollowed(team.name) ? Color.pigAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
            }
            Divider().overlay(Color.pigBorder)
            if spoilerFree {
                Label("Scores hidden", systemImage: "eye.slash").font(CricketMetrics.detail)
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

    /// The account's followed cricket names (any of its leagues), exactly as the page spells them.
    private func isFollowed(_ name: String) -> Bool {
        let names = Set(preferences.preferences.teams.filter { scope?.leagues.contains($0.key) ?? ($0.key == "Cricket") }.flatMap(\.value)
            .map { $0.lowercased() })
        return names.contains(name.lowercased())
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: PigSpacing.m) {
            #if os(tvOS)
            Text("Cricket").font(CricketMetrics.title).accessibilityAddTraits(.isHeader)
            #else
            if wide { Text("Cricket").font(CricketMetrics.title).accessibilityAddTraits(.isHeader) }
            #endif
            Spacer(minLength: 0)
            if let team = preferences.preferences.teams["Cricket"]?.first {
                Label("Following \(team)", systemImage: "star.fill").font(CricketMetrics.chip).lineLimit(1)
                    .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
                    .background(Color.pigRaised, in: Capsule())
                    .accessibilityIdentifier("cricket.following")
            }
            Button { Task { await hideScores.set(!preferences.preferences.spoilerFree) } } label: {
                Label(preferences.preferences.spoilerFree ? "Scores hidden" : "Scores shown",
                      systemImage: preferences.preferences.spoilerFree ? "eye.slash" : "eye")
                    .font(CricketMetrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: preferences.preferences.spoilerFree))
            .disabled(!preferences.preferencesKnown || hideScores.saving)
            .accessibilityLabel(preferences.preferences.spoilerFree ? "Scores are hidden" : "Scores are shown")
            .accessibilityHint("Changes it for every device")
            .accessibilityIdentifier("cricket.spoilers")
        }
        .tvFocusSection()
    }

    // MARK: The lead

    @ViewBuilder
    private func leadBlock(_ page: CricketPage, now: Date, spoilerFree: Bool) -> some View {
        if let lead = page.lead {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                HStack(spacing: PigSpacing.m) {
                    Text(CricketPageText.kicker(lead)).font(CricketMetrics.kicker).tracking(2).foregroundStyle(.secondary)
                    pill(lead, now: now)
                }
                Text(CricketPageText.title(lead.teams)).font(CricketMetrics.matchTitle).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("cricket.lead.title")
                Text(CricketPageText.venueLine(lead)).font(CricketMetrics.meta).foregroundStyle(.secondary)
                scores(lead, spoilerFree: spoilerFree).padding(.top, PigSpacing.s)
                days(lead, now: now).padding(.top, PigSpacing.xs)
                actions(lead, now: now).padding(.top, PigSpacing.s)
            }
        } else {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                Text("No match to lead with").font(CricketMetrics.cardTitle)
                Text("Nothing is live or coming up for the teams you follow.").font(CricketMetrics.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func pill(_ lead: CricketLead, now: Date) -> some View {
        let text = CricketPageText.pill(lead, now: now)
        let live = lead.status == .live
        return Text(text).font(CricketMetrics.kicker).tracking(1)
            .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.xs)
            .foregroundStyle(live ? Color.pigOnStatus : lead.status == .done ? Color.secondary : Color.pigAccentText)
            .background {
                if live { Capsule().fill(Color.pigDanger) }
                else if lead.status == .done { Capsule().fill(Color.pigRaised) }
                else { Capsule().strokeBorder(Color.pigAccentText, lineWidth: 2) }
            }
            .accessibilityIdentifier("cricket.lead.pill")
    }

    private func scores(_ lead: CricketLead, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: PigSpacing.xs) {
            ForEach(Array(lead.teams.enumerated()), id: \.offset) { index, team in
                let list = index < lead.innings.count ? lead.innings[index] : []
                let batting = list.contains(where: \.current)
                HStack(spacing: compact ? PigSpacing.s : PigSpacing.m) {
                    SportBadge(name: team.name, logo: team.logo, league: "Cricket", client: browse.client,
                               size: compact ? 28 : CricketMetrics.badge)
                    Text(team.name).font(CricketMetrics.team.weight(batting && !spoilerFree ? .heavy : .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if !spoilerFree {
                        if let note = CricketPageText.battingNote(list, status: lead.status) {
                            Text(note).font(CricketMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let score = CricketPageText.innings(list) {
                            Text(score).font(CricketMetrics.score).pigFigures().lineLimit(1)
                                .accessibilityIdentifier("cricket.lead.score.\(index)")
                        }
                    }
                }
                .frame(minHeight: CricketMetrics.badge)
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(Color.pigBorder)
            if spoilerFree {
                Label("Scores hidden", systemImage: "eye.slash").font(CricketMetrics.detail)
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
                HStack(spacing: PigSpacing.s) {
                    ForEach(lead.days) { day in
                        VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                            Text("Day \(day.number)").font(CricketMetrics.dayLabel).pigFigures()
                            Text(CricketPageText.daySub(day, lead: lead, now: now)).font(CricketMetrics.daySub)
                                .foregroundStyle(day.state == .live ? Color.pigOnStatus : Color.secondary).lineLimit(1)
                        }
                        .foregroundStyle(day.state == .live ? Color.pigOnStatus : Color.pigText)
                        .padding(.horizontal, PigSpacing.m).padding(.vertical, PigSpacing.s)
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
        let layout = !compact ? AnyLayout(HStackLayout(spacing: PigSpacing.m)) : AnyLayout(VStackLayout(alignment: .leading, spacing: PigSpacing.s))
        layout {
            ForEach(Array(offered.enumerated()), id: \.offset) { index, action in
                actionButton(action, lead: lead, event: event, primary: index == 0)
            }
            Text(CricketPageText.channelLine(lead, now: now)).font(CricketMetrics.detail).foregroundStyle(.secondary)
                .lineLimit(1).padding(.leading, compact ? 0 : PigSpacing.s)
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
            case .record: app.record(event)
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
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.name ?? "Series").font(CricketMetrics.cardTitle).lineLimit(1)
                Spacer(minLength: 8)
                if let season = series.season {
                    Text(season.replacingOccurrences(of: "/", with: "–")).font(CricketMetrics.detail).foregroundStyle(.secondary)
                }
            }
            ForEach(series.matches) { match in
                let text = CricketPageText.seriesResult(match, lead: lead, spoilerFree: spoilerFree, now: now)
                HStack(spacing: PigSpacing.m) {
                    VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                        Text(match.label ?? "Match").font(CricketMetrics.detail.weight(.bold)).lineLimit(1)
                        if let when = CricketPageText.span(start: match.start, end: match.end) {
                            Text(when).font(CricketMetrics.otherDetail).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if match.current {
                        Text(text).font(CricketMetrics.otherDetail.weight(.heavy))
                            .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                            .foregroundStyle(lead?.status == .live ? Color.pigOnStatus : Color.pigAccentText)
                            .background {
                                if lead?.status == .live { Capsule().fill(Color.pigDanger) }
                                else { Capsule().strokeBorder(Color.pigAccentText, lineWidth: 2) }
                            }
                    } else {
                        Text(text).font(CricketMetrics.otherDetail.weight(.semibold)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).lineLimit(2)
                    }
                }
                .padding(.vertical, PigSpacing.s).padding(.horizontal, PigSpacing.xs)
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
        VStack(alignment: .leading, spacing: PigSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your other competitions · today and next").font(CricketMetrics.cardTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if wide {
                    Text(competitions(list)).font(CricketMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: CricketMetrics.otherWidth), spacing: PigSpacing.m, alignment: .top)], alignment: .leading, spacing: PigSpacing.m) {
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
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                Text((other.competition ?? "Cricket").uppercased()).font(CricketMetrics.otherDetail.weight(.bold)).tracking(1.2)
                    .foregroundStyle(.secondary).lineLimit(1)
                ForEach(Array(other.teams.enumerated()), id: \.offset) { index, team in
                    HStack(spacing: PigSpacing.s) {
                        Text(team.name).font(CricketMetrics.otherTeam).lineLimit(1)
                        Spacer(minLength: 6)
                        if index < other.scores.count, let score = other.scores[index] {
                            Text(score).font(CricketMetrics.otherScore).pigFigures().lineLimit(1)
                        }
                    }
                }
                if let line = other.line {
                    Text(line).font(CricketMetrics.otherDetail).lineLimit(1)
                }
                HStack(spacing: PigSpacing.s) {
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

    /// #280 (E1): the league's one action, Open the TV Guide (SportLeagueEmpty).
    private var nothingOn: some View {
        SportLeagueEmpty(app: app, title: PageWords.noCricketTitle, text: PageWords.noCricketText, identifier: "cricket.empty")
    }

    /// Asks again (the preferences first, as every refresh).
    private func retry() async { await model.refresh(preferences: preferences) }
}
