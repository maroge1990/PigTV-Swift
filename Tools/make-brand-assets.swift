// Pig family 1.0 asset generator. Soft halo only; rays are not an approved treatment.
// Run from this repository: swiftc -O Tools/make-brand-assets.swift -o /tmp/make-brand-assets
// then /tmp/make-brand-assets. Requires macOS ArialRoundedMTBold; no silent font fallback.
// Reads the cleaned transparent PigLogo master. Measures its alpha-weighted optical centre.
// Writes luminosity-aware launch/splash/wordmark assets, light/dark/tinted iOS icons,
// tvOS parallax layers, Top Shelf art and the shared generated BrandLayout geometry.
// Core colours: paper #FBF8FA, plum #15111A, rose #EF7AAE. Halo is a smooth radial alpha field.
// Wordmarks are rasterised once so consumers need not install or redistribute the authoring font.

import Foundation
import ImageIO
import CoreGraphics
import CoreText
import AppKit
import UniformTypeIdentifiers

// MARK: - Configuration (change a number, rerun)

let repo = FileManager.default.currentDirectoryPath
let assets = "\(repo)/PigTV/Assets.xcassets"
let brandAssets = "\(assets)/App Icon & Top Shelf Image.brandassets"
// Full-size previews go to a temporary folder (the repo keeps small copies in
// docs/evidence/branding); PIGTV_BRAND_EVIDENCE=<dir> writes them elsewhere.
let evidenceDir = ProcessInfo.processInfo.environment["PIGTV_BRAND_EVIDENCE"] ?? NSTemporaryDirectory() + "pigtv-brand-evidence"
try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)


struct C { var r: Double, g: Double, b: Double
    init(_ hex: UInt32) { r = Double((hex >> 16) & 255) / 255; g = Double((hex >> 8) & 255) / 255; b = Double(hex & 255) / 255 } }
let plumStops: [(Double, C)] = [(0, C(0x15111A)), (0.55, C(0x15111A)), (1, C(0x15111A))]
let pink = C(0xEF7AAE)
let wordPink = C(0xEF7AAE)
let glowStops: [(Double, Double)] = [(0, 0.30), (0.22 / 0.42, 0.11), (1, 0)]   // (fraction of glow radius, alpha)
let glowReachOfRadius = 0.42                                                    // glow radius = 0.42 of the plum radius by default

// Pig sizes as a fraction of the canvas.
let tvIconPigHeight = 0.52          // of the layer height (safe for the parallax crop)
let tvIconGlowRadius = 100.0 / 240  // of the layer height (fully transparent 20 px inside the top/bottom at 400x240)
let shelfPigHeight = 0.62           // of the Top Shelf height
let shelfGlowRadius = 0.44          // of the Top Shelf height
let iconPigWidth = 0.64             // of the 1024 icon
let iconGlowRadius = 0.42           // of the icon width
let launchPigWidth = 0.42           // of the launch square S
let launchGlowRadius = 0.42         // of S  (the plum radius is S/2, so the glow reaches 84% of it)
let launchWordCapHeightOfPig = 0.16 // wordmark cap height relative to pig height on the splash
let launchWordGapOfPig = 0.10       // pig bottom-of-bitmap to wordmark cap top, of pig height
let shelfWordWidthOfPig = 0.95      // Top Shelf wordmark ink width relative to the pig width
let shelfWordGapOfPig = 0.12

// MARK: - Maths

