// Draws the app icon and writes a 1024px PNG. Usage: swift Scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: Int, _ alpha: Double = 1) -> NSColor {
    NSColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824pt tile centred in 1024 with ~185pt corner radius.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [rgb(0x16233F), rgb(0x070B14)])!.draw(in: tilePath, angle: -90)
rgb(0x22D3EE, 0.25).setStroke()
tilePath.lineWidth = 4
tilePath.stroke()

let center = NSPoint(x: 512, y: 512)
let accent = rgb(0x22D3EE)

// Range rings.
for (radius, alpha) in [(150.0, 0.35), (265.0, 0.18)] {
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    accent.withAlphaComponent(alpha).setStroke()
    ring.lineWidth = 6
    ring.stroke()
}

// Satellite nodes: (angle°, distance, node radius).
let nodes: [(Double, Double, Double)] = [(90, 265, 38), (18, 265, 30), (-54, 265, 38), (-126, 265, 30), (162, 265, 34), (-170, 150, 22), (50, 150, 22)]
let points = nodes.map { NSPoint(x: center.x + cos($0.0 * .pi / 180) * $0.1, y: center.y + sin($0.0 * .pi / 180) * $0.1) }

accent.withAlphaComponent(0.7).setStroke()
for point in points {
    let link = NSBezierPath()
    link.move(to: center)
    link.line(to: point)
    link.lineWidth = 10
    link.stroke()
}
for (point, node) in zip(points, nodes) {
    let r = node.2
    let dot = NSBezierPath(ovalIn: NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    rgb(0x0B1220).setFill(); dot.fill()
    accent.setStroke(); dot.lineWidth = 10; dot.stroke()
}

// Hub.
let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 78, y: center.y - 78, width: 156, height: 156))
NSGradient(colors: [rgb(0x67E8F9), rgb(0x0891B2)])!.draw(in: hub, angle: -90)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
