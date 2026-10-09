// Renders the LaunchBrand images: the pig's static halo (an alpha radial gradient) with mark.svg on top, on a TRANSPARENT
// background, so the launch screen's LaunchEdge colour shows through and no seam can appear at the image edges.
//
// Not run by hand: Tools/sync-brand.sh compiles it together with PigTV/BrandLayout.swift (the same numbers the SwiftUI
// splash uses) and runs it:
//   <tmp>/main.swift is a copy of this file (swiftc wants top-level code in main.swift)
//   swiftc -O PigTV/BrandLayout.swift <tmp>/main.swift -o <tmp>/render-launch
//   <tmp>/render-launch <mark.svg> <LaunchBrand.imageset>
//
// Sizes follow the old LaunchBrand: tv @2x, phone @2x and @3x. The layout square S is 1080 pt on tvOS, 600 pt elsewhere
// (BrandSplashView.side); the image is BrandLayout.launchSide x S points, exactly the halo's bounding square.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-launch: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: render-launch <mark.svg> <LaunchBrand.imageset>") }
let markPath = args[1]
let outDir = args[2]
guard let mark = NSImage(contentsOfFile: markPath) else { fail("cannot read \(markPath)") }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [BrandLayout.Stop]) -> CGGradient {
    let comps = stops.flatMap { [CGFloat($0.r / 255), CGFloat($0.g / 255), CGFloat($0.b / 255), CGFloat($0.a)] }
    return CGGradient(colorSpace: srgb, colorComponents: comps, locations: stops.map { CGFloat($0.at) }, count: stops.count)!
}

/// side: the layout square S in points; scale: 2 or 3.
func render(side: Double, scale: Double, dark: Bool) -> CGImage {
    let px = Int((BrandLayout.launchSide * side * scale / 2).rounded()) * 2
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let centre = CGPoint(x: Double(px) / 2, y: Double(px) / 2)
    let radius = Double(BrandLayout.haloRadius) * side * scale
    ctx.drawRadialGradient(gradient(BrandLayout.halo(dark: dark)), startCenter: centre, startRadius: 0,
                           endCenter: centre, endRadius: radius, options: [])
    let m = Double(BrandLayout.markSide) * side * scale
    let rect = NSRect(x: centre.x - m / 2, y: centre.y - m / 2, width: m, height: m)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(path)") }
}

// (file stem, idiom, scale, layout square in points)
let variants: [(String, String, Int, Double)] = [("tv@2x", "tv", 2, 1080), ("phone@2x", "universal", 2, 600), ("phone@3x", "universal", 3, 600)]
var entries: [String] = []
for (stem, idiom, scale, side) in variants {
    for dark in [false, true] {
        let file = dark ? "\(stem)-dark.png" : "\(stem).png"
        write(render(side: side, scale: Double(scale), dark: dark), to: "\(outDir)/\(file)")
        let appearance = dark ? "\n      \"appearances\" : [\n        {\n          \"appearance\" : \"luminosity\",\n          \"value\" : \"dark\"\n        }\n      ],": ""
        entries.append("    {\(appearance)\n      \"filename\" : \"\(file)\",\n      \"idiom\" : \"\(idiom)\",\n      \"scale\" : \"\(scale)x\"\n    }")
    }
}
let json = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
try! json.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
