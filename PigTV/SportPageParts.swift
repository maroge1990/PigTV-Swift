import SwiftUI

// D-43 (1 Nov): what every sport page's content under the banner shares: its type sizes, a list card (a title, a note
// and rows), the "hidden while spoiler-free" note, and a followed name's pink tint and star (rows) or pink outline
// (cards). Brand tokens only.

enum SportPageMetrics {
    #if os(tvOS)
    static let cardTitle: Font = .system(size: 25, weight: .heavy)
    static let note: Font = .system(size: 17)
    static let kicker: Font = .system(size: 15, weight: .bold)
    static let rowName: Font = .system(size: 20, weight: .semibold)
    static let rowPos: Font = .system(size: 19, weight: .bold)
    static let rowDetail: Font = .system(size: 17)
    static let tileTitle: Font = .system(size: 22, weight: .bold)
    static let tileDetail: Font = .system(size: 17)
    static let score: Font = .system(size: 22, weight: .heavy)
    static let spacing: CGFloat = 24
    static let gap: CGFloat = 24
    static let radius: CGFloat = 20
    static let row: CGFloat = 34
    static let badge: CGFloat = 28
    static let padding = EdgeInsets(top: 16, leading: 22, bottom: 16, trailing: 22)
    static let tileHeight: CGFloat = 150
    #else
    static let cardTitle: Font = .headline
    static let note: Font = .caption
    static let kicker: Font = .caption2.weight(.bold)
    static let rowName: Font = .subheadline.weight(.semibold)
    static let rowPos: Font = .subheadline.weight(.bold)
    static let rowDetail: Font = .caption
    static let tileTitle: Font = .subheadline.weight(.bold)
    static let tileDetail: Font = .caption
    static let score: Font = .headline.weight(.heavy)
    static let spacing: CGFloat = 18
    static let gap: CGFloat = 16
    static let radius: CGFloat = 16
    static let row: CGFloat = 30
    static let badge: CGFloat = 22
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    static let tileHeight: CGFloat = 120
    #endif
}

/// A titled card of rows. On tvOS the card is one focus stop (pressing it does `action`, if any), so a page whose lists
/// sit below its buttons still scrolls to them.
struct SportListCard<Content: View>: View {
    let title: String
    var note: String? = nil
    var identifier: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(SportPageMetrics.cardTitle).lineLimit(1)
                    Spacer(minLength: 8)
                    if let note { Text(note).font(SportPageMetrics.note).foregroundStyle(.secondary).lineLimit(1) }
                }
                content()
            }
            .padding(SportPageMetrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: SportPageMetrics.radius, style: .continuous))
        }
        .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: SportPageMetrics.radius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "sport.list.\(title)")
    }
}

/// "Results hidden": spoiler-free is on (or the account's choice is not known yet).
struct SportHiddenNote: View {
    let title: String
    let text: String
    var minHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 34, weight: .semibold)).accessibilityHidden(true)
            Text(title).font(SportPageMetrics.cardTitle)
            Text(text).font(SportPageMetrics.note).multilineTextAlignment(.center).frame(maxWidth: 480)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A followed name's row: the pink tint (D-43 point 6).
    func sportFollowedRow(_ followed: Bool) -> some View {
        padding(.horizontal, 8)
            .background(followed ? Color.pigAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityValue(followed ? "Following" : "")
    }

    /// A followed name's card: the pink outline.
    func sportFollowedCard(_ followed: Bool, radius: CGFloat = SportPageMetrics.radius) -> some View {
        overlay {
            if followed {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.pigAccent, lineWidth: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The star before a followed name.
struct SportFollowStar: View {
    let followed: Bool
    var body: some View {
        if followed {
            Image(systemName: "star.fill").font(SportPageMetrics.rowDetail).foregroundStyle(Color.pigAccentText)
                .accessibilityLabel("Following")
        }
    }
}

/// A game or event's Watch and Record through its C-R card (C-R's card actions, #204's record choice), else its own
/// channels as a C-I event.
@MainActor
enum SportCardActions {
    static func select(card: SportsGame?, event: SportEvent?, app: AppModel, presenter: SportPresenter?) {
        if let card { SportGamePress.select(card, app: app, presenter: presenter); return }
        guard let event, let best = event.best else { return }
        if event.isLive(on: best, at: Date()) {
            if let presenter { presenter.play(event) } else { app.playSportEvent(event, origin: SportFrontView.origin) }
        } else {
            presenter?.open(event, .details)
        }
    }

    static func recordEvent(card: SportsGame?, event: SportEvent?) -> SportEvent? {
        if let card, !card.terminal, let cardEvent = SportFrontText.event(card) { return cardEvent }
        return event
    }
}
