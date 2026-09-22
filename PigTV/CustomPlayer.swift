#if os(tvOS)
import SwiftUI
import AVFoundation

// PigTV-owned live player (roadmap R07/R08). AVKit's controls are replaced
// by an overlay modelled on the reference IPTV layout, and every Siri Remote
// press is handled here so Up/Down can open the side channel list.
// The only live player on Apple TV; the AVKit fallback was retired in build 13.
//
// Remote map
//   Controls hidden:  Up/Down → channel list · Select → info
//                     Left/Right → rewind/forward 15 s (scrub bar)
//                     Play/Pause → pause/resume (shows info) · Back → guide
//   Scrub bar:        Left/Right → keep seeking · Select → info
//                     Up/Down/Back → hide
//   Info shown:       Left/Right → choose action · Select → run action
//                     Up/Down → hide · Back → hide
//   Channel list:     Up/Down → move · Select → switch · Back → close
// Overlays hide themselves after a few idle seconds.

enum PlayerChrome: Equatable {
    case hidden, info, channels, tracks, scrub
}

private enum PlayerAction: CaseIterable {
    case favourite, record, tracks, channels, live
}

struct CustomPlayerView: View {
    @ObservedObject var playback: PlaybackModel
    @ObservedObject var app: AppModel
    let exit: () -> Void
    @State private var chrome: PlayerChrome = .info
    @State private var action = 0
    @State private var cursor = 0
    @State private var paused = false
    @State private var lastInput = Date()
    @State private var notice: String?
    @State private var favourite = false
    @State private var busy = false
    // Direction of the latest seek, for the scrub bar's ⏪/⏩ indicator.
    @State private var seekForward = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var browse: BrowseModel? { app.browse }
    private var channels: [Channel] {
        if !app.zapList.isEmpty { return app.zapList }
        return browse.map { model in model.guide.map(model.asChannel) } ?? []
    }
    // Channels are reached with Up/Down (the side list), so the action row no
    // longer carries a Channels button. Go to live only appears when behind.
    private var actions: [PlayerAction] {
        PlayerAction.allCases.filter {
            switch $0 {
            case .channels: return false
            case .tracks: return playback.hasTrackChoice
            case .live: return playback.behindLive || paused
            default: return true
            }
        }
    }
    @State private var trackCursor = 0
    private var allTracks: [PlaybackModel.MediaTrack] { playback.audioTracks + playback.subtitleTracks }

