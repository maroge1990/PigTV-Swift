import XCTest
import CoreGraphics
import ImageIO

// #342 (Apple 325): the launch screen's pig is the brand pink, #F97BAB (249,123,171), as the splash draws it. iOS and tvOS
// show the launch image's pixel values as Display P3 whatever the file is tagged: an sRGB file showed the pink as
// (255,115,172), a colour pop at the first frame (measured on the iPhone 17 and Apple TV simulators). Tools/render-launch
// now draws and saves the images in Display P3, converted from the sRGB brand colours, so they show the exact pink; the
// launch frame and the splash's first frame then measure (249,124,171) and (249,123,171). Fails on 324's sRGB images.
final class LaunchImageTests: XCTestCase {
    private static let imageset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PigTV/Assets.xcassets/LaunchBrand.imageset")

    func testTheLaunchImagesAreDisplayP3HoldingTheBrandPink() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.imageset.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(names.count, 6, "tv @2x, phone @2x and @3x, light and dark")
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for name in names {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(Self.imageset.appendingPathComponent(name) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3, "\(name) is drawn in Display P3")
            // In sRGB, the pig's body is the brand pink.
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var counts: [[Int]: Int] = [:]
            for i in stride(from: 0, to: pixels.count, by: 4 * 5) where pixels[i + 3] == 255 && pixels[i] > 200 && pixels[i + 1] < 160 {
                counts[[Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])], default: 0] += 1
            }
            let pink = try XCTUnwrap(counts.max { $0.value < $1.value }?.key, "\(name): no pink")
            for (channel, brand) in zip(pink, [249, 123, 171]) {
                XCTAssertEqual(channel, brand, accuracy: 1, "\(name): the body's pink \(pink) is #F97BAB")
            }
        }
    }
}
