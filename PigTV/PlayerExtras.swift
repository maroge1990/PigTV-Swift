#if os(iOS)
import SwiftUI

// Build 29: the iPhone/iPad player's own chrome, matching the TV (Mark, on
// iPad: no "Tuning…", and the old channel sheet). AVKit's touch transport
// controls stay (their scrubbing suits touch); PigTV adds, over them:
// - `PlayerChannelPanel`: the TV's side channel list, as a translucent side
//   panel on iPad (regular width) or a bottom sheet on iPhone, opened from
//   the Channels button; tap a row to switch (switchPlayback, which releases
//   the old stream first).
// - `TouchInfoOverlay`: the TV info overlay's content (channel, programme,
//   times, progress, next) with Favourite, Record and Last channel.

/// The channel list: current channel highlighted and scrolled to.
struct PlayerChannelPanel: View {
    @ObservedObject var app: AppModel
    let close: () -> Void

    var body: some View {
        let current = app.playback?.channel.id
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(app.playerChannels) { channel in
                            let playing = channel.id == current
                            Button {
                                if !playing { app.switchPlayback(to: channel) }
                                close()
                            } label: {
                                PlayerChannelRow(channel: channel, browse: app.browse, highlighted: playing,
                                                 playing: playing, now: context.date)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlayerRowPressStyle())
                            .id(channel.id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// iPad: the panel slides in from the leading edge over the picture (like
/// the TV's), with a header and close button; a tap beside it closes it.
struct PlayerSidePanel: View {
    @ObservedObject var app: AppModel
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.2).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Channels").font(.title2.bold())
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .accessibilityLabel("Close channels")
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                PlayerChannelPanel(app: app, close: close)
            }
            .foregroundStyle(.white)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background {
                if reduceTransparency { Color(white: 0.08).ignoresSafeArea() }
                else {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    }
                    .ignoresSafeArea()
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

private struct PlayerRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The TV info overlay's content for touch: logo, channel (muted number),
/// programme, times and minutes left, progress with LIVE, next, and the
/// actions. Always dark (it sits over video).
struct TouchInfoOverlay: View {
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel
    @ObservedObject var browse: BrowseModel
    /// Any interaction (keeps the chrome up).
    let touch: () -> Void
    @State private var busy = false
    @State private var notice: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let watching = watchedDate(now: context.date)
            let programme = playback.programme(at: watching)
            let next = playback.nextProgramme(after: watching)
            VStack(alignment: .leading, spacing: regular ? 12 : 8) {
                HStack(alignment: .center, spacing: 14) {
                    LogoTile(logo: browse.logo(for: playback.channel) ?? playback.channel.logo, client: browse.client,
                             name: playback.channel.name)
                        .frame(width: regular ? 120 : 84, height: regular ? 66 : 47)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(playback.channel.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                            if let number = playback.channel.numberText {
                                ChannelNumberText(number: number, font: .caption, onDark: true)
                            }
                        }
                        Text(programme?.title ?? "No programme information")
                            .font(regular ? .title2.bold() : .headline).lineLimit(2)
                        if let programme {
                            Text("\(PlayerInfoText.timeRange(programme)) · \(PlayerInfoText.remaining(programme, at: context.date))")
                                .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                }
                if let programme {
                    HStack(spacing: 10) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule().fill(Color.pigAccent)
                                    .frame(width: geometry.size.width * PlayerInfoText.progress(programme, at: watching))
                            }
                        }.frame(height: 5)
                        if !playback.behindLive {
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                                Text("LIVE").font(.caption.bold()).foregroundStyle(.red)
                            }
                        } else {
                            Text("BEHIND LIVE").font(.caption.bold())
                        }
                    }
                }
                if let next = PlayerInfoText.next(next) {
                    Text(next).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                actions
                if let notice {
                    Text(notice).font(.footnote.weight(.semibold)).foregroundStyle(Color.pigAccent)
                        .transition(.opacity)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(regular ? 18 : 14)
        .frame(maxWidth: regular ? 560 : .infinity, alignment: .leading)
        .background(reduceTransparency ? AnyShapeStyle(Color(white: 0.08)) : AnyShapeStyle(Color.black.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            notice = nil
        }
    }

    private var actions: some View {
        let favourite = browse.isFavourite(playback.channel)
        return HStack(spacing: 10) {
            chip(favourite ? "In favourites" : "Favourite", icon: favourite ? "heart.fill" : "heart",
                 label: favourite ? "Remove from favourites" : "Add to favourites") {
                busy = true
                Task {
                    let result = await PlayerCommands.setFavourite(!favourite, channel: playback.channel, browse: browse)
                    busy = false
                    notice = result.notice
                }
            }
            chip("Record", icon: "record.circle", label: "Record this programme") {
                busy = true
                Task {
                    notice = await PlayerCommands.recordNow(playback: playback, browse: browse)
                    busy = false
                }
            }
            if let previous = app.previousChannel, previous.id != playback.channel.id {
                chip("Last channel", icon: "arrow.uturn.backward", label: "Last channel, \(previous.name)") {
                    app.returnToPreviousChannel()
                }
            }
        }
        .disabled(busy)
    }

    private func chip(_ title: String, icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            touch()
            action()
        } label: {
            Label(title, systemImage: icon).font(.footnote.weight(.semibold))
                .labelStyle(regular ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .padding(.horizontal, regular ? 14 : 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// With timeshift, once rewound: the picture's time (as the TV).
    private func watchedDate(now: Date) -> Date {
        guard playback.behindLive, let date = playback.playbackDate(), date < now else { return now }
        return date
    }
}
#endif
