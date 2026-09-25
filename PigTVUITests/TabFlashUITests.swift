import XCTest

#if os(tvOS)
// Build 32 (Mark, on device: "a white flash when moving between the top
// tabs"). On the offline Home fixture, in dark and then light appearance,
// moves along the tab bar Home → Guide → Sport → Recordings → Settings and
// back while taking screenshots as fast as XCUITest allows (roughly every
// 60–150 ms) for about a second after each press. Each screenshot is
// reduced to a 32×18 grid and the share of cells in the wrong page colour
// is measured: near-white cells in dark mode, near-black or mid-grey cells
// in light mode. A tab-switch flash fills most of the screen, so any frame
// over half wrong fails. Screenshots cannot see every display frame; the
// build 32 notes in blueprint.md also describe a 60 fps simctl recording
// of this test analysed frame by frame.
final class TabFlashUITests: XCTestCase {
    @MainActor
    func testSwitchingTabsNeverShowsTheWrongPageColour() throws {
        for mode in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
            app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = mode
            app.launch()
            XCTAssertTrue(app.buttons["home.watch"].waitForExistence(timeout: 15))
            // Let the first page settle (logos, hero wash).
            Thread.sleep(forTimeInterval: 1.5)
            var worst: (share: Double, label: String) = (0, "")
            var frames = 0
            var shot = 0
            let presses: [XCUIRemote.Button] = Array(repeating: .right, count: 4) + Array(repeating: .left, count: 4)
            for (step, button) in presses.enumerated() {
                XCUIRemote.shared.press(button)
                let start = Date()
                while Date().timeIntervalSince(start) < 1.0 {
                    let screenshot = XCUIScreen.main.screenshot()
                    frames += 1
                    let share = Self.wrongShare(screenshot.image, dark: mode == "dark")
                    if share > worst.share {
                        worst = (share, "\(mode) step \(step + 1) +\(Int(Date().timeIntervalSince(start) * 1000)) ms")
                        shot += 1
                        let attachment = XCTAttachment(screenshot: screenshot)
                        attachment.name = String(format: "%@ worst so far %.0f%%", worst.label, share * 100)
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
            print(String(format: "TABFLASH %@: %d screenshots, worst %.0f%% wrong-colour cells (%@)",
                         mode, frames, worst.share * 100, worst.label))
            XCTAssertLessThan(worst.share, 0.5, "A \(mode)-mode tab switch showed a frame in the wrong page colour: \(worst.label)")
            app.terminate()
        }
    }

    /// The share of a coarse grid's cells in the wrong page colour.
    static func wrongShare(_ image: UIImage, dark: Bool) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var wrong = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]), g = Double(pixels[index + 1]), b = Double(pixels[index + 2])
            let luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            let grey = max(r, g, b) - min(r, g, b) < 24
            if dark ? (luma > 0.85 && grey) : (luma < 0.75 && grey) { wrong += 1 }
        }
        return Double(wrong) / Double(width * height)
    }
}
#endif