/// Monotone cubic Hermite (PCHIP) through the stops, zero slope at both ends: smooth, no overshoot, no kink.
func spline(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
    if x <= xs[0] { return ys[0] }
    if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
    var d = [Double](repeating: 0, count: xs.count - 1)
    for i in 0..<d.count { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
    var m = [Double](repeating: 0, count: xs.count)
    for i in 1..<(xs.count - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : 2 * d[i - 1] * d[i] / (d[i - 1] + d[i]) }
    var i = 0
    while x > xs[i + 1] { i += 1 }
    let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
    let t2 = t * t, t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
}
func plum(_ t: Double) -> C {
    let xs = plumStops.map { $0.0 }
    return C(0).with(spline(xs, plumStops.map { $0.1.r }, t), spline(xs, plumStops.map { $0.1.g }, t), spline(xs, plumStops.map { $0.1.b }, t))
}
extension C { func with(_ r: Double, _ g: Double, _ b: Double) -> C { var c = self; c.r = r; c.g = g; c.b = b; return c } }
func glowAlpha(_ t: Double) -> Double { max(0, spline(glowStops.map { $0.0 }, glowStops.map { $0.1 }, t)) }

/// Deterministic triangular noise in (-1, 1) LSB.
@inline(__always) func tri(_ x: Int, _ y: Int) -> Double {
    func h(_ v: UInt32) -> Double {
        var z = v &* 0x9E3779B1; z ^= z >> 15; z = z &* 0x85EBCA77; z ^= z >> 13; z = z &* 0xC2B2AE3D; z ^= z >> 16
        return Double(z) / 4294967296
    }
    let k = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663)
    return h(k) + h(k ^ 0xA5A5A5A5) - 1
}
@inline(__always) func q(_ v: Double, _ n: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255 + n + 0.5).rounded(.down)))) }

// MARK: - Bitmaps

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)   // top-left origin
    return c
}
/// Straight-alpha RGBA image from a raw buffer.
func image(_ px: [UInt8], _ w: Int, _ h: Int, alpha: Bool) -> CGImage {
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}
func draw(_ img: CGImage, in ctx: CGContext, _ r: CGRect) {
    ctx.saveGState(); ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); ctx.restoreGState()
}
func snapshot(_ ctx: CGContext) -> CGImage { ctx.makeImage()! }
func writePNG(_ img: CGImage, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(path)")
}

struct Scene {
    var w: Int, h: Int
    var centre: CGPoint          // the optical centre: pig centroid, plum and glow centre
    var plumRadius: Double       // radius where the plum reaches its edge colour (flat beyond)
    var glowRadius: Double       // radius where the glow reaches alpha 0
}

/// The plum gradient, optionally with the pink halo blended in (a flat composite), dithered, opaque.
func renderBack(_ s: Scene, withGlow: Bool, light: Bool = false) -> CGImage {
    var px = [UInt8](repeating: 255, count: s.w * s.h * 4)
    for y in 0..<s.h { for x in 0..<s.w {
        let dx = Double(x) + 0.5 - Double(s.centre.x), dy = Double(y) + 0.5 - Double(s.centre.y)
        let d = (dx * dx + dy * dy).squareRoot()
        let b = light ? C(0xFBF8FA) : plum(min(1, d / s.plumRadius))
        var r = b.r, g = b.g, bl = b.b
        if withGlow { let a = glowAlpha(d / s.glowRadius); r += (pink.r - r) * a; g += (pink.g - g) * a; bl += (pink.b - bl) * a }
        let n = tri(x, y), o = (y * s.w + x) * 4
        px[o] = q(r, n); px[o + 1] = q(g, n); px[o + 2] = q(bl, n)
    } }
    return image(px, s.w, s.h, alpha: false)
}
/// The halo alone: constant colour, dithered alpha. `grey` renders the tinted icon's grey halo (peak luminance `grey`).
func renderGlow(_ s: Scene, grey: Double? = nil) -> CGImage {
    var px = [UInt8](repeating: 0, count: s.w * s.h * 4)
    for y in 0..<s.h { for x in 0..<s.w {
        let dx = Double(x) + 0.5 - Double(s.centre.x), dy = Double(y) + 0.5 - Double(s.centre.y)
        let a = glowAlpha((dx * dx + dy * dy).squareRoot() / s.glowRadius)
        let n = tri(x, y), o = (y * s.w + x) * 4
        if let g = grey {   // opaque grey image (black + grey halo): value = g * a / peak
            let v = q(g * a / glowStops[0].1, n); px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
        } else {
            px[o] = UInt8(pink.r * 255 + 0.5); px[o + 1] = UInt8(pink.g * 255 + 0.5); px[o + 2] = UInt8(pink.b * 255 + 0.5)
            px[o + 3] = a <= 0 ? 0 : q(a, n)
        }
    } }
    return image(px, s.w, s.h, alpha: grey == nil)
}

