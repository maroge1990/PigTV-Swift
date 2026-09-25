import SwiftUI

// Build 29: player pieces shared by the tvOS custom player and the iOS/iPadOS
// AVKit player, so iPhone and iPad look like the TV (Mark: the iPad showed no
// "Tuning…" and the old channel sheet). Sizes differ per platform
// (`PlayerMetrics`); behaviour and wording are the same.

enum PlayerMetrics {
    #if os(tvOS)
    static let tuningLogo = CGSize(width: 200, height: 110)
    static let tuningName: CGFloat = 24, tuningTitle: CGFloat = 32, tuningDetail: CGFloat = 18
    static let tuningNext: CGFloat = 16, tuningBar: CGFloat = 360, tuningPadding: CGFloat = 48, tuningWidth: CGFloat = 640
    static let rowLogo = CGSize(width: 120, height: 66)
    static let rowName: CGFloat = 20, rowNumber: CGFloat = 16, rowTitle: CGFloat = 24, rowIcon: CGFloat = 16
    static let rowPadding = CGSize(width: 16, height: 10), rowRadius: CGFloat = 14, rowBar: CGFloat = 4
    #else
    static let tuningLogo = CGSize(width: 150, height: 84)
    static let tuningName: CGFloat = 17, tuningTitle: CGFloat = 22, tuningDetail: CGFloat = 14
    static let tuningNext: CGFloat = 13, tuningBar: CGFloat = 260, tuningPadding: CGFloat = 28, tuningWidth: CGFloat = 440
    static let rowLogo = CGSize(width: 92, height: 52)
    static let rowName: CGFloat = 14, rowNumber: CGFloat = 12, rowTitle: CGFloat = 17, rowIcon: CGFloat = 13
    static let rowPadding = CGSize(width: 12, height: 8), rowRadius: CGFloat = 12, rowBar: CGFloat = 3
    #endif
}

