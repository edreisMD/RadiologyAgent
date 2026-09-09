import AppKit
import SwiftUI
import CoreImage
import RadAgentCore

public enum ViewerTool: String, CaseIterable, Identifiable {
    case window = "Window / level", pan = "Pan", zoom = "Zoom", stack = "Scroll series"
    public var id: String { rawValue }
    public var symbol: String { switch self { case .window: "circle.lefthalf.filled"; case .pan: "hand.draw"; case .zoom: "plus.magnifyingglass"; case .stack: "square.stack.3d.up" } }
    public var shortcut: String { switch self { case .window: "W"; case .pan: "P"; case .zoom: "Z"; case .stack: "S" } }
    var cursor: NSCursor { switch self { case .pan: .openHand; case .window, .zoom: .crosshair; case .stack: .resizeUpDown } }
}

public struct DICOMViewport: NSViewRepresentable {
    public var image: NSImage?
    public var imageID: String
    public var seriesID: String
    public var tool: ViewerTool
    public var zoom: Double
    public var resetID: Int
    public var width: Double
    public var center: Double
    public var inverted: Bool
    public var previewing: Bool
    public var onZoom: (Double) -> Void
    public var onWindow: (Double, Double) -> Void
    public var onStep: (Int) -> Void
    public var onTool: (ViewerTool) -> Void
    public var onReset: () -> Void
    public var onInvert: () -> Void
    public var onOpenNative: (() -> Void)?
    public init(image: NSImage?, imageID: String, seriesID: String, tool: ViewerTool, zoom: Double, resetID: Int, width: Double, center: Double, inverted: Bool, previewing: Bool, onZoom: @escaping (Double) -> Void, onWindow: @escaping (Double, Double) -> Void, onStep: @escaping (Int) -> Void, onTool: @escaping (ViewerTool) -> Void, onReset: @escaping () -> Void, onInvert: @escaping () -> Void, onOpenNative: (() -> Void)? = nil) {
        self.image = image; self.imageID = imageID; self.seriesID = seriesID; self.tool = tool; self.zoom = zoom; self.resetID = resetID; self.width = width; self.center = center; self.inverted = inverted; self.previewing = previewing; self.onZoom = onZoom; self.onWindow = onWindow; self.onStep = onStep; self.onTool = onTool; self.onReset = onReset; self.onInvert = onInvert; self.onOpenNative = onOpenNative
    }
    public func makeNSView(context: Context) -> NSView { DICOMCanvas() }
    public func updateNSView(_ view: NSView, context: Context) { (view as? DICOMCanvas)?.configure(self) }
}

