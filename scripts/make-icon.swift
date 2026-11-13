// Renders the Ember Mail app icon and writes an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centred in 1024.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Deep oak background
    let bg = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.19, blue: 0.12, alpha: 1),
        NSColor(red: 0.13, green: 0.085, blue: 0.06, alpha: 1),
    ], atLocations: [0, 1], colorSpace: .deviceRGB)!
    bg.draw(in: path, angle: -80)

    // Soft ember glow behind the flame
    let glow = NSGradient(colors: [
        NSColor(red: 0.95, green: 0.45, blue: 0.18, alpha: 0.38),
        NSColor(red: 0.95, green: 0.45, blue: 0.18, alpha: 0),
    ])!
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    glow.draw(fromCenter: NSPoint(x: 512 * s, y: 450 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 450 * s), radius: 400 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // Geometry is authored y-down in a 1024 box (same as docs/brand/ember-mail-logo.svg); flip into AppKit space.
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: (1024 - y) * s) }

    // Flame
    let flame = NSBezierPath()
    flame.move(to: P(512, 196))
    flame.curve(to: P(706, 548), controlPoint1: P(560, 300), controlPoint2: P(706, 380))
    flame.curve(to: P(512, 810), controlPoint1: P(706, 680), controlPoint2: P(624, 770))
    flame.curve(to: P(318, 548), controlPoint1: P(400, 770), controlPoint2: P(318, 680))
    flame.curve(to: P(402, 372), controlPoint1: P(318, 470), controlPoint2: P(352, 420))
    flame.curve(to: P(468, 500), controlPoint1: P(402, 430), controlPoint2: P(428, 482))
    flame.curve(to: P(512, 196), controlPoint1: P(430, 380), controlPoint2: P(452, 270))
    flame.close()
    let fire = NSGradient(colors: [
        NSColor(red: 1.00, green: 0.78, blue: 0.36, alpha: 1),
        NSColor(red: 0.98, green: 0.52, blue: 0.20, alpha: 1),
        NSColor(red: 0.86, green: 0.32, blue: 0.14, alpha: 1),
    ], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
    fire.draw(in: flame, angle: -90)

    // Envelope flap cut into the flame
    let flap = NSBezierPath()
    flap.move(to: P(372, 590))
    flap.line(to: P(512, 692))
    flap.line(to: P(652, 590))
    flap.lineWidth = 42 * s
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    NSColor(red: 0.16, green: 0.10, blue: 0.07, alpha: 1).setStroke()
    flap.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EmberMail-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
