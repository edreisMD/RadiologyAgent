import XCTest
import AppKit
import RadAgentCore
@testable import RadAgentImaging

final class ViewportTests: XCTestCase {
    func testOffscreenReportLinkNeverCreatesInfiniteCursorRectangle() {
        let visible = CGRect(x: 0, y: 0, width: 600, height: 300)
        XCTAssertNil(ViewportGeometry.visibleCursorRect(CGRect(x: 30, y: 900, width: 200, height: 20), within: visible))
        XCTAssertNil(ViewportGeometry.visibleCursorRect(.null, within: visible))
        XCTAssertEqual(ViewportGeometry.visibleCursorRect(CGRect(x: 30, y: 290, width: 200, height: 20), within: visible), CGRect(x: 30, y: 290, width: 200, height: 10))
    }
    func testZoomPreservesPixelUnderPointer() {
        var geometry = ViewportGeometry(image: CGSize(width: 2048, height: 1024), viewport: CGSize(width: 600, height: 400), pan: CGSize(width: 18, height: -12))
        let anchor = CGPoint(x: 310, y: 170), before = geometry.pixel(at: CGPoint(x: 310, y: 170))
        geometry.magnify(by: 2.7, anchoredAt: anchor)
        let after = geometry.pixel(at: anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 0.0001); XCTAssertEqual(before.y, after.y, accuracy: 0.0001)
        let point = geometry.point(for: before)
        XCTAssertEqual(point.x, anchor.x, accuracy: 0.0001)
    }
    func testZoomRejectsInvalidAndBoundsExtremeGestures() {
        var geometry = ViewportGeometry(image: CGSize(width: 100, height: 100), viewport: CGSize(width: 300, height: 200))
        geometry.magnify(by: .nan, anchoredAt: .zero); XCTAssertEqual(geometry.zoom, 1)
        geometry.magnify(by: 1000, anchoredAt: .zero); XCTAssertEqual(geometry.zoom, 16)
        geometry.magnify(by: 0.00001, anchoredAt: .zero); XCTAssertEqual(geometry.zoom, 0.1)
    }
    @MainActor func config(series: String = "series-a", imageID: String = "frame-1", preview: Bool = false, tool: ViewerTool = .window, step: @escaping (Int) -> Void = { _ in }) -> DICOMViewport {
        _ = NSApplication.shared
        return DICOMViewport(image: NSImage(size: CGSize(width: 1000, height: 1000)), imageID: imageID, seriesID: series, tool: tool, zoom: 2, resetID: 0, width: 400, center: 40, inverted: false, previewing: preview, onZoom: { _ in }, onWindow: { _, _ in }, onStep: step, onTool: { _ in }, onReset: {}, onInvert: {})
    }
    @MainActor func testPanPersistsAcrossSlicesButClearsForDifferentSeries() async {
        let canvas = DICOMCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        canvas.configure(config()); canvas.pan = CGSize(width: 30, height: 20)
        canvas.configure(config(imageID: "frame-2")); XCTAssertEqual(canvas.pan, CGSize(width: 30, height: 20))
        canvas.configure(config(series: "series-b")); XCTAssertEqual(canvas.pan, .zero)
    }
    @MainActor func testPreviewDoesNotChangePinnedPresentation() async {
        let canvas = DICOMCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        canvas.configure(config()); canvas.pan = CGSize(width: 30, height: 20)
        canvas.configure(config(preview: true)); XCTAssertEqual(canvas.geometry.zoom, 1); XCTAssertEqual(canvas.geometry.pan, .zero)
        canvas.magnify(by: 2, at: CGPoint(x: 200, y: 200)); XCTAssertEqual(canvas.localZoom, 2)
        canvas.configure(config()); XCTAssertEqual(canvas.pan, CGSize(width: 30, height: 20))
    }
    @MainActor func testCursorsReflectImagingToolAndPreview() async {
        let canvas = DICOMCanvas(); canvas.configure(config(tool: .pan)); XCTAssertEqual(canvas.cursor, NSCursor.openHand)
        canvas.configure(config(tool: .window)); XCTAssertEqual(canvas.cursor, NSCursor.crosshair)
        canvas.configure(config(preview: true)); XCTAssertEqual(canvas.cursor, NSCursor.arrow)
    }
    @MainActor func testArrowKeysOnlyNavigateFocusedViewport() async throws {
        var steps = [Int]()
        let canvas = DICOMCanvas(); canvas.configure(config(step: { steps.append($0) }))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        canvas.keyDown(with: event); XCTAssertEqual(steps, [1])
        canvas.spaceHeld = true; _ = canvas.resignFirstResponder(); XCTAssertFalse(canvas.spaceHeld)
    }
}

final class EvidenceInteractionTests: XCTestCase {
    func testHoverFindsLinkedGlyphAndExitClearsPreview() throws {
        try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let view = EvidenceTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let reference = KeyImageReference(phrase: "Linked observation", imageID: "synthetic-image", imageIndex: 0, studyUID: "1.2.3", windowWidth: 400, windowCenter: 40)
        view.references = [reference.id: reference]
        view.textStorage?.setAttributedString(NSAttributedString(string: "Linked observation", attributes: [.font: NSFont.systemFont(ofSize: 14), .link: reference.id]))
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let glyph = manager.boundingRect(forGlyphRange: NSRange(location: 3, length: 1), in: container)
        let point = view.convert(CGPoint(x: glyph.midX + view.textContainerOrigin.x, y: glyph.midY + view.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        var hovered: String?, updates = 0
        view.onHover = { hovered = $0?.id; updates += 1 }
        view.mouseMoved(with: event); XCTAssertEqual(hovered, reference.id)
        view.mouseMoved(with: event); XCTAssertEqual(updates, 1)
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseExited(with: exit); XCTAssertNil(hovered); XCTAssertEqual(updates, 2)
        view.clearHover(); XCTAssertEqual(updates, 2)
        }
    }
}
