import SwiftUI

/// The model belongs to this authenticated BrowseModel, never to a process-global profile.
struct SportsLandingView: View {
  let app: AppModel
  let browse: BrowseModel
  @StateObject private var dashboard: SportsDashboardModel
  init(app: AppModel, browse: BrowseModel) {
    self.app = app
    self.browse = browse
    _dashboard = StateObject(
      wrappedValue: SportsDashboardModel(
        client: browse.client,
        refreshActivity: { [weak browse] in await browse?.loadRecordingsIfStale(maxAge: 15) }))
  }
  var body: some View {
    if dashboard.enabled && !dashboard.legacy {
      SportsDashboardView(app: app, browse: browse, model: dashboard)
    } else {
      SportView(app: app, browse: browse, sport: browse.sport)
    }
  }
}

struct SportsDashboardView: View {
  let app: AppModel
  let browse: BrowseModel
  @ObservedObject var model: SportsDashboardModel
  @ObservedObject private var actions: ActionState
  init(app: AppModel, browse: BrowseModel, model: SportsDashboardModel) {
    self.app = app
    self.browse = browse
    self.model = model
    _actions = ObservedObject(wrappedValue: browse.actions)
    #if DEBUG
      if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_SCREEN"] == "sport-dashboard" {
        _league = State(initialValue: ProcessInfo.processInfo.environment["PIGTV_UI_TEST_DASHBOARD_LEAGUE"])
      }
    #endif
  }
  @Environment(\.scenePhase) private var scenePhase
  @State private var pageWidth: CGFloat = 360
  @State private var league: String?
  @State private var details: String?
  @State private var settings = false
  @State private var recording: DashboardRecording?
  @State private var waiting: Task<Void, Never>?
  @State private var waitingLabel: String?
  @State private var waitingToken: UUID?
  @State private var afterDetails: (() -> Void)?
  @State private var lastRevision: Int?

  var body: some View {
    page
      .whileVisible { if scenePhase == .active { await model.keepFresh(league: league) } }
      .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
      .onChange(of: model.dashboard?.preferences.revision) { _, revision in
        guard let revision else {
          recording = nil
          return
        }
        if let lastRevision, lastRevision != revision {
          recording = nil
          // A spoiler/delay change does not cancel an approved future watch. Its neutral label
          // carries no result prose, and the airing/preferences are revalidated again on wake.
        }
        lastRevision = revision
      }
      .detailCover(isPresented: $settings) {
        SportsDashboardSettings(model: model)
      }
      .detailCover(item: detailBinding, onDismiss: detailsDismissed) { selection in
        dashboardDetails(selection.id)
      }
      .detailCover(item: $recording) { selection in
        Group {
          if SportsPresentationPolicy.canRender(
            storedRevision: selection.revision, current: model.dashboard?.preferences)
          {
            RecordSheet(
              model: browse, channel: browse.recordingRow(selection.event, on: selection.channel),
              programme: selection.event.programme
            ) { _ in recording = nil }
          } else {
            Text("Event details hidden until your account settings are refreshed.")
          }
        }
        .whileVisible { await model.keepFresh(league: league, clear: false) }
      }
  }
  private var page: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          PigPageHeader(
            title: model.dashboard?.scope == "preview"
              ? "Sport · Illustrative preview"
              : league.map { "\($0) · Next 72 hours" } ?? "Sport · Today")
          VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
              HStack { navigationActions }
              VStack(alignment: .leading, spacing: 12) { navigationActions }
            }
            if let waitingLabel {
              Text(waitingLabel)
              Button("Cancel scheduled watch") {
                waiting?.cancel()
                waiting = nil
                self.waitingLabel = nil
              }
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            if let response = model.dashboard {
              Text(
                "\(response.timezone) · Scores delayed \(response.preferences.scoreDelaySeconds)s\(response.preferences.avoidSpoilers ? " · Spoilers hidden" : "")"
              )
              .font(SportMetrics.detail).foregroundStyle(.secondary)
              ScrollView(.horizontal) {
                HStack {
                  ForEach(
                    response.leagues ?? Array(Set(response.games.map(\.league))).sorted(),
                    id: \.self
                  ) { name in
                    Button(name) { changeLeague(name) }
                  }
                }.padding(.vertical, 12)
              }
              ForEach(
                league.map { [$0] }
                  ?? Array(Set((response.leagues ?? []) + response.games.map(\.league))).sorted(),
                id: \.self
              ) { name in
                SportsDashboardShelf(
                  league: name, games: response.games.filter { $0.league == name },
                  hidden: response.preferences.avoidSpoilers, timezone: response.timezone,
                  browse: browse, availableWidth: max(1, pageWidth - 2 * SportMetrics.pagePadding),
                  select: { game in select(game.id) }, details: { details = $0 })
              }
              if response.games.isEmpty {
                Text("No games or guide listings available for this period.")
              }
            } else {
              Text("Scores hidden until your account settings and delayed data are refreshed.")
              if model.busy {
                ProgressView("Loading sport…")
              } else {
                Button("Try again") { Task { await model.load(league: league, clear: true) } }
              }
            }
          }.padding(.horizontal, SportMetrics.pagePadding).padding(.bottom, 60)
        }
      }.pigPageBackdrop()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }
  }
  @ViewBuilder private var navigationActions: some View {
    Button("Today") { changeLeague(nil) }.accessibilityIdentifier("sportsDashboard.today")
    Button("Spoilers & delay", systemImage: "eye.slash") { settings = true }
      .accessibilityIdentifier("sportsDashboard.settings")
  }
  private var detailBinding: Binding<DashboardIdentity?> {
    Binding(get: { details.map { DashboardIdentity(id: $0) } }, set: { details = $0?.id })
  }
  private func sceneChanged(_ phase: ScenePhase) {
    model.sceneActive(phase == .active)
    waiting?.cancel()
    waiting = nil
    waitingLabel = nil
    recording = nil
    details = nil
    settings = false
    afterDetails = nil
    if phase == .active { Task { await model.load(league: league, clear: true) } }
  }
  private func closeDetails(then action: @escaping () -> Void) {
    afterDetails = action
    details = nil
  }
  private func detailsDismissed() {
    let action = afterDetails
    afterDetails = nil
    action?()
  }
  private func changeLeague(_ value: String?) {
    league = value
    model.hide()
    Task { await model.load(league: value, clear: true) }
  }
  private func select(_ id: String) {
    guard model.dashboard?.games.first(where: { $0.id == id })?.canWatch == true else {
      details = id
      return
    }
    Task {
      guard let event = await model.event(gameID: id, watch: true), app.browse === browse else {
        return
      }
      app.playSportEvent(event)
    }
  }
  @ViewBuilder private func dashboardDetails(_ id: String) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Button("Done") { details = nil }
        if let response = model.dashboard, let game = response.games.first(where: { $0.id == id }) {
          SportsGameContent(
            game: game, hidden: response.preferences.avoidSpoilers, timezone: response.timezone,
            client: browse.client)
          Text(game.availabilityLabel)
          if let message = model.message { Text(message) }
          if let error = actions.actionError { Text(error) }
          if let message = actions.actionMessage { Text(message) }
          if !game.terminal {
            ForEach(game.channels) { channel in
              if game.canWatch {
                Button("Watch \(channel.name)", systemImage: "play.fill") {
                  closeDetails {
                    Task {
                      guard
                        let event = await model.event(
                          gameID: id, channelKey: channel.identityKey, watch: true),
                        app.browse === browse
                      else { return }
                      app.playSportEvent(event)
                    }
                  }
                }
              }
              Button("Record on \(channel.name)", systemImage: "record.circle") {
                closeDetails {
                  Task {
                    guard
                      let event = await model.event(
                        gameID: id, channelKey: channel.identityKey, watch: false),
                      let current = event.best, app.browse === browse
                    else { return }
                    recording = DashboardRecording(
                      event: event, channel: current,
                      revision: model.dashboard?.preferences.revision ?? -1)
                  }
                }
              }
              if game.start > response.now {
                Button("Watch \(channel.name) when it starts", systemImage: "alarm") {
                  closeDetails {
                    waiting?.cancel()
                    waitingLabel = "Waiting for the event on \(channel.name)"
                    let token = UUID()
                    waitingToken = token
                    waiting = Task {
                      do {
                        try await Task.sleep(for: .milliseconds(max(0, game.start - response.now)))
                      } catch { return }
                      defer {
                        if waitingToken == token {
                          waiting = nil
                          waitingLabel = nil
                          waitingToken = nil
                        }
                      }
                      if let event = await model.event(
                        gameID: id, channelKey: channel.identityKey, watch: true),
                        !Task.isCancelled, app.browse === browse
                      {
                        app.playSportEvent(event)
                      }
                    }
                  }
                }
              }
            }
            if browse.rulesAvailable {
              ForEach(RuleChoices.sport(title: game.title, league: game.league), id: \.self) {
                choice in
                Button("Record every game: \(choice)") {
                  Task {
                    guard let event = await model.event(gameID: id, watch: false),
                      app.browse === browse
                    else { return }
                    // Use only the revalidated neutral projection for rule choices too.
                    guard
                      RuleChoices.sport(title: event.title, league: event.league).contains(choice)
                    else { return }
                    _ = await browse.addRule(RuleBody(kind: "sport", match: choice))
                  }
                }.disabled(actions.mutationBusy)
              }
            }
          }
        } else {
          Text("Event data is hidden or no longer available.")
        }
      }.padding(SportsDashboardLayout.detailPadding).frame(maxWidth: 1100, alignment: .leading)
    }.pigPageBackdrop()
      .whileVisible { await model.keepFresh(league: league) }
  }
}
private struct DashboardIdentity: Identifiable { let id: String }
private struct DashboardRecording: Identifiable {
  let event: SportEvent
  let channel: SportEventChannel
  let revision: Int
  var id: String { event.id + channel.identityKey }
}

