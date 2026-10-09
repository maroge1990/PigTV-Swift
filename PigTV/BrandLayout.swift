// Hand-maintained: the shared numbers for the launch screen, the splash, the in-app canvas and the identity halo
// (Pig family brand 1.6.0). Tools/render-launch.swift is compiled together with this file to draw the LaunchBrand
// images, and the SwiftUI views read the same values, so the launch screen and the splash's first frame agree.
// Colour and stop values come from Pig-Branding/tokens/pig-radiance.css (the `radiatingLight` tokens).

import CoreGraphics

/// Layout is in units of the square side S (points: 1080 on tvOS, 600 elsewhere, see `BrandSplashView.side`).
nonisolated enum BrandLayout {
    /// One colour stop of a radial gradient: sRGB 0-255 channels, alpha 0-1, position 0-1 along the radius.
    nonisolated struct Stop: Sendable {
        let r: Double, g: Double, b: Double, a: Double, at: Double
        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double, at: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a; self.at = at
        }
        /// The same colour fully transparent (CSS `transparent` interpolates like this, with no grey fringe).
        func clear(at: Double) -> Stop { Stop(r, g, b, 0, at: at) }
    }

    private static let rose = (r: 239.0, g: 122.0, b: 174.0)
    private static let pale = (r: 246.0, g: 183.0, b: 212.0)

    // MARK: Geometry

    /// mark.svg is a 1024 square with the pig optically centred; its ink is 669.5 wide, so the pig is this fraction of the square.
    static let markInkFraction: CGFloat = 669.5 / 1024
    /// The pig's ink height as a fraction of its ink width (590.42 / 669.50).
    static let markInkAspect: CGFloat = 590.42 / 669.50
    /// The pig's visible width as a fraction of S (the old pig was 0.42 S wide, so the splash keeps its size).
    static let pigInkWidth: CGFloat = 0.42
    /// The mark's square frame (side) as a fraction of S: sized by the ink fraction.
    static var markSide: CGFloat { pigInkWidth / markInkFraction }
    /// The halo radius: 1.35 x the pig's visible size, centred on the pig.
    static var haloRadius: CGFloat { 1.35 * pigInkWidth }
    /// The launch image is exactly the halo's bounding square, so nothing is cut off inside it.
    static var launchSide: CGFloat { 2 * haloRadius }
    /// Bloom radii as multiples of the halo radius.
    static let bloomCoreRadius: CGFloat = 0.75
    static let bloomWideRadius: CGFloat = 1.6

    /// wordmark-*.svg: viewBox 363 x 129.
    static let wordmarkAspect: CGFloat = 363.0 / 129.0
    /// The wordmark's width and the distance from the pig's centre to its top edge (fractions of S). It sits below the pig.
    static let wordmarkWidth: CGFloat = 0.26
    static let wordmarkTop: CGFloat = 0.225
    static var wordmarkHeight: CGFloat { wordmarkWidth / wordmarkAspect }

    // MARK: Canvas colours (PigCanvas / LaunchEdge)

    static let canvasLight: (r: Double, g: Double, b: Double) = (251, 248, 250)
    static let canvasDark: (r: Double, g: Double, b: Double) = (21, 17, 26)

    // MARK: Radiance stops

    /// The static halo (launch screen, splash, identity halo): radius `haloRadius`.
    static func halo(dark: Bool) -> [Stop] {
        let s: [Stop] = dark
            ? [Stop(rose.r, rose.g, rose.b, 0.420, at: 0), Stop(pale.r, pale.g, pale.b, 0.128, at: 0.35), Stop(pale.r, pale.g, pale.b, 0.040, at: 0.70)]
            : [Stop(rose.r, rose.g, rose.b, 0.261, at: 0), Stop(pale.r, pale.g, pale.b, 0.800, at: 0.35), Stop(pale.r, pale.g, pale.b, 0.250, at: 0.70)]
        return s + [s[2].clear(at: 1)]
    }

    /// The splash bloom core: radius 0.75 x halo radius.
    static func bloomCore(dark: Bool) -> [Stop] {
        let s: [Stop] = dark
            ? [Stop(rose.r, rose.g, rose.b, 0.460, at: 0), Stop(rose.r, rose.g, rose.b, 0.184, at: 0.50)]
            : [Stop(rose.r, rose.g, rose.b, 0.435, at: 0), Stop(rose.r, rose.g, rose.b, 0.174, at: 0.50)]
        return s + [s[1].clear(at: 1)]
    }

    /// The splash bloom wide wash: radius 1.6 x halo radius.
    static func bloomWide(dark: Bool) -> [Stop] {
        let s: [Stop] = dark
            ? [Stop(pale.r, pale.g, pale.b, 0.180, at: 0), Stop(pale.r, pale.g, pale.b, 0.099, at: 0.45)]
            : [Stop(pale.r, pale.g, pale.b, 0.797, at: 0), Stop(pale.r, pale.g, pale.b, 0.439, at: 0.45)]
        return s + [s[1].clear(at: 1)]
    }

    /// The in-app canvas bloom from the top leading corner. `at` is a fraction of the gradient radius, which is 0.62 of the
    /// canvas diagonal (0.279 of the diagonal is 0.45 of that radius).
    static let cornerBloomRadiusOfDiagonal: CGFloat = 0.62
    static func cornerBloom(dark: Bool) -> [Stop] {
        let (peak, mid) = dark ? (0.130, 0.055) : (0.160, 0.067)
        let s = [Stop(rose.r, rose.g, rose.b, peak, at: 0), Stop(rose.r, rose.g, rose.b, mid, at: 0.279 / 0.62)]
        return s + [s[1].clear(at: 1)]
    }
}
