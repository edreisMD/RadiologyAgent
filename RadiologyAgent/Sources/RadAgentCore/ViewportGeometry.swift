import Foundation
import CoreGraphics

/// Coordinates remain in source-image pixels, independent of zoom and display size.
public struct ViewportGeometry {
    public static func visibleCursorRect(_ rect: CGRect, within visible: CGRect) -> CGRect? {
        let clipped = rect.intersection(visible)
        guard !clipped.isNull, !clipped.isEmpty, clipped.origin.x.isFinite, clipped.origin.y.isFinite, clipped.width.isFinite, clipped.height.isFinite else { return nil }
        return clipped
    }
    public var image: CGSize
    public var viewport: CGSize
    public var zoom: Double
    public var pan: CGSize
    public init(image: CGSize, viewport: CGSize, zoom: Double = 1, pan: CGSize = .zero) {
        self.image = image; self.viewport = viewport; self.zoom = zoom; self.pan = pan
    }
    public var scale: Double {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height) * zoom
    }
    public var rect: CGRect {
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2 + pan.width, y: (viewport.height - size.height) / 2 + pan.height, width: size.width, height: size.height)
    }
    public func pixel(at point: CGPoint) -> CGPoint { CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale) }
    public func point(for pixel: CGPoint) -> CGPoint { CGPoint(x: rect.minX + pixel.x * scale, y: rect.minY + pixel.y * scale) }
    public mutating func magnify(by factor: Double, anchoredAt point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let pixel = pixel(at: point)
        zoom = min(16, max(0.1, zoom * factor))
        let moved = self.point(for: pixel)
        pan.width += point.x - moved.x; pan.height += point.y - moved.y
    }
}
