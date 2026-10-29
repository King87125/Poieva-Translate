import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let markURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Design/poieva-mark.svg")
guard let mark = NSImage(contentsOf: markURL) else { fatalError("Could not load the Poieva vector mark") }
mark.size = NSSize(width: 1024, height: 1024)

func icon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high
    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 198, yRadius: 198)
    // A white surface stays distinct on a white Finder window through its rim
    // and restrained shadow. The glyph remains a shared, editable vector asset.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.12, alpha: 0.15)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 22
    shadow.set()
    NSColor.white.setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(starting: .white,
        ending: NSColor(red: 0.965, green: 0.973, blue: 0.994, alpha: 1))!
    gradient.draw(in: background, angle: -90)
    NSColor(calibratedWhite: 0, alpha: 0.065).setStroke()
    background.lineWidth = 2
    background.stroke()
    mark.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try icon(base).write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base).png"))
    try icon(base * 2).write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base)@2x.png"))
}

// ICNS is a length-prefixed container of PNG representations. Packaging it here
// also works on Command Line Tools-only machines without iconutil's GUI services.
func bigEndianData(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var payload = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let png = icon(pixels)
    payload.append(Data(type.utf8))
    payload.append(bigEndianData(UInt32(png.count + 8)))
    payload.append(png)
}
var container = Data("icns".utf8)
container.append(bigEndianData(UInt32(payload.count + 8)))
container.append(payload)
try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
