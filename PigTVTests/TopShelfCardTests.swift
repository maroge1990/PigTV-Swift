import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PigTV

// Build 32: the Top Shelf's rendered cards: sizing (never upscaling a logo),
// file names, the full-size logo URL and the files' lifecycle.
@MainActor
final class TopShelfCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLogoIsDrawnAtNoMoreThanItsNativePixelSize() {
        // Small: 160×72 px at scale 2 is 80×36 pt, i.e. still 160×72 card pixels.
        XCTAssertEqual(TopShelfCardLayout.logoSize(pixelSize: CGSize(width: 160, height: 72)), CGSize(width: 80, height: 36))
        // Large and wide: reduced to the box's height, aspect kept.
        let large = TopShelfCardLayout.logoSize(pixelSize: CGSize(width: 1200, height: 540))
        XCTAssertEqual(large.height, TopShelfCardLayout.logoBox.height, accuracy: 0.01)
        XCTAssertEqual(large.width / large.height, 1200.0 / 540.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(large.width, TopShelfCardLayout.logoBox.width)
        // Very wide: limited by the box's width.
        let banner = TopShelfCardLayout.logoSize(pixelSize: CGSize(width: 3000, height: 300))
        XCTAssertEqual(banner.width, TopShelfCardLayout.logoBox.width, accuracy: 0.01)
        XCTAssertEqual(banner.width / banner.height, 10, accuracy: 0.001)
        // Tall: limited by height.
        let tall = TopShelfCardLayout.logoSize(pixelSize: CGSize(width: 200, height: 800))
        XCTAssertEqual(tall, CGSize(width: 52.5, height: 210))
        // Never larger than native, whatever the box.
        let roomy = TopShelfCardLayout.logoSize(pixelSize: CGSize(width: 300, height: 100), box: CGSize(width: 5000, height: 5000))
        XCTAssertEqual(roomy, CGSize(width: 150, height: 50))
        XCTAssertEqual(TopShelfCardLayout.logoSize(pixelSize: .zero), .zero)
        // The card is Apple's 16:9 Top Shelf size, rendered at 2x.
        XCTAssertEqual(TopShelfCardLayout.size, CGSize(width: 908, height: 512))
        XCTAssertEqual(TopShelfCardLayout.scale, 2)
    }