// MARK: - The pig

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("cannot read \(path)") }
    return img
}
let pigImage = loadImage("\(assets)/PigLogo.imageset/PigLogo.png")
let pigW = pigImage.width, pigH = pigImage.height

/// Alpha-weighted centroid of the pig, as a fraction of the bitmap's width and height.
let pigCentroid: (x: Double, y: Double) = {
    let c = CGContext(data: nil, width: pigW, height: pigH, bitsPerComponent: 8, bytesPerRow: pigW * 4, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(pigImage, in: CGRect(x: 0, y: 0, width: pigW, height: pigH))
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    var sa = 0.0, sx = 0.0, sy = 0.0
    for y in 0..<pigH { for x in 0..<pigW {
        let a = Double(d[(y * pigW + x) * 4 + 3]) / 255   // CG rows are stored top-first for a bitmap context
        sa += a; sx += a * (Double(x) + 0.5); sy += a * (Double(y) + 0.5)
    } }
    return (sx / sa / Double(pigW), sy / sa / Double(pigH))
}()
/// Total alpha mass (in bitmap pixels squared) of the pig, for the group centroid.
let pigMass: Double = {
    let c = CGContext(data: nil, width: pigW, height: pigH, bitsPerComponent: 8, bytesPerRow: pigW * 4, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(pigImage, in: CGRect(x: 0, y: 0, width: pigW, height: pigH))
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    var s = 0.0
    for i in 0..<(pigW * pigH) { s += Double(d[i * 4 + 3]) / 255 }
    return s
}()

/// Draws the pig scaled uniformly to `width`, its centroid at `centroidAt`. Optional soft shadow beneath (the pig's own
/// pixels are untouched). `grey` draws the greyscale form used only for the tinted icon.
func drawPig(_ ctx: CGContext, width: Double, centroidAt: CGPoint, shadow: (dy: Double, blur: Double, alpha: Double)? = nil, grey: Bool = false) {
    let s = width / Double(pigW), w = width, h = Double(pigH) * s
    let r = CGRect(x: Double(centroidAt.x) - pigCentroid.x * w, y: Double(centroidAt.y) - pigCentroid.y * h, width: w, height: h)
    ctx.saveGState()
    if let sh = shadow {
        // the context is flipped: a positive dy moves the shadow down on screen
        ctx.setShadow(offset: CGSize(width: 0, height: -sh.dy), blur: sh.blur, color: CGColor(gray: 0, alpha: sh.alpha))
    }
    if grey {
        let g = CGContext(data: nil, width: pigW, height: pigH, bitsPerComponent: 8, bytesPerRow: pigW * 2, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.draw(pigImage, in: CGRect(x: 0, y: 0, width: pigW, height: pigH))
        draw(g.makeImage()!, in: ctx, r)
    } else {
        draw(pigImage, in: ctx, r)
    }
    ctx.restoreGState()
}

// MARK: - The wordmark

struct Wordmark { var image: CGImage; var capHeight: Double; var baselineFromBottom: Double; var mass: Double
    var width: Double { Double(image.width) }; var height: Double { Double(image.height) } }
func makeWordmark(light: Bool = false) -> Wordmark {
    let size: CGFloat = 560
    // Match the approved guide exactly; never silently fall back to another face.
    guard let nativeFont = NSFont(name: "ArialRoundedMTBold", size: size) else {
        fatalError("Arial Rounded MT Bold is required to reproduce the approved wordmark")
    }
    let font = nativeFont as CTFont
    let ink = light ? C(0x1C1620) : C(0xF5F1F4)
    let accent = light ? C(0xD6336C) : wordPink
    let text = NSMutableAttributedString(string: "Pig", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: ink.r, green: ink.g, blue: ink.b, alpha: 1)])
    text.append(NSAttributedString(string: "TV", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1)]))
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let w = Int(ceil(bounds.width)) + 2, h = Int(ceil(bounds.height)) + 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true); ctx.setAllowsFontSmoothing(false)
    ctx.textPosition = CGPoint(x: -bounds.minX + 1, y: -bounds.minY + 1)   // y-up context: the baseline sits `-minY` above the bottom
    CTLineDraw(line, ctx)
    let img = ctx.makeImage()!
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var mass = 0.0
    for i in 0..<(w * h) { mass += Double(d[i * 4 + 3]) / 255 }
    return Wordmark(image: img, capHeight: Double(CTFontGetCapHeight(font)), baselineFromBottom: Double(-bounds.minY + 1), mass: mass)
}
let wordmark = makeWordmark()