    var body: some View {
        // A Button owns the primary (Select) action: on tvOS this fires on the
        // first click, where `.onTapGesture` needed a second press and felt slow.
        Button(action: select) {
            ZStack {
                PlayerLayerView(player: playback.player).ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ZStack {
                        if chrome == .info { infoOverlay(now: context.date) }
                        if chrome == .channels { channelList(now: context.date) }
                        if chrome == .tracks { tracksPanel }
                        if chrome == .scrub { scrubBar(now: context.date) }
                        if let notice {
                            Text(notice).font(.callout.weight(.semibold))
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(panelFill, in: Capsule())
                                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
                        }
                    }
                    .onChange(of: context.date) { _, now in autoHide(now) }
                }
                .animation(.easeInOut(duration: 0.16), value: chrome)
            }
        }
        .buttonStyle(BlankButtonStyle())
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .focused($focused)
        .onAppear {
            focused = true
            favourite = browse?.isFavourite(playback.channel) ?? false
            cursor = channels.firstIndex { $0.id == playback.channel.id } ?? 0
        }
        .task(id: playback.ready) { if playback.ready { await playback.loadTracks() } }
        .onMoveCommand(perform: move)
        .onPlayPauseCommand(perform: togglePause)
        .onExitCommand(perform: back)
    }

    // MARK: Remote

    private func touch() { lastInput = Date() }

    private func move(_ direction: MoveCommandDirection) {
        touch()
        switch (chrome, direction) {
        case (.hidden, .up), (.hidden, .down):
            cursor = channels.firstIndex { $0.id == playback.channel.id } ?? 0
            chrome = .channels
        case (.hidden, .left), (.scrub, .left):
            seek(-15)
        case (.hidden, .right), (.scrub, .right):
            seek(15)
        case (.scrub, _):
            chrome = .hidden
        case (.hidden, _):
            chrome = .info
        case (.info, .left):
            action = max(0, action - 1)
        case (.info, .right):
            action = min(actions.count - 1, action + 1)
        case (.info, _):
            chrome = .hidden
        case (.channels, .up):
            if !channels.isEmpty { cursor = (cursor - 1 + channels.count) % channels.count }
        case (.channels, .down):
            if !channels.isEmpty { cursor = (cursor + 1) % channels.count }
        case (.channels, _):
            break
        case (.tracks, .up):
            if !allTracks.isEmpty { trackCursor = (trackCursor - 1 + allTracks.count) % allTracks.count }
        case (.tracks, .down):
            if !allTracks.isEmpty { trackCursor = (trackCursor + 1) % allTracks.count }
        case (.tracks, _):
            break
        }
    }

    // Seeking gets its own minimal chrome rather than the full info overlay,
    // so it is obvious that Left/Right are rewinding or fast-forwarding (R17).
    private func seek(_ seconds: Double) {
        seekForward = seconds > 0
        playback.skip(seconds)
        chrome = .scrub
    }

    private func select() {
        touch()
        switch chrome {
        case .hidden, .scrub:
            action = 0
            chrome = .info
        case .info:
            guard actions.indices.contains(action) else { return }
            run(actions[action])
        case .channels:
            guard channels.indices.contains(cursor) else { return }
            let target = channels[cursor]
            chrome = .hidden
            // Browsing never resolved media; only this choice switches, via
            // the existing release-before-switch path.
            if target.id != playback.channel.id { app.switchPlayback(to: target) }
        case .tracks:
            // Apply the track but keep the panel open so audio and subtitles
            // can both be set; Back closes it.
            guard allTracks.indices.contains(trackCursor) else { return }
            playback.selectTrack(allTracks[trackCursor].id)
        }
    }

    private func back() {
        touch()
        if chrome == .hidden { exit() } else { chrome = .hidden }
    }

    private func togglePause() {
        touch()
        if playback.player.rate == 0 { playback.player.play(); paused = false }
        else { playback.player.pause(); paused = true }
        chrome = .info
    }

    private func autoHide(_ now: Date) {
        let limit: TimeInterval = chrome == .channels || chrome == .tracks ? 8 : chrome == .scrub ? 4 : 6
        if chrome != .hidden, !paused, now.timeIntervalSince(lastInput) > limit { chrome = .hidden }
        if notice != nil, now.timeIntervalSince(lastInput) > 3 { notice = nil }
    }

    private func run(_ item: PlayerAction) {
        switch item {
        case .channels:
            cursor = channels.firstIndex { $0.id == playback.channel.id } ?? 0
            chrome = .channels
        case .tracks:
            trackCursor = max(0, allTracks.firstIndex { $0.selected } ?? 0)
            chrome = .tracks
        case .live:
            playback.goToLive(); paused = false
            notice = "Back to live"
        case .favourite:
            guard let browse, !busy else { return }
            let value = !favourite
            busy = true
            Task {
                let ok = await browse.setFavourite(playback.channel, value)
                busy = false
                if ok { favourite = value }
                notice = ok ? (value ? "Added to favourites" : "Removed from favourites") : "Couldn't update favourites"
                touch()
            }
        case .record:
            guard let browse, !busy,
                  let channel = browse.guideChannel(id: playback.channel.id),
                  let programme = playback.programme() else {
                notice = "No programme information to record"; return
            }
            if browse.scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime)) {
                notice = "Already scheduled — manage it in Recordings"; return
            }
            busy = true
            Task {
                let ok = await browse.schedule(channel: channel, programme: programme, before: 0, after: 0)
                busy = false
                notice = ok ? "Recording \(programme.title)" : (browse.actionError ?? "Couldn't schedule the recording")
                touch()
            }
        }
    }

    // MARK: Info overlay

    private var panelFill: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color(white: 0.1)) : AnyShapeStyle(Color.black.opacity(0.55))
    }

    private func infoOverlay(now: Date) -> some View {
        let programme = playback.programme(at: now)
        let next = playback.nextProgramme(after: now)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    LogoTile(logo: browse?.logo(for: playback.channel) ?? playback.channel.logo, client: browse?.client,
                             name: playback.channel.name)
                        .frame(width: 180, height: 100)
                    Text(playback.channel.name).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(programme?.title ?? "No programme information")
                        .font(.system(size: 56, weight: .bold)).lineLimit(2)
                    if let programme {
                        Text("\(programme.start.formatted(date: .omitted, time: .shortened)) — \(programme.end.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 26, weight: .medium))
                        if let description = programme.description, !description.isEmpty {
                            Text(description).font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(qualityTags, id: \.self) { tag in
                            Text(tag).font(.system(size: 18, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                Spacer()
                actionRow
            }
            timeline(programme: programme, next: next, now: now).padding(.top, 28)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 90).padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(reduceTransparency ? 0.95 : 0.8)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 620).ignoresSafeArea()
        }
        // Sit against the screen bottom rather than the title-safe inset, which
        // left a visible gap below the overlay.
        .ignoresSafeArea(edges: .bottom)
        .transition(.opacity)
    }

    // Feed resolution, read from the decoded video once playback starts. Empty
    // until the first frame is sized, so nothing tacky is shown speculatively.
    private var qualityTags: [String] {
        let size = playback.player.currentItem?.presentationSize ?? .zero
        let height = max(size.height, 0)
        if height >= 2000 { return ["4K"] }
        if height >= 1400 { return ["1440p"] }
        if height >= 1030 { return ["1080p"] }
        if height >= 700 { return ["720p"] }
        if height >= 560 { return ["576p"] }
        if height > 0 { return ["SD"] }
        return []
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                let selected = index == action
                VStack(spacing: 8) {
                    Image(systemName: icon(item))
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .background(selected ? Color.white : Color.white.opacity(0.18), in: Circle())
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .scaleEffect(selected ? 1.1 : 1)
                    Text(label(item)).font(.system(size: 18, weight: .medium))
                        .opacity(selected ? 1 : 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: action)
    }

    private func icon(_ item: PlayerAction) -> String {
        switch item {
        case .favourite: return favourite ? "heart.fill" : "heart"
        case .record: return "record.circle"
        case .tracks: return "captions.bubble"
        case .channels: return "list.bullet"
        case .live: return "dot.radiowaves.left.and.right"
        }
    }

    private func label(_ item: PlayerAction) -> String {
        switch item {
        case .favourite: return favourite ? "Unfavourite" : "Favourite"
        case .tracks: return "Audio & subtitles"
        case .record: return "Record"
        case .channels: return "Channels"
        case .live: return "Go to live"
        }
    }

    // MARK: Audio & subtitles panel

    private var tracksPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Audio & subtitles").font(.system(size: 34, weight: .bold))
            if !playback.audioTracks.isEmpty {
                trackSection("Audio", tracks: playback.audioTracks)
            }
            if !playback.subtitleTracks.isEmpty {
                trackSection("Subtitles", tracks: playback.subtitleTracks)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 24).fill(panelFill))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 80)
        .transition(.opacity)
    }

    private func trackSection(_ title: String, tracks: [PlaybackModel.MediaTrack]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.accentColor)
            ForEach(tracks) { track in
                let highlighted = allTracks.indices.contains(trackCursor) && allTracks[trackCursor].id == track.id
                HStack(spacing: 16) {
                    Image(systemName: track.selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(track.selected ? Color.accentColor : Color.white.opacity(0.5))
                    Text(track.name).font(.system(size: 24, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(highlighted ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(highlighted ? Color.accentColor : .clear, lineWidth: 3) }
            }
        }
    }

    // Programme bar (about three quarters) plus the next programme's slot,
    // as in the reference layout.
    private func timeline(programme: GuideProgramme?, next: GuideProgramme?, now: Date) -> some View {
        let programmeProgress = programme.map { min(1, max(0, now.timeIntervalSince($0.start) / $0.end.timeIntervalSince($0.start))) } ?? 0
        // At the live edge the bar tracks programme progress; once rewound it
        // becomes a buffer scrubber (pink) with a draggable-looking knob.
        let scrubbing = playback.behindLive
        let progress = scrubbing ? (playback.bufferPosition() ?? programmeProgress) : programmeProgress
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule().fill(scrubbing ? Color.accentColor : Color.white).frame(width: geometry.size.width * progress)
                        if scrubbing {
                            Circle().fill(Color.white).frame(width: 22, height: 22)
                                .offset(x: min(geometry.size.width - 22, max(0, geometry.size.width * progress - 11)))
                        }
                    }
                }.frame(height: 10)
                HStack {
                    Text(programme?.start.formatted(date: .omitted, time: .shortened) ?? "")
                    Spacer()
                    HStack(spacing: 8) {
                        if !paused && !playback.behindLive { Circle().fill(Color.red).frame(width: 12, height: 12) }
                        Text(paused || playback.behindLive ? "BEHIND LIVE" : "LIVE").foregroundStyle(paused || playback.behindLive ? .white : .red)
                        Text(now.formatted(date: .omitted, time: .shortened))
                    }
                }.font(.system(size: 22, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 10)
                Text(next.map { "\($0.start.formatted(date: .omitted, time: .shortened)) · \($0.title)" } ?? "")
                    .font(.system(size: 22, weight: .semibold)).lineLimit(1)
            }
            .frame(width: 420)
        }
    }

    // MARK: Scrub bar (R17)

    // Channel, direction and the buffer position only — nothing that competes
    // with the picture while seeking.
    private func scrubBar(now: Date) -> some View {
        let position = playback.bufferPosition()
        let behind = playback.secondsBehindLive() ?? 0
        let live = behind <= 20
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Image(systemName: seekForward ? "goforward.15" : "gobackward.15")
                    .font(.system(size: 40, weight: .semibold))
                Text(playback.channel.name).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer()
                if live {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                        Text("LIVE").foregroundStyle(.red)
                    }
                } else {
                    Text("\(Self.clock(behind)) behind live")
                }
                Text(now.formatted(date: .omitted, time: .shortened))
            }
            .font(.system(size: 24, weight: .semibold))
            GeometryReader { geometry in
                let fraction = position ?? 1
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * fraction)
                    Circle().fill(Color.white).frame(width: 26, height: 26)
                        .offset(x: min(geometry.size.width - 26, max(0, geometry.size.width * fraction - 13)))
                }
            }.frame(height: 26)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 90).padding(.bottom, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(reduceTransparency ? 0.95 : 0.75)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 260).ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.opacity)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Channel list

    private func channelList(now: Date) -> some View {
        HStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(channel, highlighted: index == cursor, now: now).id(index)
                        }
                    }.padding(.vertical, 340)
                }
                .scrollDisabled(true)
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(cursor, anchor: .center) }
                .onChange(of: cursor) { _, value in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(value, anchor: .center) }
                }
            }
            .frame(width: 640)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.leading, 60)
            .background(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(reduceTransparency ? 0.95 : 0.7), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 900).ignoresSafeArea()
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func channelRow(_ channel: Channel, highlighted: Bool, now: Date) -> some View {
        let programmes = browse?.programmes(for: channel) ?? []
        let current = GuideNavigation.programme(in: programmes, at: now)
        let playing = channel.id == playback.channel.id
        return HStack(spacing: 16) {
            LogoTile(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client, name: channel.name)
                .frame(width: 120, height: 66)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(channel.name).font(.system(size: 20)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    if playing { Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor) }
                }
                Text(current?.title ?? "No programme information").font(.system(size: 24, weight: .semibold)).lineLimit(1)
                if let current {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.accentColor)
                                .frame(width: geometry.size.width * min(1, max(0, now.timeIntervalSince(current.start) / current.end.timeIntervalSince(current.start))))
                        }
                    }.frame(height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(highlighted ? Color.white.opacity(0.22) : Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 3) }
        .scaleEffect(highlighted ? 1.03 : 1, anchor: .leading)
    }
}

// Draws only the label — no tvOS focus container, lift or border — while still
// firing its action on the first Select press.
private struct BlankButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

// Neutral translucent logo tile shared by the player overlays (matches the
// guide's tile treatment, R04).
private struct LogoTile: View {
    let logo: String?
    let client: APIClient?
    let name: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.logoTile(.dark))
            if logo != nil {
                ChannelArtwork(logo: logo, client: client).padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                Text(name).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6).padding(8)
            }
        }
    }
}

// Plain video surface: no AVKit controls, so no competing remote handling.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }
}
#endif
