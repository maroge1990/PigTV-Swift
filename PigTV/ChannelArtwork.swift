import SwiftUI
import ImageIO
import CoreGraphics

/// Decoded logo retained in the artwork cache. The guide owns its tile
/// background, so artwork never creates a second app-provided backing.
nonisolated struct DecodedLogo: Sendable {
    let image: UIImage

    static func analyse(_ cgImage: CGImage) -> DecodedLogo {
        DecodedLogo(image: UIImage(cgImage: cgImage))
    }
}

/// Channel logo drawn as large as its frame allows. The guide owns the single
/// full-tile backing so this view never adds an artwork-sized nested box.
struct ChannelArtwork: View {
    let logo: String?
    let client: APIClient?
    @State private var decoded: DecodedLogo?

    @MainActor private static let cache: NSCache<NSString, LogoBox> = {
        let cache = NSCache<NSString, LogoBox>()
        cache.countLimit = 400
        return cache
    }()
    final class LogoBox: Sendable {
        let value: DecodedLogo
        init(_ value: DecodedLogo) { self.value = value }
    }

    /// Home's blurred wash: the logo filling its frame (no placeholder glyph).
    var fill = false

    /// The decoded thumbnail, if the guide has drawn this logo (build 32:
    /// the Top Shelf cards' last resort).
    static func cachedImage(for logo: String) -> UIImage? {
        cache.object(forKey: logo as NSString)?.value.image
    }

    #if DEBUG
    /// Fixture logos (PIGTV_UI_TEST_SCREEN=home) go straight into the cache.
    static func preload(_ image: UIImage, for logo: String) {
        cache.setObject(LogoBox(DecodedLogo(image: image)), forKey: logo as NSString)
    }
    #endif

    var body: some View {
        ZStack {
            if let decoded {
                if fill {
                    Image(uiImage: decoded.image).resizable().scaledToFill()
                } else {
                    Image(uiImage: decoded.image).resizable().scaledToFit()
                }
            } else if fill {
                Color.clear

            } else {
                Image(systemName: "tv.fill").foregroundStyle(Color.pigAccent).padding(8)
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
            PigTVSignpost.event("LogoDecoded", String(logo.split(separator: "/").last?.prefix(40) ?? ""))
            decoded = result
        }
    }
}
