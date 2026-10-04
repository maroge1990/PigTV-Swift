import SwiftUI
import Combine

// The Sport cards (split out of SportView.swift in build 39): what a card shows, from plain values.

/// Everything a card draws that can change, as one value: the event, the
/// minute it is drawn at, and the logo revision. Cards compare it and skip
/// their body when it is unchanged, so a guide page or recordings refresh
/// no longer re-evaluates 200 cards.
nonisolated struct SportCardInput: Equatable, Sendable {
    let event: SportEvent
    let clock: Date
    let logoRevision: Int
}

/// An event card with its behaviour: Select plays (live) or opens the event
/// page (upcoming); long press offers the channel picker and the page. It
/// holds no model it observes and no pages of its own (see `SportPresenter`).
struct SportEventTile: View, Equatable {
    let input: SportCardInput
    /// Read for the logo only; `input.logoRevision` says when it may differ.
    let browse: BrowseModel
    let presenter: SportPresenter?

    nonisolated static func == (lhs: SportEventTile, rhs: SportEventTile) -> Bool { lhs.input == rhs.input }

    var body: some View {
        let event = input.event
        let live = event.isLive(at: input.clock)
        SportEventCard(input: input, logo: event.best.flatMap { browse.logo(for: $0) }, client: browse.client) {
            if live { presenter?.play(event) } else { presenter?.open(event, .details) }
        }
        .contextMenu {
            if event.channels.count > 1 {
                Button("Choose a channel", systemImage: "list.bullet") { presenter?.open(event, .channels) }
            }
            if live {
                Button("Watch on \(event.best?.name ?? "the best channel")", systemImage: "play.fill") { presenter?.play(event) }
            }
            Button("Event details", systemImage: "info.circle") { presenter?.open(event, .details) }
        }
    }
}

/// The card: league, title, time (and progress when live), the best
/// channel's logo and how many more channels show it; LIVE when on now.
struct SportEventCard: View {
    let input: SportCardInput
    let logo: String?
    let client: APIClient?
    let action: () -> Void

    var body: some View {
        let event = input.event
        let clock = input.clock
        let live = event.isLive(at: clock)
        let timing = SportRows.timing(event, now: clock)
        let replay = event.isReplay
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text(event.league.uppercased()).font(SportMetrics.league).tracking(2)
                        .foregroundStyle(Color.pigAccentText).lineLimit(1)
                    Spacer(minLength: 8)
                    // Kept (invisible) on upcoming cards so every title
                    // starts at the same height.
                    // A replay says so instead (build 31).
                    if replay {
                        CardBadge(text: "REPLAY", systemImage: "arrow.counterclockwise", colour: Color(white: 0.4))
                            .accessibilityHidden(true)
                    } else {
                        CardBadge(text: "LIVE", colour: .red).opacity(live ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                Text(event.title).font(SportMetrics.title)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(timing).font(SportMetrics.detail).foregroundStyle(live ? Color.primary : Color.secondary)
                    .monospacedDigit().lineLimit(1)
                // The bar keeps its space on upcoming cards so rows line up.
                PigProgressBar(fraction: SportRows.progress(event, now: clock))
                    .opacity(live ? 1 : 0)
                if let best = event.best {
                    HStack(spacing: 14) {
                        ChannelLogoTile(logo: logo, client: client, name: best.name, size: SportMetrics.logo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(best.name).font(SportMetrics.detail.weight(.semibold)).lineLimit(1)
                            Text(SportRows.moreChannels(event) ?? " ")
                                .font(SportMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(SportMetrics.cardPadding)
            .frame(width: SportMetrics.cardWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel([event.league, event.title, replay ? "replay" : (live ? "live" : nil), timing,
                             event.best.map { "on \($0.name)" }, SportRows.moreChannels(event)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("sport.event.\(event.id)")
    }
}

/// Home's trailing card: switches to the Sport tab.
struct SportSeeAllCard: View {
    let count: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "sportscourt.fill").font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.pigAccentText)
                Text("See all sport").font(SportMetrics.title)
                Text("Every event, by league").font(SportMetrics.detail).foregroundStyle(.secondary)
            }
            .padding(SportMetrics.cardPadding)
            .frame(width: SportMetrics.cardWidth * 0.62)
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(HomeCardButtonStyle())
        .accessibilityLabel("See all sport")
        .accessibilityIdentifier("home.sport.seeAll")
    }
}

/// "UHD" / "HD" / "SD": UHD in pink, the others outlined.
struct QualityBadge: View {
    let quality: SportQuality
    var body: some View {
        Text(quality.rawValue)
            .font(SportMetrics.detail.weight(.bold)).monospaced()
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(quality == .uhd ? Color.white : Color.secondary)
            .background(quality == .uhd ? Color.pigAccent : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(quality == .uhd ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5) }
            .accessibilityLabel(quality == .uhd ? "Ultra HD" : quality == .hd ? "HD" : "Standard definition")
    }
}