// MARK: - Layout helpers

/// A pig placed with its centroid at `c` and a wordmark beside it: returns the rects (pig bitmap rect, wordmark rect).
struct ShelfLayout { var pigWidth: Double; var pigCentroid: CGPoint; var wordRect: CGRect }
func shelfLayout(w: Int, h: Int) -> ShelfLayout {
    let pw = Double(h) * shelfPigHeight * Double(pigW) / Double(pigH)
    let ph = pw * Double(pigH) / Double(pigW)
    let ww = pw * shelfWordWidthOfPig, ws = ww / wordmark.width, wh = wordmark.height * ws
    let gap = pw * shelfWordGapOfPig
    let groupW = pw + gap + ww
    let left = (Double(w) - groupW) / 2
    let cy = Double(h) / 2
    _ = ph
    let centroid = CGPoint(x: left + pigCentroid.x * pw, y: cy)
    // Wordmark: its cap-height band (baseline to cap top) centred on the pig's centroid row.
    let baselineY = cy + wordmark.capHeight * ws / 2
    let top = baselineY - (wh - wordmark.baselineFromBottom * ws)
    return ShelfLayout(pigWidth: pw, pigCentroid: centroid, wordRect: CGRect(x: left + pw + gap, y: top, width: ww, height: wh))
}

/// Splash: pig above, wordmark below, in units of the pig's width `pw` with the pig's centroid at y=0. Returns
/// (wordRect relative to the pig centroid, and the upward shift that centres the ink-mass centroid of the group).
struct StackLayout { var pigWidth: Double; var wordRect: CGRect; var shift: Double }
func stackedGroupOffset(pigWidth pw: Double) -> StackLayout {
    let s = pw / Double(pigW), ph = Double(pigH) * s
    let capH = ph * launchWordCapHeightOfPig
    let ws = capH / wordmark.capHeight, ww = wordmark.width * ws, wh = wordmark.height * ws
    let pigBottom = (1 - pigCentroid.y) * ph                      // below the centroid
    let capTop = pigBottom + ph * launchWordGapOfPig
    let baseline = capTop + capH
    let top = baseline - (wh - wordmark.baselineFromBottom * ws)
    let rect = CGRect(x: -ww / 2, y: top, width: ww, height: wh)
    // ink-mass centroids (y, relative to the pig centroid): the pig is at 0; the wordmark's is its own centroid ~ its band centre
    let mp = pigMass * s * s, mw = wordmark.mass * ws * ws
    let wordY = capTop + capH / 2
    let cg = (mp * 0 + mw * wordY) / (mp + mw)
    return StackLayout(pigWidth: pw, wordRect: rect, shift: cg)
}

func f(_ v: Double) -> String { String(format: "%.5f", v) }

// MARK: - Output helpers

func compose(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage { let c = makeContext(w, h); body(c); return snapshot(c) }
func opaque(_ img: CGImage) -> CGImage {   // flatten to an opaque RGB PNG (CG would otherwise keep an alpha channel)
    let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); return c.makeImage()!
}
func contentsJSON(_ images: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)! + "\n"
}
func write(_ text: String, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}
let plainInfo = "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"

// MARK: - 1 + 2: tvOS icon layers

