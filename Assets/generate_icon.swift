import AppKit

// Draws the 1024x1024 app icon master PNG. Usage: swift generate_icon.swift <output.png>

let canvas = 1024
guard CommandLine.arguments.count > 1 else {
    fputs("usage: swift generate_icon.swift <output.png>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's app-icon grid: 824pt squircle centered on a 1024pt canvas.
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(
    starting: NSColor(red: 0.76, green: 0.36, blue: 0.21, alpha: 1.0),
    ending: NSColor(red: 0.93, green: 0.60, blue: 0.42, alpha: 1.0)
)!
gradient.draw(in: bgPath, angle: 90)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()

NSColor.white.setFill()
let barWidth: CGFloat = 124
let gap: CGFloat = 76
let heights: [CGFloat] = [240, 364, 488]
let startX = (CGFloat(canvas) - (barWidth * 3 + gap * 2)) / 2
let baseY = (CGFloat(canvas) - heights.max()!) / 2
for (index, height) in heights.enumerated() {
    let rect = NSRect(
        x: startX + CGFloat(index) * (barWidth + gap),
        y: baseY,
        width: barWidth,
        height: height
    )
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print(outputPath)
