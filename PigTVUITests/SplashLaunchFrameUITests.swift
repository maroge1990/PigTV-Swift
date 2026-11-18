import XCTest
import UIKit

/// #342: the splash's pig is exactly where the launch screen's pig was, so the first frame does not jump. The launch image
/// is centred on the whole screen (UILaunchScreen, UIImageRespectsSafeAreaInsets false; measured on iPhone 17 and iPad Pro
/// 13-inch: its pig's centre is the screen's centre to the pixel), so the splash's pig must be centred on the whole screen
/// too. Before Apple 325 it was centred in the safe area: 14 pt lower on an iPhone with a notch (top inset 62 pt, bottom
/// 34), which is the jump Mark saw on TestFlight 324. PIGTV_UI_TEST_SCREEN=splash keeps the splash on its settled pig.
final class SplashLaunchFrameUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The first band of rows from the top with the pig's pink in it (its ears to its feet; the name below is apart).
    private func pigBand(_ image: CGImage) -> (top: Int, bottom: Int)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func pink(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            return r > 200 && g > 90 && g < 150 && b > 150 && b < 200
        }
        // The bitmap's first row in memory is the image's top.
        func rowHasPink(_ y: Int) -> Bool { stride(from: 0, to: w, by: 2).contains { pink($0, y) } }
        guard let top = (0..<h).first(where: rowHasPink) else { return nil }
        let bottom = ((top + 1)..<h).first { !rowHasPink($0) } ?? h
        return (top, bottom - 1)
    }

    @MainActor func testTheSplashPigIsCentredOnTheWholeScreenAsTheLaunchImagesIs() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "splash"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.otherElements["Starting PigTV"].waitForExistence(timeout: 10))
        sleep(3) // the settled pig and name
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "splash-settled"; attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(shot.image.cgImage)
        let band = try XCTUnwrap(pigBand(image), "the pig is on screen")
        let pixelsPerPoint = CGFloat(image.height) / app.windows.firstMatch.frame.height
        let offset = (CGFloat(band.top + band.bottom) / 2 - CGFloat(image.height) / 2) / pixelsPerPoint
        XCTAssertEqual(offset, 0, accuracy: 1, "the pig's centre is the screen's centre, as the launch image's is (\(offset) pt off)")
    }
}