struct Layers { var back: CGImage; var middle: CGImage; var front: CGImage }
func iconLayers(w: Int, h: Int) -> Layers {
    let k = Double(w) / 400
    let scene = Scene(w: w, h: h, centre: CGPoint(x: Double(w) / 2, y: Double(h) / 2),
                      plumRadius: (Double(w * w + h * h)).squareRoot() / 2, glowRadius: tvIconGlowRadius * Double(h))
    let front = compose(w, h) { c in
        drawPig(c, width: Double(h) * tvIconPigHeight * Double(pigW) / Double(pigH), centroidAt: scene.centre,
                shadow: (8 * k, 10 * k, 0.35))
    }
    return Layers(back: renderBack(scene, withGlow: false), middle: renderGlow(scene), front: front)
}
func flatten(_ l: Layers, shift: (Double, Double) = (0, 0), scale: (Double, Double, Double) = (1, 1, 1)) -> CGImage {
    let w = l.back.width, h = l.back.height
    return compose(w, h) { c in
        // back (scale.0, no shift), middle (half the front's shift), front (full shift): a plain model of the focus parallax
        for (img, s, f) in [(l.back, scale.0, 0.0), (l.middle, scale.1, 0.5), (l.front, scale.2, 1.0)] {
            let rw = Double(w) * s, rh = Double(h) * s
            draw(img, in: c, CGRect(x: (Double(w) - rw) / 2 + shift.0 * f, y: (Double(h) - rh) / 2 + shift.1 * f, width: rw, height: rh))
        }
    }
}
func writeStack(named stack: String, sizes: [(w: Int, h: Int, scale: String)], layers: [(String, KeyPath<Layers, CGImage>, String)]) {
    let root = "\(brandAssets)/\(stack).imagestack"
    write("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  },\n  \"layers\" : [\n    { \"filename\" : \"Front.imagestacklayer\" },\n    { \"filename\" : \"Middle.imagestacklayer\" },\n    { \"filename\" : \"Back.imagestacklayer\" }\n  ]\n}\n", "\(root)/Contents.json")
    for (name, kp, prefix) in layers {
        let dir = "\(root)/\(name).imagestacklayer"
        write(plainInfo, "\(dir)/Contents.json")
        var entries: [[String: Any]] = []
        for size in sizes {
            let l = iconLayers(w: size.w, h: size.h)
            let img = l[keyPath: kp]
            writePNG(kp == \Layers.back ? opaque(img) : img, "\(dir)/Content.imageset/\(prefix)@\(size.scale).png")
            entries.append(["filename": "\(prefix)@\(size.scale).png", "idiom": "tv", "scale": size.scale])
        }
        write(contentsJSON(entries), "\(dir)/Content.imageset/Contents.json")
    }
}
let layerSpec: [(String, KeyPath<Layers, CGImage>, String)] = [("Front", \.front, "front"), ("Middle", \.middle, "middle"), ("Back", \.back, "back")]
writeStack(named: "App Icon", sizes: [(400, 240, "1x"), (800, 480, "2x")], layers: layerSpec)
writeStack(named: "App Icon - App Store", sizes: [(1280, 768, "1x")], layers: layerSpec)

// evidence: the icon at rest and with a sample parallax offset (front +14,+9 px at 800x480, 1.06x; middle half, 1.03x)
let iconL = iconLayers(w: 800, h: 480)
writePNG(opaque(flatten(iconL)), "\(evidenceDir)/tv-icon-at-rest.png")
writePNG(opaque(flatten(iconL, shift: (14, 9), scale: (1.0, 1.03, 1.06))), "\(evidenceDir)/tv-icon-parallax.png")
writePNG(opaque(flatten(iconL, shift: (-14, -9), scale: (1.0, 1.03, 1.06))), "\(evidenceDir)/tv-icon-parallax-opposite.png")
for (name, img) in [("tv-icon-layer-back", iconL.back), ("tv-icon-layer-middle", iconL.middle), ("tv-icon-layer-front", iconL.front)] {
    // layers shown over a mid grey checker-free backdrop so transparency is visible
    writePNG(opaque(compose(800, 480) { c in c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 800, height: 480)); draw(img, in: c, CGRect(x: 0, y: 0, width: 800, height: 480)) }), "\(evidenceDir)/\(name).png")
}

// MARK: - 3: Top Shelf

