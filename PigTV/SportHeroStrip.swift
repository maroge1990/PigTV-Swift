import SwiftUI

// #264 (Mark, 9 Nov 2026, option B of three side-by-side mock-ups: A the hero scrolls away, B it shrinks to a pinned
// strip, C the full hero stays pinned; C left the rails a third of a television screen): the strip the Sport front page's
// hero becomes once the page scrolls past it. It takes its own room between the header and the page, and the rails
// scroll beneath it as they do under the TV Guide's header. Apple TV: it is not focusable; up from the
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
}

struct SportHeroStripView: View {
    let strip: SportHeroStrip
    /// iPad and iPhone: back to the full hero.
    var onTap: (() -> Void)? = nil

    var body: some View {
        #if os(tvOS)
        content
        #else
        Button { onTap?() } label: { content }.buttonStyle(.plain)
        #endif
    }

    private var content: some View {
        HStack(spacing: PigSpacing.m) {
            if strip.live {
                Text("LIVE").font(SportHeroStripMetrics.detail.weight(.heavy)).foregroundStyle(Color.pigOnAccent)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SportHeroStripMetrics.height)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([strip.live ? "Live" : nil, strip.title, strip.line, strip.others].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(onTap == nil ? "" : "Back to the top")
        .accessibilityIdentifier("sport.front.strip")
    }
}

/// The page's top edge (#263): the scroll's content ends there, under the header (and the strip, #264), fading over its
/// first few points; sideways and below it may draw `overdraw` past its frame (a focused card grows).
struct SportPageTopMask: View {
    var overdraw: CGFloat = 0
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, Color.pigAccent], startPoint: .top, endPoint: .bottom).frame(height: PigSpacing.s)
            Rectangle().fill(Color.pigAccent) // a mask reads only alpha: any opaque role
        }
        .padding(.horizontal, -overdraw).padding(.bottom, -overdraw)
    }
}
