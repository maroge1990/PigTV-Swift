import SwiftUI

// #264 (Mark, 9 Nov 2026, option B of three side-by-side mock-ups: A the hero scrolls away, B it shrinks to a pinned
// strip, C the full hero stays pinned; C left the rails a third of a television screen): the strip the Sport front page's
// hero becomes once the page scrolls past it. It is drawn over the page's top (#312: on the Apple TV and the iPad the
// page keeps its room as a content margin; the iPhone gives it its own room above the page), and the rails scroll
// beneath it as they do under the TV Guide's header. Apple TV: it is not focusable; up from the
// first rail scrolls back to the full hero, as before. iPad and iPhone: a tap scrolls back to the hero.

enum SportHeroStripMetrics {
    #if os(tvOS)
    static let height: CGFloat = 72
    static var title: Font { .system(size: PigType.cardTitle, weight: .bold) }
    static var detail: Font { .system(size: PigType.body, weight: .semibold) }
    #else
    static let height: CGFloat = 44
    static var title: Font { .subheadline.weight(.bold) }
    static var detail: Font { .footnote }
    #endif
    /// The gap between the strip and the page beneath it.
    static let gap: CGFloat = PigSpacing.s
    /// #312: the room the Apple TV and iPad page keeps at its top for the strip, whether or not it shows.
    static var room: CGFloat { height + gap }
}

struct SportHeroStripView: View {
    let strip: SportHeroStrip
    /// iPad and iPhone: back to the full hero.
    var onTap: (() -> Void)? = nil

    var body: some View {
        // #346: whatever it draws is laid out on whole pixels, and a width offered between two pixels (370.5 pt on a 3x
        // iPhone) was rounded up, so the strip took 370.67: it now takes the whole pixels that fit in the offer.
        StripWidth(scale: displayScale) { button }
    }

    @Environment(\.displayScale) private var displayScale

    @ViewBuilder private var button: some View {
        #if os(tvOS)
        content
        #else
        Button { onTap?() } label: { content }.buttonStyle(.plain)
        #endif
    }

    private var content: some View {
        HStack(spacing: PigSpacing.m) {
            if strip.live {
                // #278: never squeezed out by a long title (the pill was a red bar with no word on the iPhone).
                Text(strip.liveWord).font(SportHeroStripMetrics.detail.weight(.heavy)).foregroundStyle(Color.pigOnAccent)
                    .lineLimit(1).fixedSize().layoutPriority(3)
                    .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xxs)
                    .background(Color.pigDanger, in: Capsule())
            }
            Text(strip.title).font(SportHeroStripMetrics.title).lineLimit(1).layoutPriority(2)
            if !strip.line.isEmpty {
                Text(strip.line).font(SportHeroStripMetrics.detail).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
            Spacer(minLength: PigSpacing.m)
            if let others = strip.others {
                Text(others).font(SportHeroStripMetrics.detail).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, PigSpacing.l)
        // #316: exactly the width it is given. Its row can need a fraction of a point more than that (fixed pill, rounded
        // text widths); the strip then claimed it, the page's column grew by a third of a point and, centred, moved the
        // header above it sideways as the strip appeared (iPhone 17).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: SportHeroStripMetrics.height)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([strip.live ? (strip.liveWord == "ON AIR" ? "On air" : "Live") : nil, strip.title, strip.line, strip.others].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(onTap == nil ? "" : "Back to the top")
        .accessibilityIdentifier("sport.front.strip")
    }
}

/// #346: lays its one child out at the offered width rounded down to whole pixels (pure: `width(offered:scale:)`), so
/// the strip never claims more width than it is given.
struct StripWidth: Layout {
    let scale: CGFloat

    nonisolated static func width(offered: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0, offered.isFinite else { return offered }
        return (offered * scale + 1e-6).rounded(.down) / scale
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { Self.width(offered: $0, scale: scale) }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The page's top edge (#263): the scroll's content ends there, under the header (and the strip, #264), fading over its
/// first few points; sideways and below it may draw `overdraw` past its frame (a focused card grows).
struct SportPageTopMask: View {
    var overdraw: CGFloat = 0
    /// #312: how far down the page's top edge starts (the strip's room while it shows).
    var top: CGFloat = 0
    /// The fade over the page's first points.
    static let fade: CGFloat = PigSpacing.s
    /// #339: the room the content keeps below the fade, so the first row rests fully clear of it and a focused card
    /// (its lift, ring and shadow) never reaches into it: the fade, then a card's growth, the ring and the shadow's edge.
    static let clearance: CGFloat = fade + PigFocusLift.card.maxGrowth + PigFocus.ringWidth + PigSpacing.xs
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
            LinearGradient(colors: [.clear, Color.pigAccent], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
            Rectangle().fill(Color.pigAccent) // a mask reads only alpha: any opaque role
        }
        .padding(.horizontal, -overdraw).padding(.bottom, -overdraw)
    }
}
