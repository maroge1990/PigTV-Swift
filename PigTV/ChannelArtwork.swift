import SwiftUI
import ImageIO
import CoreGraphics

/// Decoded logo retained in the artwork cache. The guide owns its tile
/// background, so artwork never creates a second app-provided backing.
nonisolated struct DecodedLogo: Sendable {
    let image: UIImage
    /// Decoded size in bytes: what the cache budget counts.
    let cost: Int

    init(image: UIImage, cost: Int? = nil) {
        self.image = image
        self.cost = cost ?? Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    static func analyse(_ cgImage: CGImage) -> DecodedLogo {
        DecodedLogo(image: UIImage(cgImage: cgImage), cost: cgImage.bytesPerRow * cgImage.height)
    }
}

/// Channel logo drawn as large as its frame allows. The guide owns the single
/// full-tile backing so this view never adds an artwork-sized nested box.
struct ChannelArtwork: View {
    let logo: String?
    let client: APIClient?
    @State private var decoded: DecodedLogo?

    // Keyed by `ArtworkKey` (the server-qualified absolute URL, no token), so
    // two servers' relative `/api/logo/1` never share an entry. Bounded by
    // decoded bytes, not count: a 320 px thumbnail is ~230 KB.
    static let decodedByteBudget = 32 * 1024 * 1024
    @MainActor private static let cache: NSCache<NSString, LogoBox> = {
        let cache = NSCache<NSString, LogoBox>()
        cache.totalCostLimit = decodedByteBudget
        return cache
    }()
    // One fetch + decode per key; every cell showing that logo awaits it.
    @MainActor private static var inflight: [String: Task<DecodedLogo?, Never>] = [:]
    final class LogoBox: Sendable {
        let value: DecodedLogo
        init(_ value: DecodedLogo) { self.value = value }
    }

    /// Home's blurred wash: the logo filling its frame (no placeholder glyph).
    var fill = false

    /// The decoded thumbnail, if the guide has drawn this logo (build 32:
    /// the Top Shelf cards' last resort).
    static func cachedImage(for logo: String, address: ServerAddress) -> UIImage? {
        guard let key = ArtworkKey.key(logo: logo, address: address) else { return nil }
        return cache.object(forKey: key as NSString)?.value.image
    }

    #if DEBUG
    /// Fixture logos (PIGTV_UI_TEST_SCREEN=home) go straight into the cache.
    static func preload(_ image: UIImage, for logo: String, address: ServerAddress) {
        guard let key = ArtworkKey.key(logo: logo, address: address) else { return }
        let value = DecodedLogo(image: image)
        cache.setObject(LogoBox(value), forKey: key as NSString, cost: value.cost)
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
            guard let logo, let client, let key = client.artworkKey(logo) else { decoded = nil; return }
            if let cached = Self.cache.object(forKey: key as NSString) { decoded = cached.value; return }
            decoded = nil
            let result = await Self.decodedLogo(key: key, logo: logo, client: client)
            guard !Task.isCancelled, let result else { return }
            decoded = result
        }
    }

    /// Fetch and decode once per key. The shared task is unstructured, so a
    /// cell scrolling away (cancelling its own `.task`) does not cancel the
    /// work the other cells are waiting on.
    @MainActor
    static func decodedLogo(key: String, logo: String, client: APIClient) async -> DecodedLogo? {
        if let cached = cache.object(forKey: key as NSString) { return cached.value }
        if let pending = inflight[key] { return await pending.value }
        let task = Task<DecodedLogo?, Never> {
            defer { inflight[key] = nil }
            guard let data = try? await client.artworkData(logo) else { return nil }
            let result: DecodedLogo? = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                return DecodedLogo.analyse(cgImage)
            }.value
            guard let result else { return nil }
            cache.setObject(LogoBox(result), forKey: key as NSString, cost: result.cost)
            PigTVSignpost.event("LogoDecoded", String(logo.split(separator: "/").last?.prefix(40) ?? ""))
            return result
        }
        inflight[key] = task
        return await task.value
    }
}
