import SwiftUI
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import os

// Build 32 (Mark: "the logos are very pixelated when blown up to that size
// … it's worse than nothing right now"). The Top Shelf's 16:9 items were
// channel logos, mostly the server's 320 px thumbnails, stretched by tvOS to
// fill a 1816×1024 image. Now the app renders its own card per channel and
// programme and the extension shows those files:
//
//  - Size: Apple's Top Shelf guidance for sectioned 16:9 (`.hdtv`) items is
//    908×512 at 1x (852×480 focused safe area); cards are drawn at 908×512
//    points with scale 2, so 1816×1024 px PNGs (tvOS scales down for 1080p).
//  - Design: a dark PigTV card (a subtle gradient with a faint wash of the
//    logo's dominant colour, like Home's hero); the logo centred in the
//    upper part at no more than its native pixel size (1 logo px = 1 card
//    px; never upscaled, so a small logo stays small and sharp); a dark
//    logo with a transparent background sits on a light plate so it can be
//    seen; the programme title in bold (up to 2 lines); a small LIVE and
//    time line; a thin pink progress bar, the only pink.
//  - Logos: the server's full-size `/api/logo/<key>?size=full` for logo-cache
//    paths (an older server ignores the query and sends its thumbnail),
//    else the plain URL, else the in-memory thumbnail.
//  - Files: `<group>/Library/Caches/topshelf/<channel>-<content hash>.png`.
//    The name changes with the content, so tvOS never shows a cached copy of
//    an older card; an existing file is reused without rendering; files no
//    longer referenced are deleted after the snapshot is written.
//  - One card for the programme on now (with progress at render time) and
//    one for the next (drawn as it will look when it is on), or a channel
//    card when there is no programme data. The extension picks the card for
//    the current time, else falls back to the logo URL.

/// Pure sizing for the card (tested).
nonisolated enum TopShelfCardLayout {
    /// The card in points (Apple's 16:9 Top Shelf size at 1x).
    static let size = CGSize(width: 908, height: 512)
    /// Render scale: 1816×1024 px files.
    static let scale: CGFloat = 2
    /// The largest the logo may be drawn, in points.
    static let logoBox = CGSize(width: 520, height: 210)
    /// Bumped whenever the design changes, so every card is redrawn.
    static let version = 1

    /// The logo's drawn size in points: its native pixel size at the render
    /// scale (one logo pixel per card pixel), reduced to fit `box` keeping
    /// its aspect ratio, and never enlarged.
    static func logoSize(pixelSize: CGSize, box: CGSize = logoBox, scale: CGFloat = scale) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0, scale > 0 else { return .zero }
        let native = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let fit = min(1, box.width / native.width, box.height / native.height)
        return CGSize(width: native.width * fit, height: native.height * fit)
    }

    /// Progress through a programme, 0…1 (nil outside it).
    static func progress(start: Date, end: Date, at date: Date) -> Double? {
        guard end > start, date >= start, date < end else { return nil }
        return date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// A card's file name: the channel plus a hash of everything drawn, so
    /// different content never reuses a name (tvOS caches images by URL).
    static func fileName(sourceId: Int, id: String, content: String) -> String {
        let channel = "\(sourceId)_\(id)".map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined().prefix(48)
        let digest = SHA256.hash(data: Data("v\(version)|\(content)".utf8))
        return "\(channel)-\(digest.prefix(6).map { String(format: "%02x", $0) }.joined()).png"
    }
}

/// What a logo looks like, for the card's wash and plate.
nonisolated struct TopShelfLogoLook: Equatable, Sendable {
    /// Saturation-weighted average colour of its visible pixels (0…1 RGB).
    var tint: [Double]?
    /// Mean brightness (HSB value: the brightest channel) of its visible
    /// pixels, so a deep red or blue mark does not count as dark.
    var luminance: Double
    /// Whether any part is transparent (a mark on a clear background).
    var transparent: Bool

    /// A dark mark on a clear background would vanish on the dark card.
    var needsPlate: Bool { transparent && luminance < 0.3 }

    static func analyse(_ image: CGImage) -> TopShelfLogoLook {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return TopShelfLogoLook(tint: nil, luminance: 0.5, transparent: false) }
        var weighted = [0.0, 0.0, 0.0], weights = 0.0, luminance = 0.0, visible = 0.0
        var transparent = false
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            if alpha < 0.9 { transparent = true }
            guard alpha > 0.5 else { continue }
            let rgb = (0..<3).map { Double(pixels[index + $0]) / 255 / alpha }
            let high = rgb.max() ?? 0, low = rgb.min() ?? 0
            let saturation = high > 0 ? (high - low) / high : 0
            let weight = saturation * high + 0.02
            for channel in 0..<3 { weighted[channel] += rgb[channel] * weight }
            weights += weight
            luminance += high
            visible += 1
        }
        guard visible > 0 else { return TopShelfLogoLook(tint: nil, luminance: 0.5, transparent: true) }
        let tint = weighted.map { min(1, $0 / weights) }
        let saturated = (tint.max() ?? 0) - (tint.min() ?? 0) > 0.12
        return TopShelfLogoLook(tint: saturated ? tint : nil, luminance: luminance / visible, transparent: transparent)
    }
}

