import SwiftUI
import ImageIO
import CoreGraphics

/// Decoded logo plus what it needs behind it. Logos are mostly flat marks on a
/// transparent background; a white mark vanishes on a light page and a black
/// mark vanishes on a dark one. The analysis says which, so the tile can add a
/// plain black or white backing only when the appearance would otherwise hide
/// the logo — no coloured boxes.
nonisolated struct DecodedLogo: Sendable {
    enum Backing: Sendable { case none, light, dark, neutral }
    let image: UIImage
    let lightShare: Double     // share of opaque pixels with luminance ≥ 0.7
    let darkShare: Double      // share of opaque pixels with luminance ≤ 0.3
    let hasTransparency: Bool  // ≥ 15% of pixels are (nearly) transparent

    // Mixed marks (a dark badge with white lettering, say) lose one half on
    // either a black or a white background, so they get a mid-grey backing
    // where both remain legible. Single-tone marks get the opposite tone only
    // when the current appearance would otherwise hide them.
    func backing(in scheme: ColorScheme) -> Backing {
        guard hasTransparency else { return .none }
        if lightShare >= 0.12 && darkShare >= 0.12 { return .neutral }
        if scheme == .dark { return darkShare > lightShare ? .light : .none }
        return lightShare > darkShare ? .dark : .none
    }

    static func analyse(_ cgImage: CGImage) -> DecodedLogo {
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else {
            return DecodedLogo(image: UIImage(cgImage: cgImage), lightShare: 0, darkShare: 0, hasTransparency: false)
        }
        var light = 0, dark = 0, opaque = 0, transparent = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            if alpha < 0.1 { transparent += 1; continue }
            // Premultiplied components: divide by alpha to recover colour.
            let r = Double(pixels[index]) / 255 / alpha
            let g = Double(pixels[index + 1]) / 255 / alpha
            let b = Double(pixels[index + 2]) / 255 / alpha
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luminance >= 0.7 { light += 1 } else if luminance <= 0.3 { dark += 1 }
            opaque += 1
        }
        let count = Double(max(opaque, 1))
        return DecodedLogo(image: UIImage(cgImage: cgImage), lightShare: Double(light) / count,
                           darkShare: Double(dark) / count,
                           hasTransparency: Double(transparent) / Double(size * size) >= 0.15)
    }
}

/// Channel logo drawn as large as its frame allows, with no container. A
/// black or white backing appears only when the current appearance would hide
/// the mark; unsupported or missing images show the TV fallback.
struct ChannelArtwork: View {
    let logo: String?
    let client: APIClient?
    @State private var decoded: DecodedLogo?
    @Environment(\.colorScheme) private var scheme

    @MainActor private static let cache: NSCache<NSString, LogoBox> = {
        let cache = NSCache<NSString, LogoBox>()
        cache.countLimit = 400
        return cache
    }()
    final class LogoBox: Sendable {
        let value: DecodedLogo
        init(_ value: DecodedLogo) { self.value = value }
    }

    var body: some View {
        ZStack {
            if let decoded {
                // One backing for every transparent logo so the column reads as a
                // set: a dark charcoal in dark mode, a mid grey in light mode.
                // Logos that bring their own background (JPEGs) sit bare.
                if decoded.hasTransparency {
                    RoundedRectangle(cornerRadius: 8).fill(scheme == .dark ? Color(white: 0.22) : Color(white: 0.42))
                }
                Image(uiImage: decoded.image).resizable().scaledToFit()
                    .padding(decoded.hasTransparency ? 6 : 0)
            } else {
                Image(systemName: "tv.fill").foregroundStyle(Color.accentColor).padding(8)
            }
        }
        .accessibilityHidden(true)
        .task(id: logo) {
            guard let logo, let client else { decoded = nil; return }
            if let cached = Self.cache.object(forKey: logo as NSString) { decoded = cached.value; return }
            decoded = nil
            guard let data = try? await client.artworkData(logo), !Task.isCancelled else { return }
            let result: DecodedLogo? = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                return DecodedLogo.analyse(cgImage)
            }.value
            guard !Task.isCancelled, let result else { return }
            Self.cache.setObject(LogoBox(result), forKey: logo as NSString)
            decoded = result
        }
    }
}