private struct SportsDashboardShelf: View {
  let league: String
  let games: [SportsGame]
  let hidden: Bool
  let timezone: String
  let browse: BrowseModel
  let select: (SportsGame) -> Void
  let availableWidth: CGFloat
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  let details: (String) -> Void
  @ObservedObject private var marks: ScheduleMarks
  @State private var order: [String] = []
  @FocusState private var focused: String?
  #if os(tvOS)
    @ScaledMetric(relativeTo: .body) private var basicHeight: CGFloat = 320
    @ScaledMetric(relativeTo: .body) private var situationHeight: CGFloat = 372
    @ScaledMetric(relativeTo: .body) private var sessionHeight: CGFloat = 352
    @ScaledMetric(relativeTo: .body) private var guideHeight: CGFloat = 304
    private var cardHeight: CGFloat {
      switch league {
      case "NFL", "MLB": situationHeight
      case "Cricket", "F1": sessionHeight
      case "AFL", "AFLW", "NBA", "EPL", "FA Cup", "UEFA", "Championship": basicHeight
      default: guideHeight
      }
    }
  #else
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 280
  #endif

  init(
    league: String, games: [SportsGame], hidden: Bool, timezone: String, browse: BrowseModel,
    availableWidth: CGFloat,
    select: @escaping (SportsGame) -> Void, details: @escaping (String) -> Void
  ) {
    self.availableWidth = availableWidth
    self.league = league
    self.games = games
    self.hidden = hidden
    self.timezone = timezone
    self.browse = browse
    self.select = select
    self.details = details
    _marks = ObservedObject(wrappedValue: browse.marks)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(league).font(SportMetrics.sectionTitle).accessibilityAddTraits(.isHeader)
      if games.isEmpty && focused == nil {
        Text("No games or guide listings available.").foregroundStyle(.secondary)
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: SportMetrics.cardSpacing) {
          ForEach(order, id: \.self) { id in
            if let game = games.first(where: { $0.id == id }) {
              VStack(alignment: .leading) {
                Button {
                  select(game)
                } label: {
                  VStack(alignment: .leading, spacing: 8) {
                    SportsGameContent(
                      game: game, hidden: hidden, timezone: timezone, client: browse.client,
                      showLeague: false)
                    HStack(spacing: 8) {
                      if game.availability == "matched" && !game.terminal {
                        Label(game.availabilityLabel, systemImage: "tv")
                          .foregroundStyle(.secondary).lineLimit(1)
                      }
                      if game.channels.contains(where: { marks.isRecording($0) }) {
                        Label("Recording", systemImage: "record.circle.fill")
                          .foregroundStyle(.red).fixedSize()
                      }
                    }.font(SportMetrics.detail)
                  }.padding(SportMetrics.cardPadding).frame(
                    width: cardWidth, height: cardHeight, alignment: .topLeading
                  ).clipped()
                }.buttonStyle(HomeCardButtonStyle())
                  #if os(tvOS)
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in details(id) })
                    .focused($focused, equals: id)
                    .accessibilityIdentifier("sportsDashboard.game.\(id)")
                    .accessibilityHint("Hold Select for event, channel and recording options")
                  #else
                    .focused($focused, equals: id)
                    .accessibilityIdentifier("sportsDashboard.game.\(id)")
                    .contextMenu {
                      Button("Event details, channels & recording", systemImage: "ellipsis.circle") { details(id) }
                    }
                  #endif
                #if os(tvOS)
                  Text("Hold Select for options").font(.caption).foregroundStyle(.secondary)
                    .opacity(focused == id ? 1 : 0).accessibilityHidden(true)
                #else
                  Button("More options", systemImage: "ellipsis.circle") { details(id) }
                    .accessibilityLabel("More options for \(game.title)")
                    .accessibilityIdentifier("sportsDashboard.options.\(id)")
                #endif
              }
            } else {
              Button {
              } label: {
                Text("Event no longer available").padding(SportMetrics.cardPadding)
                  .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
              }.buttonStyle(HomeCardButtonStyle()).focused($focused, equals: id)
            }
          }
        }.padding(.vertical, 24)
      }.scrollClipDisabled().tvFocusSection()
    }
    .onAppear { reconcile() }
    .onChange(of: games.map(\.id)) { reconcile() }
    .onChange(of: focused) { reconcile() }
  }
  private var cardWidth: CGFloat {
    #if os(tvOS)
      SportMetrics.cardWidth
    #else
      min(availableWidth, typeSize.isAccessibilitySize ? 480 : sizeClass == .regular ? 360 : 300)
    #endif
  }
  private func reconcile() {
    // Keep existing order through score/status updates and pin an expired focused placeholder.
    let ids = Set(games.map(\.id))
    order = order.filter { ids.contains($0) || $0 == focused }
    order += games.filter { !order.contains($0.id) }.map(\.id)
  }
}

