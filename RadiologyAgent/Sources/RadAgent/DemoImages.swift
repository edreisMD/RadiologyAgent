import AppKit

enum DemoImages {
    /// An original schematic, intentionally labelled. Never used as clinical evidence.
    static func chest() -> NSImage {
        let size = NSSize(width: 800, height: 800)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.015, alpha: 1).setFill(); rect.fill()
            NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.045, alpha: 1))?.draw(in: NSBezierPath(ovalIn: NSRect(x: 105, y: 15, width: 590, height: 780)), relativeCenterPosition: .zero)
            for mirror in [false, true] {
                NSGraphicsContext.saveGraphicsState()
                if mirror { let t = NSAffineTransform(); t.translateX(by: 800, yBy: 0); t.scaleX(by: -1, yBy: 1); t.concat() }
                let lung = NSBezierPath(); lung.move(to: NSPoint(x: 351, y: 699))
                lung.curve(to: NSPoint(x: 181, y: 520), controlPoint1: NSPoint(x: 277, y: 755), controlPoint2: NSPoint(x: 214, y: 654))
                lung.curve(to: NSPoint(x: 164, y: 179), controlPoint1: NSPoint(x: 150, y: 420), controlPoint2: NSPoint(x: 135, y: 214))
                lung.curve(to: NSPoint(x: 343, y: 191), controlPoint1: NSPoint(x: 220, y: 208), controlPoint2: NSPoint(x: 283, y: 153))
                lung.curve(to: NSPoint(x: 351, y: 699), controlPoint1: NSPoint(x: 377, y: 350), controlPoint2: NSPoint(x: 374, y: 581)); lung.close()
                NSGradient(starting: NSColor(white: 0.027, alpha: 1), ending: NSColor(white: 0.15, alpha: 1))?.draw(in: lung, angle: 20)
                for i in 0..<9 {
                    let y = CGFloat(640 - i * 47), rib = NSBezierPath()
                    rib.move(to: NSPoint(x: 391, y: y + 23))
                    rib.curve(to: NSPoint(x: 154 + i * 3, y: Int(y) - 40), controlPoint1: NSPoint(x: 274, y: y + 62), controlPoint2: NSPoint(x: 129, y: y + 10))
                    rib.curve(to: NSPoint(x: 323, y: y - 97), controlPoint1: NSPoint(x: 162, y: y - 89), controlPoint2: NSPoint(x: 252, y: y - 122))
                    NSColor(white: 0.63, alpha: 0.10).setStroke(); rib.lineWidth = 12; rib.stroke()
                    NSColor(white: 0.83, alpha: 0.10).setStroke(); rib.lineWidth = 4; rib.stroke()
                }
                for i in 0..<16 {
                    let vessel = NSBezierPath(); vessel.move(to: NSPoint(x: 350, y: 403))
                    vessel.curve(to: NSPoint(x: 193 + (i % 5) * 26, y: 223 + i * 27), controlPoint1: NSPoint(x: 285, y: 440), controlPoint2: NSPoint(x: 275, y: 263 + i * 27))
                    NSColor(white: 0.64, alpha: 0.065).setStroke(); vessel.lineWidth = CGFloat(1 + i % 3); vessel.stroke()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            let heart = NSBezierPath(); heart.move(to: NSPoint(x: 382, y: 490))
            heart.curve(to: NSPoint(x: 540, y: 220), controlPoint1: NSPoint(x: 457, y: 470), controlPoint2: NSPoint(x: 588, y: 291))
            heart.curve(to: NSPoint(x: 342, y: 202), controlPoint1: NSPoint(x: 489, y: 172), controlPoint2: NSPoint(x: 377, y: 179)); heart.close()
            NSGradient(starting: NSColor(white: 0.30, alpha: 0.85), ending: NSColor(white: 0.16, alpha: 0.8))?.draw(in: heart, angle: 35)
            NSColor(white: 0.025, alpha: 0.8).setFill(); NSBezierPath(roundedRect: NSRect(x: 383, y: 460, width: 26, height: 300), xRadius: 12, yRadius: 12).fill()
            let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
            ("R" as NSString).draw(at: NSPoint(x: 72, y: 664), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.60, alpha: 1)])
            ("SYNTHETIC DEMO · NOT A CLINICAL IMAGE" as NSString).draw(at: NSPoint(x: 194, y: 40), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
            return true
        }
    }
}
