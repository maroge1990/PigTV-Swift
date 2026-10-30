import SwiftUI
import ImageIO

// C-P (#21): the Formula 1 page, opened from the Sport tab when the server advertises `sportPages`. The approved
// mock-ups ("PigTV Sport mock-ups": Formula 1 · Apple TV, · iPad, · iPhone; DESIGN.md › Sport pages): a header with
// Following and the spoiler-free chip; the race weekend (round, name, circuit card with its map and four stats, every
// session with its status pill and bell); the last race's top ten (a starting grid during a weekend) beside both
// championships' top tens. No section tabs and no season calendar. Spoiler-free hides results, the pole/winner
// labels and the standings. The results carry no points (C-P gives none), so they have no points column.
//
// A session is a C-I event (`F1PageText.event`): Watch, Record, "Watch when it starts" and the channel picker are
// the Sport tab's own, on each channel's airing times (#20). Apple TV and iPad (regular width) share the wide layout
// at their own sizes; iPhone stacks it in one scrolling column (an open question whether it wants pages instead).

private enum F1Metrics {
    #if os(tvOS)
    static let title: Font = .system(size: 46, weight: .heavy)
    static let eyebrow: Font = .system(size: 19, weight: .bold)
    static let heroName: Font = .system(size: 46, weight: .heavy)
    static let heroPlace: Font = .system(size: 22)
    static let headline: Font = .system(size: 27, weight: .bold)
    static let rowTitle: Font = .system(size: 24, weight: .bold)
    static let rowDetail: Font = .system(size: 18)
    static let pill: Font = .system(size: 19, weight: .bold)
    static let cardTitle: Font = .system(size: 26, weight: .bold)
    static let tableName: Font = .system(size: 22, weight: .semibold)
    static let tablePos: Font = .system(size: 21, weight: .bold)
    static let tableDetail: Font = .system(size: 19)
    static let statLabel: Font = .system(size: 16, weight: .semibold)
    static let statValue: Font = .system(size: 21, weight: .bold)
    static let chip: Font = .system(size: 22, weight: .medium)
    static let spacing: CGFloat = 26
    static let columnGap: CGFloat = 44
    static let heroWidth: CGFloat = 640
    static let circuitWidth: CGFloat = 440
    static let topHeight: CGFloat = 340
    static let map = CGSize(width: 380, height: 228)
    static let rowHeight: CGFloat = 33
    static let sessionRow: CGFloat = 64
    static let radius: CGFloat = 24
    static let cardPadding = EdgeInsets(top: 20, leading: 28, bottom: 20, trailing: 28)
    static let bell: CGFloat = 48
    #else
    static let title: Font = .largeTitle.bold()
    static let eyebrow: Font = .caption.bold()
    static let heroName: Font = .title.bold()
    static let heroPlace: Font = .subheadline
    static let headline: Font = .headline
    static let rowTitle: Font = .headline
    static let rowDetail: Font = .subheadline
    static let pill: Font = .caption.bold()
    static let cardTitle: Font = .title3.bold()
    static let tableName: Font = .callout.weight(.semibold)
    static let tablePos: Font = .callout.bold()
    static let tableDetail: Font = .footnote
    static let statLabel: Font = .caption.weight(.semibold)
    static let statValue: Font = .headline
    static let chip: Font = .subheadline
    static let spacing: CGFloat = 20
    static let columnGap: CGFloat = 24
    static let heroWidth: CGFloat = 0
    static let circuitWidth: CGFloat = 330
    static let topHeight: CGFloat = 360
    static let map = CGSize(width: 290, height: 190)
    static let rowHeight: CGFloat = 30
    static let sessionRow: CGFloat = 64
    static let radius: CGFloat = 18
    static let cardPadding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    static let bell: CGFloat = 44
    #endif
}