private struct SportsGameContent: View {
  let game: SportsGame
  let hidden: Bool
  let timezone: String
  let client: APIClient
  var showLeague = true
  var body: some View {
    VStack(alignment: .leading, spacing: showLeague ? 12 : 8) {
      HStack {
        Text(showLeague ? "\(game.league.uppercased()) · \(game.statusLabel)" : game.statusLabel)
          .font(SportMetrics.league).foregroundStyle(Color.pigAccentText)
        Spacer(minLength: 8)
        if !showLeague && !game.terminal && game.availability != "matched" {
          Image(
            systemName: game.availability == "unmatched" ? "exclamationmark.circle" : "xmark.circle"
          )
          .foregroundStyle(game.availability == "unmatched" ? Color.yellow : Color.red)
          .accessibilityLabel(game.availabilityLabel)
        }
      }
      if game.competitors.count == 2 && game.family != .motorsport {
        ForEach(Array(game.competitors.enumerated()), id: \.element.id) { index, team in
          HStack(spacing: 12) {
            ChannelLogoTile(
              logo: team.cachedLogo, client: client, name: team.name,
              size: CGSize(width: SportMetrics.logo.height, height: SportMetrics.logo.height))
            Text(team.name).font(SportMetrics.title).lineLimit(2, reservesSpace: true)
              .fixedSize(horizontal: false, vertical: true).frame(
                maxWidth: .infinity, alignment: .leading)
            if let scores = game.visibleScores(hidden: hidden) {
              Text(scores[index]).font(SportMetrics.title).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.7)
            }
          }
        }
      } else {
        Text(!showLeague && hidden && game.dataSource == "guide" ? "Guide event" : game.title).font(
          SportMetrics.title
        ).lineLimit(3)
      }
      if game.family == .motorsport {
        if let session = game.session { Text(session).font(SportMetrics.title).lineLimit(showLeague ? nil : 1) }
        if let circuit = game.circuit, !circuit.name.isEmpty {
          Text(circuit.name).font(SportMetrics.detail).lineLimit(showLeague ? nil : 2)
        }
      }
      if !game.progressLabel().isEmpty && game.status != "scheduled" {
        Text(game.progressLabel()).font(SportMetrics.detail).monospacedDigit()
      } else {
        Text(
          Date(timeIntervalSince1970: game.start / 1000),
          format: Date.FormatStyle(
            date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: timezone) ?? .gmt)
        )
        .font(SportMetrics.detail)
      }
      if let situation = game.situationLabel(hidden: hidden) {
        Text(situation).font(SportMetrics.detail)
      }
      if !note.isEmpty {
        HStack(spacing: 8) {
          if hidden && game.family != .motorsport {
            Image(systemName: "eye.slash").accessibilityHidden(true)
          }
          Text(note)
        }.font(SportMetrics.detail).foregroundStyle(.secondary).lineLimit(2)
      }
    }
  }
  private var note: String {
    var parts: [String] = []
    if hidden && game.family != .motorsport { parts.append("Scores hidden") }
    if game.dataSource == "guide" {
      parts.append(hidden ? "Guide only" : "Guide only · Scores unavailable")
    } else if game.freshness != "fresh" {
      parts.append(game.freshness == "stale" ? "Stale data" : "Buffering")
    }
    return parts.joined(separator: " · ")
  }

}