func shelf(w: Int, h: Int) -> CGImage {
    let lay = shelfLayout(w: w, h: h)
    let R = Double(w * w + h * h).squareRoot()   // conservative: plum radius from the pig centroid to the far corner
    let far = max(hypot(Double(lay.pigCentroid.x), Double(lay.pigCentroid.y)), hypot(Double(w) - Double(lay.pigCentroid.x), Double(lay.pigCentroid.y)),
                  hypot(Double(lay.pigCentroid.x), Double(h) - Double(lay.pigCentroid.y)), hypot(Double(w) - Double(lay.pigCentroid.x), Double(h) - Double(lay.pigCentroid.y)))
    _ = R
    let scene = Scene(w: w, h: h, centre: lay.pigCentroid, plumRadius: far, glowRadius: shelfGlowRadius * Double(h))
    let back = renderBack(scene, withGlow: true)
    return opaque(compose(w, h) { c in
        draw(back, in: c, CGRect(x: 0, y: 0, width: w, height: h))
        drawPig(c, width: lay.pigWidth, centroidAt: lay.pigCentroid, shadow: (8 * Double(h) / 240 * 0.6, 10 * Double(h) / 240 * 0.6, 0.35))
        draw(wordmark.image, in: c, lay.wordRect)
    })
}
for (name, w, h) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    let dir = "\(brandAssets)/\(name).imageset"
    writePNG(shelf(w: w, h: h), "\(dir)/shelf@1x.png")
    writePNG(shelf(w: w * 2, h: h * 2), "\(dir)/shelf@2x.png")
    writePNG(shelf(w: w, h: h), "\(evidenceDir)/top-shelf-\(w)x\(h).png")
}

// MARK: - 4: iPhone / iPad icon

func iosIcon(tinted: Bool, light: Bool = false) -> CGImage {
    let n = 1024
    let scene = Scene(w: n, h: n, centre: CGPoint(x: n / 2, y: n / 2), plumRadius: Double(n) * 2.0.squareRoot() / 2, glowRadius: iconGlowRadius * Double(n))
    let base = tinted ? renderGlow(scene, grey: 0.30) : renderBack(scene, withGlow: false, light: light)
    return opaque(compose(n, n) { c in
        if tinted { c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: n)) }
        draw(base, in: c, CGRect(x: 0, y: 0, width: n, height: n))
        drawPig(c, width: Double(n) * iconPigWidth, centroidAt: scene.centre, shadow: nil, grey: tinted)
    })
}
let iosLight = iosIcon(tinted: false, light: true), iosDark = iosIcon(tinted: false), iosTinted = iosIcon(tinted: true)
writePNG(iosLight, "\(assets)/AppIcon.appiconset/icon-light.png")
writePNG(iosDark, "\(assets)/AppIcon.appiconset/icon-dark.png")   // the design is dark already
writePNG(iosTinted, "\(assets)/AppIcon.appiconset/icon-tinted.png")
writePNG(iosLight, "\(evidenceDir)/ios-icon-light.png"); writePNG(iosDark, "\(evidenceDir)/ios-icon-dark.png"); writePNG(iosTinted, "\(evidenceDir)/ios-icon-tinted.png")
// the same three at home-screen size with the corner mask, side by side
writePNG(opaque(compose(3 * 360 + 4 * 40, 440) { c in
    c.setFillColor(CGColor(gray: 0.12, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 2000, height: 600))
    for (i, img) in [iosLight, iosDark, iosTinted].enumerated() {
        let r = CGRect(x: 40 + i * 400, y: 40, width: 360, height: 360)
        c.saveGState(); c.addPath(CGPath(roundedRect: r, cornerWidth: 80, cornerHeight: 80, transform: nil)); c.clip(); draw(img, in: c, r); c.restoreGState()
    }
}), "\(evidenceDir)/ios-icon-light-dark-tinted.png")

// MARK: - 5 + 6: launch screen and splash images