struct F1PageView: View {
    let app: AppModel
    let browse: BrowseModel
    @ObservedObject var model: F1PageModel
    /// Observed for the bells (a pending "watch when it starts").
    @ObservedObject private var appState: AppModel
    @Environment(\.sportPresenter) private var presenter
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var recording: SportEvent?
    @State private var choosingDriver = false
    /// The page's width: an iPad in portrait gets the single column (the approved iPad mock-up's note).
    @State private var width: CGFloat = 0

    init(app: AppModel, browse: BrowseModel, model: F1PageModel) {
        self.app = app
        self.browse = browse
        self.model = model
        _appState = ObservedObject(wrappedValue: app)
    }

    private var wide: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular && width >= 1150
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .pigPageBackdrop()
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Formula 1")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .whileVisible { await model.keepFresh() }
        .detailCover(item: $recording) { event in
            if let best = event.best {
                RecordSheet(model: browse, channel: browse.recordingRow(event, on: best), programme: event.programme(on: best)) { _ in
                    recording = nil
                }
            }
        }
        .confirmationDialog("Follow a driver", isPresented: $choosingDriver, titleVisibility: .visible) {
            ForEach(model.page.map(F1PageText.drivers) ?? [], id: \.self) { driver in
                Button(driver) { Task { await model.setFollowing(driver) } }
            }
            if model.preferences.f1Following != nil {
                Button("Follow no one") { Task { await model.setFollowing(nil) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The driver you follow is highlighted in the results and standings, on every device.")
        }
        .accessibilityIdentifier("f1.page")
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let spoilerFree = model.preferences.spoilerFree
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: F1Metrics.spacing) {
                header
                if let page = model.page, page.available, let weekend = page.weekend {
                    if wide {
                        HStack(alignment: .top, spacing: F1Metrics.columnGap) {
                            hero(weekend, now: now)
                                .frame(maxWidth: F1Metrics.heroWidth > 0 ? F1Metrics.heroWidth : .infinity, alignment: .leading)
                            circuit(weekend).frame(width: F1Metrics.circuitWidth)
                            sessions(weekend, now: now, spoilerFree: spoilerFree).frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: F1Metrics.topHeight, alignment: .top)
                        // Side by side and the same height (DESIGN.md › Sport pages: symmetric lists).
                        HStack(alignment: .top, spacing: F1Metrics.columnGap + 4) {
                            results(page, spoilerFree: spoilerFree).frame(maxWidth: .infinity, maxHeight: .infinity)
                            standings(page, spoilerFree: spoilerFree).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        hero(weekend, now: now)
                        circuit(weekend)
                        sessions(weekend, now: now, spoilerFree: spoilerFree)
                        results(page, spoilerFree: spoilerFree)
                        standings(page, spoilerFree: spoilerFree)
                    }
                } else if !model.loaded || model.page?.available == false {
                    ProgressView("Loading Formula 1…").frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    unavailable
                }
                if let error = model.saveError {
                    Text(error).font(F1Metrics.rowDetail).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .padding(wide ? 32 : 16)
            #endif
        }
        .scrollClipDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            #if os(tvOS)
            Text("Formula 1").font(F1Metrics.title).accessibilityAddTraits(.isHeader)
            #else
            if wide { Text("Formula 1").font(F1Metrics.title).accessibilityAddTraits(.isHeader) }
            #endif
            Spacer(minLength: 0)
            Button { choosingDriver = true } label: {
                Label(model.preferences.f1Following.map { "Following \($0)" } ?? "Follow a driver", systemImage: "star.fill")
                    .font(F1Metrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: model.preferences.f1Following != nil))
            .disabled(model.page.map(F1PageText.drivers)?.isEmpty ?? true)
            .accessibilityIdentifier("f1.following")
            Button { Task { await model.setSpoilerFree(!model.preferences.spoilerFree) } } label: {
                Label(model.preferences.spoilerFree ? "Spoiler-free on" : "Scores shown",
                      systemImage: model.preferences.spoilerFree ? "eye.slash" : "eye")
                    .font(F1Metrics.chip).lineLimit(1)
            }
            .buttonStyle(GuideFilterStyle(selected: model.preferences.spoilerFree))
            .accessibilityLabel(model.preferences.spoilerFree ? "Spoiler-free is on" : "Scores are shown")
            .accessibilityHint("Changes it for every device")
            .accessibilityIdentifier("f1.spoilers")
        }
        .tvFocusSection()
    }

    // MARK: The weekend

    @ViewBuilder
    private func hero(_ weekend: F1Weekend, now: Date) -> some View {
        let focus = F1PageText.focusSession(weekend, now: now)
        VStack(alignment: .leading, spacing: 10) {
            if let round = F1PageText.roundLine(weekend) {
                Text(round).font(F1Metrics.eyebrow).tracking(2).foregroundStyle(.secondary)
            }
            Text(weekend.name).font(F1Metrics.heroName).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("f1.weekend")
            Text(F1PageText.placeLine(weekend)).font(F1Metrics.heroPlace).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                if let focus, F1PageText.live(focus, now: now) {
                    Circle().fill(Color.pigDanger).frame(width: 14, height: 14).accessibilityHidden(true)
                }
                Text(F1PageText.headline(weekend, now: now)).font(F1Metrics.headline)
                    .monospacedDigit()
            }
            .padding(.top, 14)
            if let focus { actions(F1PageText.event(focus, in: weekend), live: F1PageText.live(focus, now: now), now: now) }
        }
    }

    @ViewBuilder
    private func actions(_ event: SportEvent, live: Bool, now: Date) -> some View {
        if let best = event.best {
            let pending = appState.pendingWatch?.eventID == event.id
            let scheduled = browse.isScheduled(event, on: best)
            HStack(spacing: 14) {
                if live || SportRows.playsChannelNow(event, now: now) {
                    Button(live ? "Watch live" : "Watch", systemImage: "play.fill") {
                        if let presenter { presenter.play(event) } else { app.playSportEvent(event) }
                    }
                        .pigPrimaryButton()
                        .accessibilityLabel("Watch on \(best.name)")
                        .accessibilityIdentifier("f1.watch")
                    if event.channels.count > 1 {
                        Button("Channels") { presenter?.open(event, .channels) }
                            .accessibilityIdentifier("f1.channels")
                    }
                } else if pending {
                    Button("Don't watch at \((appState.pendingWatch?.at ?? event.start).formatted(date: .omitted, time: .shortened))",
                           systemImage: "xmark") { app.cancelPendingWatch() }
                } else {
                    Button("Watch when it starts", systemImage: "bell") { app.watchWhenStarts(event, now: now) }
                        .pigPrimaryButton()
                        .accessibilityIdentifier("f1.watchWhenStarts")
                }
                if !scheduled && event.end(on: best) > now {
                    Button("Record", systemImage: "record.circle") { recording = event }
                        .disabled(browse.mutationBusy)
                        .accessibilityIdentifier("f1.record")
                } else if scheduled {
                    Label("Recording scheduled", systemImage: "record.circle").font(F1Metrics.rowDetail).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.top, 16)
            .tvFocusSection()
            Text("on \(best.name)" + (event.channels.count > 1 ? " · \(event.channels.count - 1) more" : ""))
                .font(F1Metrics.rowDetail).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("Its channel appears here once the guide carries it, a day or two before.")
                .font(F1Metrics.rowDetail).foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private func circuit(_ weekend: F1Weekend) -> some View {
        VStack(spacing: 14) {
            CircuitMap(path: weekend.info?.map, client: browse.client)
                .frame(width: F1Metrics.map.width, height: F1Metrics.map.height)
                .accessibilityLabel("\(weekend.circuit ?? weekend.name) circuit map")
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(F1PageText.stats(weekend.info).enumerated()), id: \.offset) { index, stat in
                    if index > 0 { Spacer(minLength: 14) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.label).font(F1Metrics.statLabel).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Text(stat.value).font(F1Metrics.statValue).lineLimit(1).fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: F1Metrics.radius, style: .continuous))
    }

    private func sessions(_ weekend: F1Weekend, now: Date, spoilerFree: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !wide { Text("Sessions").font(F1Metrics.cardTitle).padding(.bottom, 6) }
            ForEach(weekend.sessions) { session in
                sessionRow(session, weekend: weekend, now: now, spoilerFree: spoilerFree)
                Divider()
            }
        }
        .tvFocusSection()
    }

    private func sessionRow(_ session: F1Session, weekend: F1Weekend, now: Date, spoilerFree: Bool) -> some View {
        let event = F1PageText.event(session, in: weekend)
        let pill = F1PageText.pill(session, in: weekend, now: now, spoilerFree: spoilerFree)
        let pending = appState.pendingWatch?.eventID == event.id
        let canWait = event.best != nil && session.start > now && !pending
        return HStack(spacing: 16) {
            Button {
                if event.best != nil { presenter?.open(event, .details) }
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name).font(F1Metrics.rowTitle)
                        Text(event.best.map { "\(F1PageText.when(session.start)) · \($0.name)" } ?? F1PageText.when(session.start))
                            .font(F1Metrics.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    pillView(pill)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: F1Metrics.sessionRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: 12))
            .disabled(event.best == nil)
            .accessibilityIdentifier("f1.session.\(session.id)")
            Button {
                if pending { app.cancelPendingWatch() } else { app.watchWhenStarts(event, now: now) }
            } label: {
                Image(systemName: pending ? "bell.fill" : "bell")
                    .frame(width: F1Metrics.bell, height: F1Metrics.bell)
            }
            .buttonStyle(PigSurfaceButtonStyle(cornerRadius: 14))
            .disabled(!canWait && !pending)
            .opacity(canWait || pending ? 1 : 0.35)
            .accessibilityLabel(pending ? "Don't watch \(session.name) when it starts" : "Watch \(session.name) when it starts")
            .accessibilityIdentifier("f1.bell.\(session.id)")
        }
        .background(pill == .live ? Color.pigDanger.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func pillView(_ pill: F1PageText.Pill) -> some View {
        switch pill {
        case .live:
            Text("LIVE").font(F1Metrics.pill).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8).background(Color.pigDanger, in: Capsule())
        case .next:
            Text("Next").font(F1Metrics.pill).foregroundStyle(Color.pigAccentText)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(Color.pigAccent, lineWidth: 2))
        case .done(let text):
            Text(text).font(F1Metrics.pill).lineLimit(1)
                .padding(.horizontal, 16).padding(.vertical, 8).background(Color.pigRaised, in: Capsule())
        case .none:
            EmptyView()
        }
    }

    // MARK: Results and standings

    private func results(_ page: F1Page, spoilerFree: Bool) -> some View {
        card(title: page.results?.title ?? "Last race", note: nil) {
            if spoilerFree {
                hidden("Results hidden", "Spoiler-free is on. Finishing orders, grids and points stay hidden until it is turned off.")
            } else if let rows = page.results?.rows, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.pos) { row in
                        tableRow(pos: row.pos, colour: row.teamColor, name: row.driver, detail: row.team, trailing: nil)
                    }
                }
            } else {
                Text("No results yet.").font(F1Metrics.rowDetail).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("f1.results")
    }