/// Owns events only inside this viewport; no application-wide mouse or keyboard monitors.
final class DICOMCanvas: NSView {
    var configuration: DICOMViewport?
    var pan = CGSize.zero
    var localZoom: Double = 1
    var dragStart: CGPoint?
    var dragPan = CGSize.zero
    var dragZoom: Double = 1
    var dragWidth: Double = 400
    var dragCenter: Double = 40
    var draggingTool: ViewerTool?
    var stackSteps = 0
    var scrollRemainder: Double = 0
    var spaceHeld = false
    private var tracking: NSTrackingArea?
    private var invertedImage: NSImage?
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: ViewportGeometry {
        ViewportGeometry(image: configuration?.image?.size ?? .zero, viewport: bounds.size, zoom: configuration?.previewing == true ? 1 : localZoom, pan: configuration?.previewing == true ? .zero : pan)
    }
    func configure(_ next: DICOMViewport) {
        let previous = configuration
        if previous?.seriesID != next.seriesID || previous?.resetID != next.resetID { pan = .zero; scrollRemainder = 0 }
        if previous?.image !== next.image || previous?.inverted != next.inverted {
            invertedImage = nil
            if next.inverted, let image = next.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ci = CIImage(cgImage: cg).applyingFilter("CIColorInvert")
                if let output = Self.ciContext.createCGImage(ci, from: ci.extent) { invertedImage = NSImage(cgImage: output, size: image.size) }
            }
        }
        configuration = next; localZoom = next.zoom
        if previous?.tool != next.tool || previous?.previewing != next.previewing { window?.invalidateCursorRects(for: self) }
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("DICOM image viewport")
        setAccessibilityHelp("Drag to \(next.tool.rawValue.lowercased()). Scroll to change image, pinch to zoom, double-click to \(next.onOpenNative == nil ? "fit" : "open this series in Horos"). Right-drag adjusts window and level.")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image = configuration?.image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        (invertedImage ?? image).draw(in: geometry.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    var cursor: NSCursor {
        guard configuration?.image != nil, configuration?.previewing != true else { return .arrow }
        if spaceHeld { return dragStart == nil ? .openHand : .closedHand }
        if draggingTool == .pan { return .closedHand }
        return configuration?.tool.cursor ?? .arrow
    }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: cursor) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .cursorUpdate, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    func begin(_ event: NSEvent, override: ViewerTool? = nil) {
        guard let config = configuration, config.image != nil, !config.previewing else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 && event.buttonNumber == 0 {
            if let open = config.onOpenNative { open() } else { reset() }; return
        }
        dragStart = convert(event.locationInWindow, from: nil); dragPan = pan; dragZoom = localZoom; dragWidth = config.width; dragCenter = config.center; stackSteps = 0
        draggingTool = override ?? (spaceHeld ? .pan : event.modifierFlags.contains(.option) ? .zoom : config.tool)
        cursor.set()
    }
    override func mouseDown(with event: NSEvent) { begin(event) }
    override func rightMouseDown(with event: NSEvent) { begin(event, override: .window) }
    override func otherMouseDown(with event: NSEvent) { begin(event, override: .pan) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let config = configuration else { return }
        let point = convert(event.locationInWindow, from: nil), dx = point.x - start.x, dy = point.y - start.y
        switch draggingTool {
        case .pan: pan = CGSize(width: dragPan.width + dx, height: dragPan.height + dy)
        case .zoom:
            var transform = ViewportGeometry(image: config.image?.size ?? .zero, viewport: bounds.size, zoom: dragZoom, pan: dragPan)
            transform.magnify(by: exp(-dy / 180), anchoredAt: start)
            localZoom = transform.zoom; pan = transform.pan; config.onZoom(localZoom)
        case .window:
            let sensitivity = max(1, dragWidth / 300)
            config.onWindow(min(1_000_000, max(1, dragWidth + dx * sensitivity)), min(1_000_000, max(-1_000_000, dragCenter + dy * sensitivity)))
        case .stack:
            let steps = Int(dy / 12)
            if steps != stackSteps { config.onStep(steps - stackSteps); stackSteps = steps }
        case nil: break
        }
        needsDisplay = true
    }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { dragStart = nil; draggingTool = nil; cursor.set(); window?.invalidateCursorRects(for: self) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) {
        guard let config = configuration, config.image != nil, !config.previewing else { return }
        if event.modifierFlags.contains(.command) { magnify(by: exp(event.scrollingDeltaY / 100), at: convert(event.locationInWindow, from: nil)); return }
        if event.modifierFlags.contains(.shift) { pan.width += event.scrollingDeltaX; pan.height += event.scrollingDeltaY; needsDisplay = true; return }
        if event.phase == .began { scrollRemainder = 0 }
        scrollRemainder += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1.0 / 12 : 1)
        let steps = Int(scrollRemainder)
        if steps != 0 { scrollRemainder -= Double(steps); config.onStep(-steps) }
    }
    func magnify(by factor: Double, at point: CGPoint) {
        guard configuration?.previewing != true else { return }
        var transform = geometry; transform.magnify(by: factor, anchoredAt: point)
        localZoom = transform.zoom; pan = transform.pan; configuration?.onZoom(localZoom); needsDisplay = true
    }
    override func magnify(with event: NSEvent) { magnify(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }
    func reset() { pan = .zero; localZoom = 1; configuration?.onReset(); needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: configuration?.onStep(-1)
        case 124, 125: configuration?.onStep(1)
        case 49: spaceHeld = true; window?.invalidateCursorRects(for: self); cursor.set()
        case 53: dragStart = nil; draggingTool = nil; spaceHeld = false; cursor.set()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": configuration?.onTool(.window)
            case "p": configuration?.onTool(.pan)
            case "z": configuration?.onTool(.zoom)
            case "s": configuration?.onTool(.stack)
            case "f": reset()
            case "i": configuration?.onInvert()
            default: super.keyDown(with: event)
            }
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self); cursor.set() } else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool { spaceHeld = false; dragStart = nil; draggingTool = nil; return super.resignFirstResponder() }
}