    func testProgressAndFileNames() {
        let end = now.addingTimeInterval(3600)
        XCTAssertEqual(TopShelfCardLayout.progress(start: now, end: end, at: now.addingTimeInterval(900)) ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertNil(TopShelfCardLayout.progress(start: now, end: end, at: end))
        XCTAssertNil(TopShelfCardLayout.progress(start: end, end: now, at: now))
        let a = TopShelfCardLayout.fileName(sourceId: 1, id: "fox/footy:504", content: "x")
        XCTAssertEqual(a, TopShelfCardLayout.fileName(sourceId: 1, id: "fox/footy:504", content: "x"), "stable")
        XCTAssertNotEqual(a, TopShelfCardLayout.fileName(sourceId: 1, id: "fox/footy:504", content: "y"), "content changes the name")
        XCTAssertTrue(a.hasPrefix("1_fox_footy_504-") && a.hasSuffix(".png"), a)
        XCTAssertNotNil(TopShelfCards.fileURL(a, in: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(TopShelfCards.fileURL("../x.png", in: URL(fileURLWithPath: "/tmp")), "never a path")
    }

    func testFullSizeLogoOnlyForTheServersLogoCache() {
        let base = URL(string: "http://tv.local:3000")
        XCTAssertEqual(BrowseModel.fullSizeLogo("/api/logo/abc", relativeTo: base), "http://tv.local:3000/api/logo/abc?size=full")
        XCTAssertEqual(BrowseModel.fullSizeLogo("http://tv.local:3000/api/logo/abc?size=thumb", relativeTo: base),
                       "http://tv.local:3000/api/logo/abc?size=full")
        XCTAssertNil(BrowseModel.fullSizeLogo("https://cdn.example/fox.png", relativeTo: base))
        XCTAssertNil(BrowseModel.fullSizeLogo("/api/proxy/image?url=x", relativeTo: base))
    }

    func testDecodingNeverEnlargesAndLooksAreAnalysed() throws {
        let small = image(CGSize(width: 120, height: 60), colour: UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        let decoded = try XCTUnwrap(BrowseModel.decodeLogo(try XCTUnwrap(png(small))))
        XCTAssertEqual(decoded.size.width * decoded.scale, 120)
        XCTAssertEqual(decoded.size.height * decoded.scale, 60)
        let red = TopShelfLogoLook.analyse(try XCTUnwrap(small.cgImage))
        XCTAssertFalse(red.transparent)
        XCTAssertFalse(red.needsPlate)
        XCTAssertGreaterThan(try XCTUnwrap(red.tint)[0], 0.6)
        // A dark mark on a clear background gets a light plate.
        let dark = image(CGSize(width: 100, height: 100), colour: UIColor(white: 0.05, alpha: 1), inset: 30)
        let look = TopShelfLogoLook.analyse(try XCTUnwrap(dark.cgImage))
        XCTAssertTrue(look.transparent)
        XCTAssertTrue(look.needsPlate)
    }

    func testCardsAreWrittenReusedChosenByTimeAndPruned() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let logoURL = URL(string: "http://tv.local:3000/api/logo/fox")
        let entry = TopShelfSnapshot.Entry(id: "fox", sourceId: 1, name: "Fox Footy", number: nil, logo: logoURL, programmes: [
            .init(title: "AFL Live", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3000)),
            .init(title: "AFL 360", start: now.addingTimeInterval(3000), end: now.addingTimeInterval(6600))])
        let bare = TopShelfSnapshot.Entry(id: "tcm", sourceId: 1, name: "TCM", number: nil, logo: nil, programmes: [])
        let snapshot = TopShelfSnapshot(kind: "favourites", channels: [entry, bare], savedAt: now)
        var loads = 0
        let loader: TopShelfCardExport.LogoLoader = { _ in
            loads += 1
            return self.image(CGSize(width: 160, height: 72), colour: .systemGreen)
        }
        let rendered = await TopShelfCardExport.render(snapshot, logoSources: ["1:fox": "/api/logo/fox"], loader: loader,
                                                       container: container, now: now)
        XCTAssertEqual(loads, 1, "one logo load per channel")
        let cards = try XCTUnwrap(rendered.channels[0].cards)
        XCTAssertEqual(cards.count, 2, "now and next")
        XCTAssertEqual(rendered.channels[1].cards?.count, 1, "a channel card without programme data")
        XCTAssertNil(rendered.channels[1].cards?[0].start)
        let directory = try XCTUnwrap(TopShelfCards.directory(in: container))
        XCTAssertEqual(Array(directory.pathComponents.suffix(3)), ["Library", "Caches", "topshelf"])
        // Each file is a 1816×1024 PNG.
        let file = try XCTUnwrap(TopShelfCards.fileURL(cards[0].file, in: container))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1816)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        // The extension's choice: the card for the programme on then, the
        // channel card, else the logo URL.
        XCTAssertEqual(rendered.channels[0].imageURL(at: now, container: container), file)
        XCTAssertEqual(rendered.channels[0].imageURL(at: now.addingTimeInterval(4000), container: container),
                       TopShelfCards.fileURL(cards[1].file, in: container))
        XCTAssertEqual(rendered.channels[0].imageURL(at: now.addingTimeInterval(9000), container: container), logoURL)
        XCTAssertNotNil(rendered.channels[1].imageURL(at: now.addingTimeInterval(9000), container: container))
        XCTAssertEqual(TopShelfCards.renderedCount(for: rendered, in: container), 3)
        // A second run with the same content renders nothing new.
        let again = await TopShelfCardExport.render(snapshot, logoSources: ["1:fox": "/api/logo/fox"], loader: loader,
                                                    container: container, now: now)
        XCTAssertEqual(again, rendered)
        XCTAssertEqual(loads, 1, "existing cards are reused")
        // The snapshot round-trips its cards; older snapshots have none.
        XCTAssertEqual(TopShelfSnapshot.decode(try rendered.encoded()), rendered)
        // Stale files go; referenced ones stay.
        XCTAssertTrue(TopShelfCards.write(Data("old".utf8), named: "1_old-000000.png", in: container))
        let keep = Set(rendered.channels.flatMap { $0.cards ?? [] }.map(\.file))
        XCTAssertEqual(TopShelfCards.prune(keeping: keep, in: container), 1)
        XCTAssertEqual(TopShelfCards.renderedCount(for: rendered, in: container), 3)
        // A missing file falls back to the logo URL.
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(rendered.channels[0].imageURL(at: now, container: container), logoURL)
        // Sign-out removes them all.
        TopShelfCards.removeAll(in: container)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(TopShelfCards.renderedCount(for: rendered, in: container), 0)
    }

    // MARK: Helpers

    private func image(_ size: CGSize, colour: UIColor, inset: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            colour.setFill()
            UIRectFill(CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
        }
    }

    private func png(_ image: UIImage) -> Data? { image.pngData() }
}