/// The launch square: side S points, drawn at `pixelScale` pixels per point. The pig is centred by its centroid; no wordmark.
func launchScene(side: Int) -> Scene {
    Scene(w: side, h: side, centre: CGPoint(x: Double(side) / 2, y: Double(side) / 2), plumRadius: Double(side) / 2, glowRadius: launchGlowRadius * Double(side))
}
func launchComposite(side: Int, light: Bool = false) -> CGImage {
    let s = launchScene(side: side)
    let back = renderBack(s, withGlow: true, light: light)
    return opaque(compose(side, side) { c in
        draw(back, in: c, CGRect(x: 0, y: 0, width: side, height: side))
        drawPig(c, width: Double(side) * launchPigWidth, centroidAt: s.centre)
    })
}
func imageset(_ name: String, _ files: [(String, String?, String)]) {   // (filename, idiom, scale)
    let dir = "\(assets)/\(name).imageset"
    for f in FileManager.default.enumerator(atPath: dir).map({ $0.allObjects as! [String] }) ?? [] where f.hasSuffix(".png") { try? FileManager.default.removeItem(atPath: "\(dir)/\(f)") }
    write(contentsJSON(files.map { var e: [String: Any] = ["filename": $0.0, "scale": $0.2]; e["idiom"] = $0.1 ?? "universal"; return e }), "\(dir)/Contents.json")
}
// LaunchBrand: the whole static composition. tv: 1080 pt square at @2x; iPhone/iPad: 600 pt square at @2x and @3x.
imageset("LaunchBrand", [("tv@2x.png", "tv", "2x"), ("phone@2x.png", "universal", "2x"), ("phone@3x.png", "universal", "3x")])
writePNG(launchComposite(side: 2160), "\(assets)/LaunchBrand.imageset/tv@2x.png")
writePNG(launchComposite(side: 1200), "\(assets)/LaunchBrand.imageset/phone@2x.png")
writePNG(launchComposite(side: 1800), "\(assets)/LaunchBrand.imageset/phone@3x.png")
// The splash's layers (SwiftUI draws them at S points; same geometry as the composite).
let plateSide = 1024
let plateScene = launchScene(side: plateSide)
imageset("BrandPlate", [("plate.png", nil, "1x")])
writePNG(renderBack(plateScene, withGlow: false), "\(assets)/BrandPlate.imageset/plate.png")
let glowSide = 768   // covers the glow's full diameter (2 x 0.42 S)
imageset("BrandGlow", [("glow.png", nil, "1x")])
writePNG(renderGlow(Scene(w: glowSide, h: glowSide, centre: CGPoint(x: glowSide / 2, y: glowSide / 2), plumRadius: 1, glowRadius: Double(glowSide) / 2)), "\(assets)/BrandGlow.imageset/glow.png")
imageset("BrandWordmark", [("wordmark.png", nil, "1x")])
writePNG(wordmark.image, "\(assets)/BrandWordmark.imageset/wordmark.png")

// The launch canvas uses the same named dynamic colour as the page.
let canvasData = try! Data(contentsOf: URL(fileURLWithPath: "\(assets)/PigCanvas.colorset/Contents.json"))
try! canvasData.write(to: URL(fileURLWithPath: "\(assets)/LaunchEdge.colorset/Contents.json"))

