import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = folder.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.21, yRadius: p * 0.21).fill()
        for (index, color) in [NSColor(calibratedRed: 0.32, green: 0.79, blue: 0.65, alpha: 1), NSColor(calibratedRed: 0.86, green: 0.57, blue: 0.43, alpha: 1)].enumerated() {
            let y = p * (index == 0 ? 0.56 : 0.32)
            color.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: p * 0.23, y: y, width: p * 0.54, height: p * 0.12), xRadius: p * 0.06, yRadius: p * 0.06).fill()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: p * 0.23, y: y, width: p * (index == 0 ? 0.42 : 0.30), height: p * 0.12), xRadius: p * 0.06, yRadius: p * 0.06).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
func bigEndian(_ number: Int) -> Data {
    var value = UInt32(number).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (tag, name) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
                    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
                    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
                    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")] {
    let png = try Data(contentsOf: iconset.appendingPathComponent(name))
    chunks.append(Data(tag.utf8)); chunks.append(bigEndian(png.count + 8)); chunks.append(png)
}
var container = Data("icns".utf8)
container.append(bigEndian(chunks.count + 8)); container.append(chunks)
try container.write(to: folder.appendingPathComponent("AppIcon.icns"))
try FileManager.default.removeItem(at: iconset)