/// What one card shows.
nonisolated struct TopShelfCardContent: Equatable, Sendable {
    var channel: String
    /// The programme (nil: a channel card).
    var title: String?
    /// "LIVE" is drawn before this line when set.
    var live: Bool
    /// "7:30 – 9:00 pm" (empty on a channel card).
    var line: String
    /// Pink bar, 0…1 (nil: none).
    var progress: Double?

    /// Everything drawn except the logo image (for the file name).
    var key: String {
        [channel, title ?? "-", live ? "live" : "-", line, progress.map { String(Int(($0 * 20).rounded())) } ?? "-"]
            .joined(separator: "|")
    }
}

/// The card itself (also shown by the topshelf-cards fixture).
struct TopShelfCardView: View {
    let content: TopShelfCardContent
    let logo: UIImage?
    let look: TopShelfLogoLook?

    private var tint: Color {
        guard let rgb = look?.tint else { return Color.pigAccent }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.14), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(look?.tint == nil && logo != nil ? 0.16 : 0.34), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 10, endRadius: 560)
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 0) {
                logoArea.frame(maxWidth: .infinity).frame(height: 268)
                Spacer(minLength: 0)
                text.padding(.horizontal, 44).padding(.bottom, 34)
            }
        }
        .frame(width: TopShelfCardLayout.size.width, height: TopShelfCardLayout.size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var logoArea: some View {
        if let logo {
            let size = TopShelfCardLayout.logoSize(pixelSize: CGSize(width: logo.size.width * logo.scale,
                                                                     height: logo.size.height * logo.scale))
            Image(uiImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(look?.needsPlate == true ? 18 : 0)
                .background {
                    if look?.needsPlate == true {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.92))
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .padding(.top, 30)
        } else {
            // No logo: the pig, small and quiet, and the channel's name.
            VStack(spacing: 14) {
                PigBrandMark(width: 84, height: 68).opacity(0.85)
                if content.title != nil {
                    Text(content.channel).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(.top, 30)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.title ?? content.channel)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if content.live {
                    Text("LIVE")
                        .font(.system(size: 19, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                if !content.line.isEmpty {
                    Text(content.line)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            if let progress = content.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.pigAccent)
                            .frame(width: max(6, geometry.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// Renders the snapshot's cards and saves the snapshot pointing at them.
@MainActor
enum TopShelfCardExport {
    private static var task: Task<Void, Never>?
    /// The last run's result, for the fixture screen and tests.
    private(set) static var lastRendered: TopShelfSnapshot?

    typealias LogoLoader = @MainActor (String) async -> UIImage?

    /// Replaces any run in progress with one for `snapshot`.
    static func schedule(_ snapshot: TopShelfSnapshot, logoSources: [String: String], loader: @escaping LogoLoader,
                         container: URL? = AppGroupStorage.containerURL) {
        task?.cancel()
        task = Task { @MainActor in
            let rendered = await render(snapshot, logoSources: logoSources, loader: loader, container: container)
            guard !Task.isCancelled else { return }
            lastRendered = rendered
            TopShelfExport.save(rendered, pruneCardsIn: container)
        }
    }

    /// Waits for the current run (fixtures and tests).
    static func finish() async { await task?.value }

    /// The snapshot with each entry's cards, rendering only cards whose files
    /// do not exist yet.
    static func render(_ snapshot: TopShelfSnapshot, logoSources: [String: String], loader: LogoLoader,
                       container: URL?, now: Date = Date()) async -> TopShelfSnapshot {
        guard container != nil else { return snapshot }
        var result = snapshot
        var logos: [String: LoadedLogo] = [:]
        for (index, entry) in snapshot.channels.enumerated() {
            if Task.isCancelled { return snapshot }
            let logoKey = entry.logo?.absoluteString ?? ""
            var cards: [TopShelfSnapshot.Card] = []
            for (content, slot) in contents(for: entry, now: now) {
                let name = TopShelfCardLayout.fileName(sourceId: entry.sourceId, id: entry.id,
                                                       content: content.key + "|" + logoKey)
                if !TopShelfCards.exists(name, in: container) {
                    let logo: LoadedLogo
                    if let loaded = logos[logoKey] {
                        logo = loaded
                    } else {
                        var image: UIImage?
                        if let source = logoSources["\(entry.sourceId):\(entry.id)"] { image = await loader(source) }
                        logo = LoadedLogo(image: image, look: image?.cgImage.map(TopShelfLogoLook.analyse))
                        logos[logoKey] = logo
                    }
                    guard let png = renderPNG(content, logo: logo.image, look: logo.look) else { continue }
                    let written = await Task.detached(priority: .utility) {
                        TopShelfCards.write(png, named: name, in: container)
                    }.value
                    guard written else { continue }
                    // Keep the main thread free between cards.
                    await Task.yield()
                }
                cards.append(TopShelfSnapshot.Card(file: name, start: slot?.start, end: slot?.end))
            }
            result.channels[index].cards = cards.isEmpty ? nil : cards
        }
        return result
    }

    /// Now and next (or the channel alone without programme data).
    static func contents(for entry: TopShelfSnapshot.Entry, now: Date) -> [(TopShelfCardContent, TopShelfSnapshot.Slot?)] {
        let slots = entry.programmes.filter { $0.end > now }.prefix(2)
        guard !slots.isEmpty else {
            return [(TopShelfCardContent(channel: entry.name, title: nil, live: true, line: "", progress: nil), nil)]
        }
        return slots.map { slot in
            let times = "\(slot.start.formatted(date: .omitted, time: .shortened)) – \(slot.end.formatted(date: .omitted, time: .shortened))"
            // The next programme is drawn as it will look while it is on.
            let progress = TopShelfCardLayout.progress(start: slot.start, end: slot.end, at: now)
            return (TopShelfCardContent(channel: entry.name, title: slot.title, live: true, line: times,
                                        progress: progress ?? 0), slot)
        }
    }

    static func renderPNG(_ content: TopShelfCardContent, logo: UIImage?, look: TopShelfLogoLook?) -> Data? {
        let renderer = ImageRenderer(content: TopShelfCardView(content: content, logo: logo, look: look))
        renderer.scale = TopShelfCardLayout.scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else {
            TopShelfLog.logger.error("cards: render failed for \(content.channel, privacy: .public)")
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private struct LoadedLogo {
    var image: UIImage?
    var look: TopShelfLogoLook?
}

// MARK: Logos

extension BrowseModel {
    /// Each snapshot entry's logo as the app knows it ("sourceId:id" →
    /// relative path, absolute URL or fixture key).
    func topShelfLogoSources(for snapshot: TopShelfSnapshot) -> [String: String] {
        var sources: [String: String] = [:]
        for entry in snapshot.channels {
            let key = "\(entry.sourceId):\(entry.id)"
            if let row = guideChannel(id: key), let logo = logo(for: row) { sources[key] = logo }
            else if let favourite = favourites.first(where: { $0.id == key }), let logo = logo(for: favourite) { sources[key] = logo }
        }
        return sources
    }

    /// The server's full-size logo: `/api/logo/<key>?size=full` for its logo
    /// cache paths; nil for any other URL.
    nonisolated static func fullSizeLogo(_ logo: String, relativeTo base: URL?) -> String? {
        guard let url = URL(string: logo, relativeTo: base)?.absoluteURL, url.path.hasPrefix("/api/logo/"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (parts.queryItems ?? []).filter { $0.name != "size" }
        items.append(URLQueryItem(name: "size", value: "full"))
        parts.queryItems = items
        return parts.url?.absoluteString
    }

    /// The logo at the best resolution available: full size, else the
    /// plain URL, else the thumbnail already decoded for the guide.
    func topShelfLogoImage(_ logo: String) async -> UIImage? {
        #if DEBUG
        if isFixture { return GuideFixtures.topShelfLogo(logo) ?? ChannelArtwork.cachedImage(for: logo, address: client.address) }
        #endif
        var candidates: [String] = []
        if let full = Self.fullSizeLogo(logo, relativeTo: client.address.url) { candidates.append(full) }
        candidates.append(logo)
        for candidate in candidates {
            guard let data = await withTimeout(seconds: 8, { [client] in try? await client.artworkData(candidate) }) ?? nil
            else { continue }
            if let image = await Task.detached(priority: .utility, operation: { Self.decodeLogo(data) }).value { return image }
        }
        return ChannelArtwork.cachedImage(for: logo, address: client.address)
    }

    /// Decodes at native size (capped at 2048 px, never enlarged).
    nonisolated static func decodeLogo(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}

/// `operation`'s result, or nil if it takes longer than `seconds`.
@MainActor
private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
