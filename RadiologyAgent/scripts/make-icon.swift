import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), cornerWidth: 194, cornerHeight: 194, transform: nil)
    context.addPath(background); context.setFillColor(CGColor(red: 0.075, green: 0.105, blue: 0.105, alpha: 1)); context.fillPath()
    context.addPath(background); context.setStrokeColor(CGColor(red: 0.23, green: 0.34, blue: 0.29, alpha: 1)); context.setLineWidth(5); context.strokePath()
    context.setStrokeColor(CGColor(red: 0.67, green: 0.89, blue: 0.76, alpha: 1)); context.setLineWidth(37); context.setLineCap(.round); context.setLineJoin(.round)
    for (x, y, dx, dy) in [(310.0, 310.0, 1.0, 1.0), (714.0, 310.0, -1.0, 1.0), (310.0, 714.0, 1.0, -1.0), (714.0, 714.0, -1.0, -1.0)] {
        context.move(to: CGPoint(x: x + 110 * dx, y: y)); context.addLine(to: CGPoint(x: x + 20 * dx, y: y)); context.addQuadCurve(to: CGPoint(x: x, y: y + 20 * dy), control: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x, y: y + 110 * dy)); context.strokePath()
    }
    context.setFillColor(CGColor(red: 0.67, green: 0.89, blue: 0.76, alpha: 1))
    context.fillEllipse(in: CGRect(x: 483, y: 483, width: 58, height: 58))
    let image = context.makeImage()!
    let url = root.appendingPathComponent(name + ".png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