    private func standings(_ page: F1Page, spoilerFree: Bool) -> some View {
        card(title: "Championship", note: page.standings.flatMap { F1PageText.standingsNote($0, weekend: page.weekend) }) {
            if spoilerFree {
                hidden("Standings hidden", "Points reveal results, so the championship is hidden too while spoiler-free is on.")
            } else if let standings = page.standings {
                let columns = wide ? [GridItem(.flexible(minimum: 0), spacing: 36, alignment: .top), GridItem(.flexible(minimum: 0), alignment: .top)]
                    : [GridItem(.flexible(minimum: 0), alignment: .top)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    table("DRIVERS", standings.drivers)
                    table("CONSTRUCTORS", standings.constructors)
                }
            } else {
                Text("No standings yet.").font(F1Metrics.rowDetail).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("f1.standings")
    }

    private func table(_ title: String, _ rows: [F1StandingRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(F1Metrics.statLabel).tracking(1.5).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(rows, id: \.pos) { row in
                tableRow(pos: row.pos, colour: row.teamColor, name: row.name, detail: nil, trailing: F1PageText.points(row.points))
            }
        }
    }

    private func tableRow(pos: Int, colour: String?, name: String, detail: String?, trailing: String?) -> some View {
        let followed = name == model.preferences.f1Following
        return HStack(spacing: 14) {
            Text(String(pos)).font(F1Metrics.tablePos).foregroundStyle(.secondary).monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
            RoundedRectangle(cornerRadius: 3).fill(Color(teamHex: colour) ?? .secondary).frame(width: 6, height: 24)
                .accessibilityHidden(true)
            Text(followed ? "★ \(name)" : name).font(F1Metrics.tableName).lineLimit(1)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(F1Metrics.tableDetail).foregroundStyle(.secondary).lineLimit(1) }
            if let trailing, !trailing.isEmpty { Text(trailing).font(F1Metrics.tablePos).monospacedDigit() }
        }
        .frame(height: F1Metrics.rowHeight)
        .padding(.horizontal, 10)
        .background(followed ? Color.pigAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityValue(followed ? "Following" : "")
    }

    private func card<Content: View>(title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(F1Metrics.cardTitle).lineLimit(1)
                Spacer(minLength: 8)
                if let note { Text(note).font(F1Metrics.rowDetail).foregroundStyle(.secondary).lineLimit(1) }
            }
            content()
        }
        .padding(F1Metrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: F1Metrics.radius, style: .continuous))
    }

    private func hidden(_ title: String, _ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.system(size: wide ? 40 : 30, weight: .semibold)).accessibilityHidden(true)
            Text(title).font(F1Metrics.cardTitle)
            Text(text).font(F1Metrics.rowDetail).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: wide ? 300 : 160)
        .accessibilityElement(children: .combine)
    }

    private var unavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "flag.checkered").font(.system(size: 56, weight: .semibold)).foregroundStyle(Color.pigAccentText)
                .accessibilityHidden(true)
            Text("Formula 1 is unavailable right now").font(DetailType.title).multilineTextAlignment(.center)
            Text(model.error ?? "The race data could not be reached. The guide and playback are not affected.")
                .font(DetailType.meta).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load() } }.pigPrimaryButton()
        }
        .padding(.vertical, 70).frame(maxWidth: .infinity)
    }
}

