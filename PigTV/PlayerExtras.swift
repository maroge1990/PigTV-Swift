import SwiftUI
import AVKit

// What is on now and next for the channel being watched. Shown in the
// expanded programme panel and in the iOS player overlay.
struct NowNextPanel: View {
    @ObservedObject var playback: PlaybackModel
    var logo: String?
    var client: APIClient?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = playback.programme(at: context.date)
            let upcoming = playback.upcoming(after: context.date, limit: 3)
            HStack(alignment: .top, spacing: 28) {
                ChannelArtwork(logo: logo ?? playback.channel.logo, client: client)
                    .frame(width: 160, height: 90)
                VStack(alignment: .leading, spacing: 14) {
                    Text(playback.channel.name).font(.headline).foregroundStyle(.secondary)
                    if let now {
                        Text(now.title).font(.title2.bold()).lineLimit(2)
                        HStack(spacing: 12) {
                            Text("\(now.start.formatted(date: .omitted, time: .shortened)) – \(now.end.formatted(date: .omitted, time: .shortened))")
                            ProgressView(value: min(1, max(0, context.date.timeIntervalSince(now.start) / now.end.timeIntervalSince(now.start))))
                                .tint(.accentColor).frame(maxWidth: 260)
                        }.foregroundStyle(.secondary)
                        if let description = now.description, !description.isEmpty {
                            Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        }
                    } else {
                        Text("No programme information").font(.title2.bold())
                    }
                }
                if !upcoming.isEmpty {
                    Divider().frame(height: 160)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("COMING UP").font(.caption.bold()).foregroundStyle(Color.accentColor)
                        ForEach(upcoming, id: \.startTime) { programme in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(programme.title).font(.callout).lineLimit(1)
                                if programme.startTime == upcoming.first?.startTime,
                                   let description = programme.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }.frame(maxWidth: 560, alignment: .leading)
                }
                Spacer()
            }
            .padding(32)
        }
    }
}

// Channel list for hopping without leaving playback. Rows follow the order
// the guide was showing when playback started; selecting a row switches.
struct QuickGuidePanel: View {
    @ObservedObject var app: AppModel
    var browse: BrowseModel?
    var dismiss: (() -> Void)? = nil
    @FocusState private var focusedChannelID: String?

    private var channels: [Channel] {
        if !app.zapList.isEmpty { return app.zapList }
        return browse.map { model in model.guide.map(model.asChannel) } ?? []
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(channels) { channel in
                            let programmes = browse?.programmes(for: channel) ?? []
                            let now = GuideNavigation.programme(in: programmes, at: context.date)
                            Button {
                                app.switchPlayback(to: channel)
                                dismiss?()
                            } label: {
                                HStack(spacing: 16) {
                                    ChannelArtwork(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client)
                                        .frame(width: 96, height: 54)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(channel.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                        Text(now?.title ?? "No programme information").font(.headline).lineLimit(1)
                                    }
                                    Spacer()
                                    if let now {
                                        ProgressView(value: min(1, max(0, context.date.timeIntervalSince(now.start) / now.end.timeIntervalSince(now.start))))
                                            .tint(.accentColor).frame(width: 120)
                                    }
                                    if channel.id == app.playback?.channel.id {
                                        Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(QuickGuideRowStyle())
                            .focused($focusedChannelID, equals: channel.id)
                            .id(channel.id)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
                .task {
                    if let id = app.playback?.channel.id {
                        proxy.scrollTo(id, anchor: .center)
                        // Let the lazy row mount before assigning remote focus.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        focusedChannelID = id
                    }
                }
            }
        }
    }
}

private struct QuickGuideRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(focused || configuration.isPressed ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
    }
}

#if os(tvOS)
// Lives in AVKit's contentOverlayView and follows native transport visibility;
// programme information requires no additional menu or Info-panel selection.
struct TransportProgrammeSummary: View {
    @ObservedObject var playback: PlaybackModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(playback.channel.name).font(.headline).foregroundStyle(.secondary)
                if let programme = playback.programme(at: context.date) {
                    Text(programme.title).font(.title2.bold()).lineLimit(2)
                    HStack {
                        Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                        ProgressView(value: min(1, max(0, context.date.timeIntervalSince(programme.start) / programme.end.timeIntervalSince(programme.start))))
                            .frame(maxWidth: 250)
                    }
                    if let description = programme.description { Text(description).lineLimit(2).font(.callout) }
                } else { Text("No programme information").font(.title2) }
                if let next = playback.upcoming(after: context.date, limit: 1).first {
                    Text("Next · \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                        .font(.callout).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .foregroundStyle(.white)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.12)) }
                else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct PlayerOverlayView: View {
    let overlay: PlayerOverlay
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.52).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label(overlay == .programmeInfo ? "Now playing" : "Channels", systemImage: overlay == .programmeInfo ? "info.circle" : "list.bullet")
                        .font(.title2.bold())
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") { app.playerOverlay = nil }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Close overlay")
                }
                Divider()
                switch overlay {
                case .programmeInfo:
                    NowNextPanel(playback: playback, logo: app.browse?.logo(for: playback.channel), client: app.browse?.client)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .channels:
                    QuickGuidePanel(app: app, browse: app.browse) { app.playerOverlay = nil }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(36)
            .frame(maxWidth: 1_200, maxHeight: 760, alignment: .topLeading)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 28).fill(Color(white: 0.12)) }
                else { RoundedRectangle(cornerRadius: 28).fill(.ultraThinMaterial) }
            }
            .padding(56)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .onExitCommand { app.playerOverlay = nil }
    }
}

// Retain AVKit's transport, captions, audio and seeking controls. PigTV adds
// its contextual programme/channel panels through the documented custom menu
// path rather than installing remote swipe gestures over the system player.
@MainActor
enum PlayerPanels {
    static func configure(_ controller: AVPlayerViewController, playback: PlaybackModel, app: AppModel) {
        controller.customInfoViewControllers = []
        updateMenu(controller, playback: playback, app: app)
    }

    static func updateMenu(_ controller: AVPlayerViewController, playback: PlaybackModel, app: AppModel) {
        var actions: [UIMenuElement] = [
            UIAction(title: "Programme info", image: UIImage(systemName: "info.circle")) { _ in app.playerOverlay = .programmeInfo },
            UIAction(title: "Channels…", image: UIImage(systemName: "list.bullet")) { _ in app.playerOverlay = .channels },
            UIAction(title: "Next channel", image: UIImage(systemName: "chevron.up")) { _ in app.zap(1) },
            UIAction(title: "Previous channel", image: UIImage(systemName: "chevron.down")) { _ in app.zap(-1) }
        ]
        if let previous = app.previousChannel, previous.id != playback.channel.id {
            actions.append(UIAction(title: "Back to \(previous.name)", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                app.returnToPreviousChannel()
            })
        }
        controller.transportBarCustomMenuItems = [UIMenu(title: "Channel", image: UIImage(systemName: "tv"), children: actions)]
        // Keep these actions in the native player chrome; overlay Back closes
        // only the panel, leaving the player and its controls intact.
        var contextual = [UIAction(title: "Programme info", image: UIImage(systemName: "info.circle")) { _ in
            app.playerOverlay = .programmeInfo
        }]
        // After a pause or rewind, offer a one-press return to the live edge.
        if playback.behindLive {
            contextual.append(UIAction(title: "Go to live", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { _ in
                playback.goToLive()
            })
        }
        controller.contextualActions = contextual
    }
}
#endif
