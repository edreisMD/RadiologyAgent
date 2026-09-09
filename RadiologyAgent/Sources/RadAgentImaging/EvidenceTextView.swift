import AppKit
import RadAgentCore

public final class EvidenceTextView: NSTextView {
    public var references: [String: KeyImageReference] = [:]
    public var onHover: (KeyImageReference?) -> Void = { _ in }
    public var onPin: (KeyImageReference) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    private var hoveredID: String?
    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let manager = layoutManager, let container = textContainer else { return }
        for reference in references.values {
            guard let range = reference.range(in: string) else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                if let visible = ViewportGeometry.visibleCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), within: self.visibleRect) {
                    self.addCursorRect(visible, cursor: .pointingHand)
                }
            }
        }
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
        window?.acceptsMouseMovedEvents = true
    }
    func reference(at event: NSEvent) -> KeyImageReference? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs, manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -3).contains(point) else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        let link = storage.attribute(.link, at: character, effectiveRange: nil)
        guard let id = (link as? String) ?? (link as? URL)?.absoluteString else { return nil }
        return references[id]
    }
    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    public override func mouseMoved(with event: NSEvent) {
        let reference = reference(at: event)
        if reference?.id != hoveredID { hoveredID = reference?.id; onHover(reference) }
    }
    public override func cursorUpdate(with event: NSEvent) {
        (reference(at: event) != nil ? NSCursor.pointingHand : isEditable ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    public func clearHover() { guard hoveredID != nil else { return }; hoveredID = nil; onHover(nil) }
    public override func mouseExited(with event: NSEvent) { clearHover(); super.mouseExited(with: event); NSCursor.arrow.set() }
    public override func mouseDown(with event: NSEvent) {
        if let reference = reference(at: event) {
            if isEditable, event.modifierFlags.contains(.option), let manager = layoutManager, let container = textContainer {
                let local = convert(event.locationInWindow, from: nil)
                let character = manager.characterIndex(for: NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
                window?.makeFirstResponder(self); setSelectedRange(NSRange(location: character, length: 0)); clearHover()
            } else { onPin(reference) }
            return
        }
        super.mouseDown(with: event)
    }
}
