import Cocoa

// Generates a macOS .iconset using an SF Symbol.
// Usage:
//   swift scripts/generate_icon.swift
//   iconutil -c icns Barista.iconset

let appName = "Barista"
let symbolName = "cup.and.saucer.fill"
let outputFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Barista.iconset")

// Some AppKit drawing (including SF Symbols) behaves better if NSApplication is initialized.
_ = NSApplication.shared

let fileManager = FileManager.default
try? fileManager.removeItem(at: outputFolder)
try? fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)

// Standard macOS icon sizes
let sizes = [16, 32, 64, 128, 256, 512, 1024]

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

private func drawRoundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func savePNG(_ image: NSImage, to url: URL) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else { return }
    try? pngData.write(to: url)
}

private func makeMaskCGImage(from image: NSImage, size: NSSize) -> CGImage? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    return rep.cgImage
}

func generateIcon(size: Int, scale: Int) {
    let pixelSize = size * scale
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let cornerRadius = CGFloat(pixelSize) * 0.235
    let bgPath = drawRoundedRect(rect, radius: cornerRadius)

    // Flat background
    NSColor(calibratedRed: 0.36, green: 0.23, blue: 0.16, alpha: 1.0).setFill()
    bgPath.fill()

    // Subtle border (still flat)
    NSColor(white: 1.0, alpha: 0.12).setStroke()
    let border = drawRoundedRect(rect.insetBy(dx: 1, dy: 1), radius: cornerRadius * 0.96)
    border.lineWidth = clamp(CGFloat(pixelSize) * 0.006, 1.0, 6.0)
    border.stroke()

    // SF Symbol glyph
    let s = CGFloat(pixelSize)
    let pointSize = s * 0.62
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbolBase = NSImage(systemSymbolName: symbolName, accessibilityDescription: appName)?.withSymbolConfiguration(config) else {
        image.unlockFocus()
        return
    }

    // Draw symbol centered
    let glyphColor = NSColor(white: 1.0, alpha: 0.92)
    let drawSize = NSSize(width: pointSize, height: pointSize)
    let drawRect = NSRect(
        x: (s - drawSize.width) / 2,
        y: (s - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )

    // Render as a mask + fill, to avoid cases where SF Symbols draw as a solid block in scripts.
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()

        // Create a mask at the target draw size.
        if let maskImage = makeMaskCGImage(from: symbolBase, size: drawRect.size) {
            // Clip to the symbol alpha mask.
            ctx.clip(to: drawRect, mask: maskImage)
            ctx.setFillColor(glyphColor.cgColor)
            ctx.fill(drawRect)
        } else {
            // Fallback: just draw it.
            symbolBase.draw(in: drawRect)
        }

        ctx.restoreGState()
    } else {
        symbolBase.draw(in: drawRect)
    }
    
    image.unlockFocus()

    let filename = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@\(scale)x.png"
    let url = outputFolder.appendingPathComponent(filename)
    savePNG(image, to: url)
}

// Generate all sizes
for size in sizes {
    generateIcon(size: size, scale: 1)
    generateIcon(size: size, scale: 2)
}

print("Generated iconset at \(outputFolder.path)")
print("Run 'iconutil -c icns Barista.iconset' to create AppIcon.icns")
