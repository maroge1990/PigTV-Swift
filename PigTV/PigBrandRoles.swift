import SwiftUI

// Shared brand roles that are not colours in the catalog (Pig family brand 1.7.0). Colours are roles in
// Assets.xcassets (Color.pigCanvas, .pigBorder, .pigDanger, .pigMediaPanel, ...); BrandRulesTests keeps typed-in colours
// and literal radii out of the views.

/// Corner radii by role (kit §6). Television: compact 10, cards 18, heroes 32; touch: cards 16, heroes 22 (the kit gives
/// no touch compact radius, so it uses the 10 pt control radius). `inner` is the kit's concentric minimum, for a shape
/// nested inside another with no room left to curve.
nonisolated enum PigRadius {
    #if os(tvOS)
    static let compact: CGFloat = 10
    static let card: CGFloat = 18
    static let hero: CGFloat = 32
    #else
    static let compact: CGFloat = 10
    static let card: CGFloat = 16
    static let hero: CGFloat = 22
    #endif
    static let inner: CGFloat = 6
}

/// Spacing by step (maroge1990/PigTV#243): every padding and stack spacing in the views is one of these, so screens built
/// at different times share one rhythm. Six steps on touch; the television's are 1.5 times as large (read from ten feet),
/// rounded. `section`, `empty` and the television safe margins are the few larger distances. BrandRulesTests fails on a
/// literal padding or spacing outside this file.
nonisolated enum PigSpacing {
    #if os(tvOS)
    static let xxs: CGFloat = 3
    static let xs: CGFloat = 6
    static let s: CGFloat = 12
    static let m: CGFloat = 18
    static let l: CGFloat = 24
    static let xl: CGFloat = 36
    /// Between a page's sections.
    static let section: CGFloat = 48
    /// Around an empty or loading state's message.
    static let empty: CGFloat = 80
    #else
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let section: CGFloat = 32
    static let empty: CGFloat = 60
    #endif
    /// The television's title-safe margins (Apple's tvOS layout guide): 90 at the sides, 60 at the top and bottom. Used
    /// by full-screen chrome drawn over video, which has no safe-area layout of its own.
    static let tvSafeSide: CGFloat = 90
    static let tvSafeTop: CGFloat = 60
    /// How far a focus ring is drawn outside its control (`.padding(-PigSpacing.ringOutset)`).
    static let ringOutset: CGFloat = 6
}

/// Type sizes by role (maroge1990/PigTV#243). The television's sizes are the twenty sizes the views used, merged where
/// they were within 2 pt; touch sizes follow the system's text styles. Weight and design stay at the call site:
/// `.font(.system(size: PigType.body, weight: .semibold))`. BrandRulesTests fails on a literal font size outside this file.
nonisolated enum PigType {
    #if os(tvOS)
    static let caption: CGFloat = 17
    /// A small uppercase label over a title (ON NOW, YOUR SPORTS).
    static let kicker: CGFloat = 17
    static let secondary: CGFloat = 20
    static let body: CGFloat = 23
    static let cardTitle: CGFloat = 26
    static let sectionTitle: CGFloat = 32
    /// Large figures and symbols inside a card (a score, a sport's symbol).
    static let display: CGFloat = 40
    static let pageTitle: CGFloat = 46
    /// A banner's title, an empty state's symbol.
    static let hero: CGFloat = 56
    /// Letters inside a small badge (a league's initials in a 22 pt square).
    static let micro: CGFloat = 13
    /// A code read across the room (the pairing code).
    static let jumbo: CGFloat = 72
    #else
    static let caption: CGFloat = 12
    static let kicker: CGFloat = 12
    static let secondary: CGFloat = 15
    static let body: CGFloat = 17
    static let cardTitle: CGFloat = 20
    static let sectionTitle: CGFloat = 24
    static let display: CGFloat = 30
    static let pageTitle: CGFloat = 34
    static let hero: CGFloat = 44
    static let micro: CGFloat = 9
    static let jumbo: CGFloat = 56
    #endif
}

extension Color {
    /// White labels on a status fill (LIVE on `pigDanger`) or a team-colour disc (#190, Apple 104). The kit names no
    /// on-danger role; its white is `media.text` (light `onAccent`), so this is that asset under the name the views mean.
    static let pigOnStatus = Color.pigMediaText

    /// A colour taken from content (a channel logo's tint). Artwork keeps its own colours (kit §4); this is the one
    /// place such a colour is built, so every other colour in the views is a role.
    nonisolated init(artworkRGB rgb: [Double]) {
        self.init(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
}

/// The kit's lockups (kit §3: use the supplied files, never reassemble a pig and wordmark). Each is sized by the width
/// of its pig's ink, so a lockup's pig matches a `PigBrandMark` or the launch pig of the same size exactly.
struct PigLockup: View {
    let kind: BrandLayout.LockupKind
    /// The pig's visible width in points.
    let pigInkWidth: CGFloat
    /// true: the view's layout box is the lockup's ink (the file's clear space, equal on opposite sides, still draws, just
    /// outside the box), so the pig lines up with leading-aligned text like a `PigBrandMark` does.
    var trimmedToInk = false

    var body: some View {
        let geometry = BrandLayout.lockup(kind)
        let scale = pigInkWidth / geometry.pigInk.width
        let clear = trimmedToInk ? CGSize(width: geometry.pigInk.minX * scale, height: geometry.pigInk.minY * scale) : .zero
        Image(kind == .horizontal ? "LockupHorizontal" : "LockupStacked").resizable()
            .frame(width: geometry.canvas.width * scale, height: geometry.canvas.height * scale)
            .padding(.horizontal, -clear.width)
            .padding(.vertical, -clear.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PigTV")
    }

    /// The pig's ink height for a given ink width (the same in every lockup and in mark.svg).
    static func pigInkHeight(forWidth width: CGFloat) -> CGFloat { width * BrandLayout.markInkAspect }
}
