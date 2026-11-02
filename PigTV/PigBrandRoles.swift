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