// Explicit luminosity variants keep launch and the first splash frame identical.
func adaptiveImages(_ name: String, entries: [[String: Any]]) {
    write(contentsJSON(entries), "\(assets)/\(name).imageset/Contents.json")
}
var launchEntries: [[String: Any]] = []
for (stem, idiom, scale, side) in [("tv@2x", "tv", "2x", 2160), ("phone@2x", "universal", "2x", 1200), ("phone@3x", "universal", "3x", 1800)] {
    for light in [true, false] {
        let file = stem + (light ? "" : "-dark") + ".png"
        writePNG(launchComposite(side: side, light: light), "\(assets)/LaunchBrand.imageset/\(file)")
        var entry: [String: Any] = ["filename": file, "idiom": idiom, "scale": scale]
        if !light { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        launchEntries.append(entry)
    }
}
adaptiveImages("LaunchBrand", entries: launchEntries)
for name in ["BrandPlate", "BrandWordmark"] {
    var entries: [[String: Any]] = []
    for light in [true, false] {
        let file = light ? "light.png" : "dark.png"
        let bitmap = name == "BrandPlate" ? renderBack(plateScene, withGlow: false, light: light) : makeWordmark(light: light).image
        writePNG(bitmap, "\(assets)/\(name).imageset/\(file)")
        var entry: [String: Any] = ["filename": file, "idiom": "universal", "scale": "1x"]
        if !light { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        entries.append(entry)
    }
    adaptiveImages(name, entries: entries)
    let oldFile = name == "BrandPlate" ? "plate.png" : "wordmark.png"
    try? FileManager.default.removeItem(atPath: "\(assets)/\(name).imageset/\(oldFile)")
}

// The first splash frame equals the launch image; the final frame adds the wordmark and lifts the group.
let stack = stackedGroupOffset(pigWidth: launchPigWidth)   // in units of S
func splashFinal(side: Int) -> CGImage {
    let s = launchScene(side: side)
    let st = stackedGroupOffset(pigWidth: Double(side) * launchPigWidth)
    let shift = st.shift
    let liftedScene = Scene(w: side, h: side, centre: CGPoint(x: s.centre.x, y: s.centre.y - shift), plumRadius: s.plumRadius, glowRadius: s.glowRadius)
    let back = renderBack(Scene(w: side, h: side, centre: s.centre, plumRadius: s.plumRadius, glowRadius: s.glowRadius), withGlow: false)
    let glow = renderGlow(Scene(w: Int(2 * s.glowRadius), h: Int(2 * s.glowRadius), centre: CGPoint(x: s.glowRadius, y: s.glowRadius), plumRadius: 1, glowRadius: s.glowRadius))
    return opaque(compose(side, side) { c in
        draw(back, in: c, CGRect(x: 0, y: 0, width: side, height: side))
        draw(glow, in: c, CGRect(x: liftedScene.centre.x - s.glowRadius, y: liftedScene.centre.y - s.glowRadius, width: 2 * s.glowRadius, height: 2 * s.glowRadius))
        drawPig(c, width: st.pigWidth, centroidAt: liftedScene.centre)
        draw(wordmark.image, in: c, st.wordRect.offsetBy(dx: Double(liftedScene.centre.x), dy: Double(liftedScene.centre.y)))
    })
}
writePNG(splashFinal(side: 1200), "\(evidenceDir)/splash-final-design.png")
writePNG(launchComposite(side: 1200), "\(evidenceDir)/launch-design.png")

// MARK: - BrandLayout.swift (the numbers the SwiftUI splash uses)

let stackUnit = stackedGroupOffset(pigWidth: 1)   // per unit of S
write("""
// GENERATED by Tools/make-brand-assets.swift: do not edit; change the script and rerun it.

import CoreGraphics

/// Layout of the branded launch screen and splash, in units of the square side S (the launch image is S points wide;
/// the plum radius is S/2). Same geometry the script used for the launch bitmaps, so the splash's first frame equals
/// the launch screen.
nonisolated enum BrandLayout {
    /// Alpha-weighted centroid of PigLogo.png as a fraction of its width and height (the optical centre of the pig).
    static let pigCentroidX: CGFloat = \(f(pigCentroid.x))
    static let pigCentroidY: CGFloat = \(f(pigCentroid.y))
    /// Pig width, glow radius (alpha reaches 0 there), wordmark size and position: fractions of S.
    static let pigWidth: CGFloat = \(f(launchPigWidth))
    static let glowRadius: CGFloat = \(f(launchGlowRadius))
    /// The wordmark's rect relative to the pig's centroid (fractions of S), and how far the whole group lifts once it appears.
    static let wordmarkWidth: CGFloat = \(f(stackUnit.wordRect.width * launchPigWidth))
    static let wordmarkHeight: CGFloat = \(f(stackUnit.wordRect.height * launchPigWidth))
    static let wordmarkTop: CGFloat = \(f(stackUnit.wordRect.minY * launchPigWidth))
    static let groupLift: CGFloat = \(f(stackUnit.shift * launchPigWidth))
    /// The plum's edge colour, which fills everything beyond the launch square.
    static let edge: (r: Double, g: Double, b: Double) = (\(f(plumStops[2].1.r)), \(f(plumStops[2].1.g)), \(f(plumStops[2].1.b)))
}
""" + "\n", "\(repo)/PigTV/BrandLayout.swift")

print("pig centroid: x=\(f(pigCentroid.x)) y=\(f(pigCentroid.y)) of \(pigW)x\(pigH); wordmark \(Int(wordmark.width))x\(Int(wordmark.height)) font=ArialRoundedMTBold")
print("splash group lift (of S): \(f(stackUnit.shift * launchPigWidth))")