private struct SportsDashboardSettings: View {
  @ObservedObject var model: SportsDashboardModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SportsPreferences?
  @FocusState private var focused: String?
  private var preferences: SportsPreferences? {
    model.dashboard?.preferences ?? (model.saving ? draft : nil)
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        Button("Done") { dismiss() }
        Text("Sports · Your account").font(SportMetrics.sectionTitle)
        Text("These settings sync to devices paired with this account.")
        if let prefs = preferences {
          Toggle("Avoid spoilers", isOn: Binding(
            get: { prefs.avoidSpoilers },
            set: { value in save(prefs, spoilers: value, delay: prefs.scoreDelaySeconds) }))
          Text("Score delay: \(prefs.scoreDelaySeconds) seconds")
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
            ForEach([0, 30, 60, 90, 120, 180, 300], id: \.self) { delay in
              Button("\(delay)s") { save(prefs, spoilers: prefs.avoidSpoilers, delay: delay) }
                .focused($focused, equals: "delay-\(delay)")
                .accessibilityIdentifier("sportsDashboard.delay.\(delay)")
                .accessibilityLabel("Score delay \(delay) seconds")
                .accessibilityValue(prefs.scoreDelaySeconds == delay ? "Selected" : "")
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            Button("− 10 seconds") { save(prefs, spoilers: prefs.avoidSpoilers, delay: max(0, prefs.scoreDelaySeconds - 10)) }
              .focused($focused, equals: "less")
            Button("+ 10 seconds") { save(prefs, spoilers: prefs.avoidSpoilers, delay: min(300, prefs.scoreDelaySeconds + 10)) }
              .focused($focused, equals: "more")
          }
          // Controls remain mounted/focusable during save; the model refuses repeated writes.
          Text(model.saving ? "Saving settings…" : "0–300 seconds. Game clocks come from the delayed server snapshot.")
            .font(SportMetrics.detail).frame(minHeight: 48, alignment: .topLeading)
        } else {
          Text("Settings hidden until refreshed.")
        }
        if let message = model.message { Text(message) }
      }.padding(SportsDashboardLayout.detailPadding).frame(maxWidth: 1000, alignment: .leading)
    }.pigPageBackdrop()
      .onAppear { draft = model.dashboard?.preferences }
      .onChange(of: model.dashboard?.preferences) { _, prefs in
        if let prefs { draft = prefs }
        else if !model.saving { draft = nil }
      }
      .whileVisible { await model.keepFresh(league: model.league, clear: false) }
  }
  private func save(_ prefs: SportsPreferences, spoilers: Bool, delay: Int) {
    guard !model.saving else { return }
    draft = SportsPreferences(avoidSpoilers: spoilers, scoreDelaySeconds: delay, revision: prefs.revision)
    Task { await model.save(avoidSpoilers: spoilers, delay: delay, revision: prefs.revision) }
  }
}

private enum SportsDashboardLayout {
  static var detailPadding: CGFloat {
    #if os(tvOS)
      48
    #else
      20
    #endif
  }
}