/// Pure text and numbers for the player's overlays (tested in
/// `PlayerSharedTests`).
nonisolated enum PlayerInfoText {
    /// "6:35 am – 9:35 am".
    static func timeRange(_ programme: GuideProgramme) -> String {
        "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
    }

    /// "Next: NRL 360 at 9:35 am", or nil.
    static func next(_ programme: GuideProgramme?) -> String? {
        programme.map { "Next: \($0.title) at \($0.start.formatted(date: .omitted, time: .shortened))" }
    }

    /// Share of the programme elapsed at `now`, 0…1.
    static func progress(_ programme: GuideProgramme, at now: Date) -> Double {
        TimeshiftMath.fraction(of: now, from: programme.start, to: programme.end)
    }

    /// "29 min left" (at least one minute).
    static func remaining(_ programme: GuideProgramme, at now: Date) -> String {
        let minutes = max(1, Int((programme.end.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

// Neutral translucent logo tile shared by the player overlays (matches the
// guide's tile treatment, R04). Moved here from CustomPlayer.swift in build 29
// so the iOS tuning card, channel panel and info overlay use it too.
struct LogoTile: View {
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

// A1.2 (tvOS), build 29 (iOS too): shown centred over black while resolving
// media or reconnecting, so a channel change reads as "tuning to something"
// rather than a blank wait. Built entirely from cached guide data
// (`playback.programme()`/`nextProgramme()`), so there is no network wait.
struct TuningCard: View {
    @ObservedObject var playback: PlaybackModel
    let browse: BrowseModel?
    let message: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let programme = playback.programme(at: context.date)
            let next = playback.nextProgramme(after: context.date)
            VStack(spacing: PlayerMetrics.tuningPadding * 0.375) {
                LogoTile(logo: browse?.logo(for: playback.channel) ?? playback.channel.logo,
                         client: browse?.client, name: playback.channel.name)
                    .frame(width: PlayerMetrics.tuningLogo.width, height: PlayerMetrics.tuningLogo.height)
                Text(playback.channel.name).font(.system(size: PlayerMetrics.tuningName, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(programme?.title ?? "No programme information")
                    .font(.system(size: PlayerMetrics.tuningTitle, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                if let programme {
                    Text(PlayerInfoText.timeRange(programme))
                        .font(.system(size: PlayerMetrics.tuningDetail, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: geometry.size.width * PlayerInfoText.progress(programme, at: context.date))
                        }
                    }.frame(width: PlayerMetrics.tuningBar, height: 6)
                }
                if let next = PlayerInfoText.next(next) {
                    Text(next).font(.system(size: PlayerMetrics.tuningNext)).foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(message).font(.system(size: PlayerMetrics.tuningNext, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(PlayerMetrics.tuningPadding)
        .frame(maxWidth: PlayerMetrics.tuningWidth)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// One row of the player's channel list: logo tile, name (and a muted
/// number), what is on now and its progress. The TV's side list and the
/// iOS channel panel (build 29) both draw it.
struct PlayerChannelRow: View {
    let channel: Channel
    let browse: BrowseModel?
    let highlighted: Bool
    let playing: Bool
    let now: Date

    var body: some View {
        let programmes = browse?.programmes(for: channel) ?? []
        let current = GuideNavigation.programme(in: programmes, at: now)
        HStack(spacing: PlayerMetrics.rowPadding.width) {
            LogoTile(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client, name: channel.name)
                .frame(width: PlayerMetrics.rowLogo.width, height: PlayerMetrics.rowLogo.height)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(channel.name).font(.system(size: PlayerMetrics.rowName)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    if let number = channel.numberText {
                        ChannelNumberText(number: number, font: .system(size: PlayerMetrics.rowNumber, weight: .medium), onDark: true)
                    }
                    if playing {
                        Image(systemName: "play.fill").font(.system(size: PlayerMetrics.rowIcon)).foregroundStyle(Color.pigAccent)
                    }
                }
                Text(current?.title ?? "No programme information")
                    .font(.system(size: PlayerMetrics.rowTitle, weight: .semibold)).lineLimit(1)
                if let current {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.pigAccent)
                                .frame(width: geometry.size.width * PlayerInfoText.progress(current, at: now))
                        }
                    }.frame(height: PlayerMetrics.rowBar)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PlayerMetrics.rowPadding.width).padding(.vertical, PlayerMetrics.rowPadding.height)
        .background(highlighted ? Color.white.opacity(0.22) : Color.black.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: PlayerMetrics.rowRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PlayerMetrics.rowRadius)
                .strokeBorder(highlighted ? Color.pigAccent : .clear, lineWidth: 3)
        }
        #if os(tvOS)
        .scaleEffect(highlighted ? 1.03 : 1, anchor: .leading)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(playing ? .isSelected : [])
    }
}

/// The player's Favourite and Record actions, shared by the TV info overlay's
/// action row and the iOS info overlay. Each returns the notice to show.
@MainActor
enum PlayerCommands {
    static func setFavourite(_ value: Bool, channel: Channel, browse: BrowseModel) async -> (ok: Bool, notice: String) {
        let ok = await browse.setFavourite(channel, value)
        return (ok, ok ? (value ? "Added to favourites" : "Removed from favourites") : "Couldn't update favourites")
    }

    /// Records what is on now on the playing channel (no padding).
    static func recordNow(playback: PlaybackModel, browse: BrowseModel) async -> String {
        guard let channel = browse.guideChannel(id: playback.channel.id), let programme = playback.programme() else {
            return "No programme information to record"
        }
        if browse.scheduledKeys.contains(ScheduledRecording.key(channel: channel.name, start: programme.startTime)) {
            return "Already scheduled — manage it in Recordings"
        }
        let ok = await browse.schedule(channel: channel, programme: programme, before: 0, after: 0)
        return ok ? "Recording \(programme.title)" : (browse.actionError ?? "Couldn't schedule the recording")
    }
}

extension AppModel {
    /// The player's channel list: the guide's row order when playback began
    /// (the zap list), else the whole guide.
    var playerChannels: [Channel] {
        if !zapList.isEmpty { return zapList }
        return browse.map { model in model.guide.map(model.asChannel) } ?? []
    }
}

/// iOS/iPadOS player chrome visibility (build 31: PigTV's controls are the
/// only ones; AVKit's are off). A tap on the picture toggles the controls;
/// they hide after 4 idle seconds unless playback is paused or a panel (the
/// channel list, Go to number) is open. Dragging the scrub bar counts as
/// input, so the controls never hide under the finger.
nonisolated enum PlayerChromeTimer {
    static let idle: TimeInterval = 4

    /// Visibility after a tap on the picture (taps on PigTV's own buttons
    /// never reach it).
    static func afterTap(visible: Bool) -> Bool { !visible }

    static func shouldHide(visible: Bool, lastInput: Date, now: Date, paused: Bool, panelOpen: Bool) -> Bool {
        visible && !paused && !panelOpen && now.timeIntervalSince(lastInput) >= idle
    }
}

/// The seekable (timeshift or live buffer) window in the player item's
/// seconds, for the touch scrub bar (build 31). Pure: position ↔ fraction
/// mapping and the behind-live readout, tested in `PlayerSharedTests`.
nonisolated struct PlayerSeekWindow: Equatable, Sendable {
    var start: Double
    var end: Double
    var current: Double
    /// Within this many seconds of the end reads as live (as on the TV).
    static let liveMargin: Double = 20

    /// Nil when there is nothing meaningful to scrub (under 5 s, or not finite).
    init?(start: Double, end: Double, current: Double) {
        guard start.isFinite, end.isFinite, current.isFinite, end - start > 5 else { return nil }
        self.start = start; self.end = end; self.current = current
    }

    var duration: Double { end - start }
    /// Where the picture is, 0…1 through the window.
    var fraction: Double { Self.clamp((current - start) / duration) }
    func time(at fraction: Double) -> Double { start + Self.clamp(fraction) * duration }
    func behindLive(at fraction: Double) -> Double { max(0, end - time(at: fraction)) }
    func isLive(at fraction: Double) -> Bool { behindLive(at: fraction) <= Self.liveMargin }
    /// The target of a ±seconds skip, clamped to the window.
    func skipTarget(_ seconds: Double) -> Double { min(max(current + seconds, start), end) }

    /// A drag's x position on a track `width` wide → fraction.
    static func fraction(forX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return clamp(x / width)
    }

    /// "LIVE", or "2:15 behind live" / "1 h 05 min behind live".
    func readout(at fraction: Double) -> String {
        isLive(at: fraction) ? "LIVE" : "\(TimeshiftMath.behindText(behindLive(at: fraction))) behind live"
    }

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