/// The circuit map (a logo-cache path), decoded large enough for the card; nothing while it loads or when absent.
private struct CircuitMap: View {
    let path: String?
    let client: APIClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "flag.checkered").font(.system(size: 44)).foregroundStyle(.tertiary) }
        }
        .task(id: path) {
            guard let path, let data = try? await client.artworkData(path) else { image = nil; return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 900,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}

extension Color {
    /// A team colour as C-P sends it ("00D2BE"); nil when absent or not hex.
    nonisolated init?(teamHex: String?) {
        guard let raw = teamHex?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), raw.count == 6,
              let value = UInt32(raw, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The Sport tab's way in: one card per sport page the server offers (Formula 1 today).
struct SportPageLinks: View {
    let app: AppModel
    let browse: BrowseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sport pages").font(SportMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
            HStack(spacing: SportMetrics.cardSpacing) {
                NavigationLink {
                    F1PageView(app: app, browse: browse, model: browse.f1Page)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "flag.checkered").font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Color.pigAccentText).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Formula 1").font(SportMetrics.title)
                            Text("Race weekend, results, championship").font(SportMetrics.detail).foregroundStyle(.secondary)
                        }
                    }
                    .padding(SportMetrics.cardPadding)
                    .frame(width: SportMetrics.cardWidth, alignment: .leading)
                }
                .buttonStyle(PigSurfaceButtonStyle(cornerRadius: SportMetrics.radius))
                .accessibilityIdentifier("sport.page.f1")
            }
            .padding(.vertical, 24)
        }
        .tvFocusSection()
    }
}
