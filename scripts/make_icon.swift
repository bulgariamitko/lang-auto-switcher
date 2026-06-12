// Generates LangAutoSwitcher/Resources/icon.tiff — the input-menu icon.
//
// Native input source icons are template images: a solid rounded rectangle
// with the glyphs punched out (transparent). macOS then tints the template
// for menu state (dark/light/selected). A bare-glyph icon renders without
// the background plate and looks foreign next to the system ones.
//
// Run: swift scripts/make_icon.swift LangAutoSwitcher/Resources/icon.tiff
import AppKit

func makeRep(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Point size stays 16×16 so the 32px rep is tagged @2x (144 dpi).
    rep.size = NSSize(width: 16, height: 16)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let scale = CGFloat(pixels) / 16.0

    // Full-bleed plate like the system "БГ"/"A" icons.
    let plate = NSRect(x: 0.5 * scale, y: 0.5 * scale,
                       width: 15 * scale, height: 15 * scale)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: plate, xRadius: 3.5 * scale, yRadius: 3.5 * scale).fill()

    // Punch the glyphs out of the plate.
    ctx.cgContext.setBlendMode(.destinationOut)
    let font = NSFont.systemFont(ofSize: 9 * scale, weight: .bold)
    let text = NSAttributedString(string: "Аб", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: (CGFloat(pixels) - size.width) / 2,
                          y: (CGFloat(pixels) - size.height) / 2 + 0.5 * scale))

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count > 1 else {
    fputs("usage: swift scripts/make_icon.swift <output.tiff>\n", stderr)
    exit(1)
}
let reps = [makeRep(pixels: 16), makeRep(pixels: 32)]
let data = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) (16px + 32px @2x)")
