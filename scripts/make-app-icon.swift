// Renders the app icon: the menu bar's "waveform" SF Symbol in the overlay's
// neon gradient on a dark macOS squircle, then writes every AppIcon size.
// Run: swift scripts/make-app-icon.swift
import AppKit
import SwiftUI

let cyan = Color(red: 0, green: 1.0, blue: 0.969)
let magenta = Color(red: 1.0, green: 0.169, blue: 0.839)
let violet = Color(red: 0.478, green: 0.169, blue: 1.0)
let gradient = LinearGradient(colors: [cyan, magenta, violet], startPoint: .leading, endPoint: .trailing)

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824 pt squircle centered on a 1024 pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.07, blue: 0.20), Color(red: 0.03, green: 0.02, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(gradient.opacity(0.55), lineWidth: 6)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            let symbol = Image(systemName: "waveform")
                .font(.system(size: 470, weight: .semibold))
            // Glow underneath, crisp symbol on top.
            symbol.foregroundStyle(gradient).blur(radius: 28).opacity(0.8)
            symbol.foregroundStyle(gradient)
        }
        .frame(width: 1024, height: 1024)
    }
}

let outDir = URL(fileURLWithPath: "Sources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let cgImage = MainActor.assumeIsolated { () -> CGImage in
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("render failed") }
    return image
}

func png(_ image: CGImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(cgImage, size: pixels).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!
    .write(to: outDir.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(outDir.path)")
