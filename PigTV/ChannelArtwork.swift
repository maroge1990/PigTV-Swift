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
///
/// #360 (G4): a logo already in memory is drawn on the view's first frame (read in `body`, not in `.task`, so a reused
/// guide tile never draws its placeholder first and the logo a frame later), and a fetch is cancelled, down to its
/// URLSession task, once no view waits for it: the cell was reused for another channel, the view went away, or the guide
/// tile left the screen (`ArtworkLifetime`).
struct ChannelArtwork: View {
    let logo: String?
    let client: APIClient?
    /// The logo this view fetched (a cache entry can be evicted while it is shown).
    @State private var fetched: Fetched?
    /// The guide tile's cell, when there is one: whether it is on screen.
    @Environment(ArtworkLifetime.self) private var lifetime: ArtworkLifetime?

    private struct Fetched {
        let logo: String
        let image: DecodedLogo
    }

    /// What the view's task waits for: a fetch only while nothing is drawn and the view is on screen.
    private struct FetchID: Equatable {
        let logo: String?
        let wanted: Bool
    }

    // Keyed by `ArtworkKey` (the server-qualified absolute URL, no token), so
    // two servers' relative `/api/logo/1` never share an entry. Bounded by
    // decoded bytes, not count: a 320 px thumbnail is ~230 KB, so the budget holds about 140 of them, well over the
    // guide's visible tiles (about 12 rows) and the rows a fast scroll passes through before the first ones are reused.
    static let decodedByteBudget = 32 * 1024 * 1024
    @MainActor private static let cache: NSCache<NSString, LogoBox> = {
        let cache = NSCache<NSString, LogoBox>()
        cache.totalCostLimit = decodedByteBudget
        return cache
    }()
    // One fetch + decode per key; every view showing that logo awaits it (#360: cancelled when none waits).
    private static let inflight = SharedFetches<DecodedLogo?>(onCancel: { Task { @MainActor in GuidePerf.logoFetchCancelled() } })
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

    /// Tests: forget every decoded logo.
    static func clearCacheForTesting() { cache.removeAllObjects() }
    #endif

    /// The cache key for `logo` on `client`'s server, remembered per logo string (the guide redraws the same few hundred
    /// tiles; working the key out parses the URL).
    @MainActor private static var keys: [String: (address: ServerAddress, key: String)] = [:]
    @MainActor private static func key(_ logo: String, _ client: APIClient) -> String? {
        if let known = keys[logo], known.address == client.address { return known.key }
        guard let key = client.artworkKey(logo) else { return nil }
        if keys.count >= 4096 { keys.removeAll(keepingCapacity: true) }
        keys[logo] = (client.address, key)
        return key
    }

    /// What to draw now: what this view fetched, else the memory cache (no placeholder frame for a logo already decoded).
    private var shown: DecodedLogo? {
        guard let logo else { return nil }
        if let fetched, fetched.logo == logo { return fetched.image }
        guard let client, let key = Self.key(logo, client), let hit = Self.cache.object(forKey: key as NSString) else { return nil }
        GuidePerf.logoSyncHit()
        return hit.value
    }

    var body: some View {
        let decoded = shown
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
                Image(systemName: "tv.fill").foregroundStyle(Color.pigAccent).padding(PigSpacing.s)
            }
        }
        .accessibilityHidden(true)
        // The lifetime is read only while nothing is drawn, so a tile with its logo is not updated when it leaves the screen.
        .task(id: FetchID(logo: logo, wanted: decoded == nil && (lifetime?.isDisplayed ?? true))) {
            guard decoded == nil, lifetime?.isDisplayed ?? true, let logo, let client, let key = Self.key(logo, client) else { return }
            // Decoded meanwhile by another view: drawn from the cache from now on (counted: drawn a frame late).
            if let cached = Self.cache.object(forKey: key as NSString) {
                GuidePerf.logoLateHit()
                fetched = Fetched(logo: logo, image: cached.value)
                return
            }
            let result = await Self.decodedLogo(key: key, logo: logo, client: client, cancellable: true)
            guard !Task.isCancelled, let result else { return }
            fetched = Fetched(logo: logo, image: result)
        }
    }

    /// Fetch and decode once per key. `cancellable`: the fetch stops (its URLSession task too) once every cancellable
    /// caller has been cancelled and no other caller waits; other callers (the Sport front's marks) keep it going.
    @MainActor
    static func decodedLogo(key: String, logo: String, client: APIClient, cancellable: Bool = false) async -> DecodedLogo? {
        if let cached = cache.object(forKey: key as NSString) { return cached.value }
        let joined = inflight.join(key, cancellable: cancellable) {
            Task<DecodedLogo?, any Error> {
                guard let data = try? await client.artworkData(logo, cancellable: true), !Task.isCancelled else { return nil }
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
        }
        if joined.started { GuidePerf.logoFetchStarted() }
        return (try? await inflight.wait(for: joined.entry, key: key, cancellable: cancellable)) ?? nil
    }
}

/// #360 (G4): whether a guide tile's cell is on screen (the grid sets it as cells start and end being displayed). A logo
/// fetch runs only while it is: a tile that leaves the screen before its logo arrives cancels the fetch, and starts it
/// again if it comes back. Views outside the guide have none and fetch while they exist.
@MainActor @Observable final class ArtworkLifetime {
    var isDisplayed = true
}
