// Renders the Limevert app icon (a lime slice on a rounded tile) into an .iconset folder.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.20, blue: 0.12, alpha: 1),
               ending: NSColor(srgbRed: 0.06, green: 0.08, blue: 0.05, alpha: 1))!.draw(in: tilePath, angle: -90)
    let c = NSPoint(x: s / 2, y: s / 2)
    func disk(_ r: CGFloat, _ color: NSColor) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    let R = s * 0.3
    let pith = NSColor(srgbRed: 0.93, green: 0.98, blue: 0.80, alpha: 1)
    disk(R, NSColor(srgbRed: 0.33, green: 0.62, blue: 0.10, alpha: 1))
    disk(R * 0.9, pith)
    for i in 0..<8 {
        let a0 = CGFloat(i) * 45 + 3, a1 = CGFloat(i + 1) * 45 - 3
        let p = NSBezierPath()
        p.move(to: c)
        p.appendArc(withCenter: c, radius: R * 0.8, startAngle: a0, endAngle: a1)
        p.close()
        NSGradient(starting: NSColor(srgbRed: 0.72, green: 0.90, blue: 0.30, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.80, blue: 0.18, alpha: 1))!.draw(in: p, relativeCenterPosition: .zero)
    }
    disk(R * 0.08, pith)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
