import AppKit

// Draws the app icon: two overlapping pages with struck-through red and underlined green lines.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.22, blue: 0.38, alpha: 1),
           ending: NSColor(srgbRed: 0.08, green: 0.11, blue: 0.2, alpha: 1))!.draw(in: bg, angle: -90)

func page(_ r: NSRect, _ fill: NSColor) {
    let p = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -10)
    sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.set()
    fill.setFill(); p.fill()
    NSGraphicsContext.restoreGraphicsState()
}
page(NSRect(x: 215, y: 260, width: 400, height: 520), NSColor(white: 0.86, alpha: 1))
page(NSRect(x: 395, y: 210, width: 420, height: 560), .white)

let grey = NSColor(white: 0.78, alpha: 1)
let red = NSColor(srgbRed: 0.88, green: 0.2, blue: 0.2, alpha: 1)
let green = NSColor(srgbRed: 0.12, green: 0.66, blue: 0.32, alpha: 1)
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor) {
    c.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 26), xRadius: 13, yRadius: 13).fill()
}
var y: CGFloat = 690
for (w, kind) in [(330, 0), (280, 1), (300, 0), (250, 2), (320, 0), (210, 0)] as [(CGFloat, Int)] {
    switch kind {
    case 1:
        bar(445, y, w, red.withAlphaComponent(0.25))
        red.setFill(); NSRect(x: 440, y: y + 10, width: w + 10, height: 7).fill()
    case 2:
        bar(445, y, w, green.withAlphaComponent(0.28))
        green.setFill(); NSRect(x: 445, y: y - 10, width: w, height: 8).fill()
    default:
        bar(445, y, w, grey)
    }
    y -= 72
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
