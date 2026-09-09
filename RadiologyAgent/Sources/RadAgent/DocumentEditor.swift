import SwiftUI
import AppKit
import RadAgentCore
import RadAgentImaging

struct DocumentEditor: NSViewRepresentable {
    @Binding var text: String
    var evidence: [KeyImageReference] = []
    var editable = true
    var hover: (KeyImageReference?) -> Void = { _ in }
    var pin: (KeyImageReference) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = EvidenceTextView(); view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.drawsBackground = false; view.textColor = NSColor(Theme.text); view.insertionPointColor = NSColor(Theme.text)
        view.font = NSFont.systemFont(ofSize: 14); view.textContainerInset = NSSize(width: 28, height: 24)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator; view.setAccessibilityLabel("Report document")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? EvidenceTextView else { return }
        context.coordinator.parent = self; view.isEditable = editable
        view.onHover = hover; view.onPin = pin
        view.references = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if view.string != text || context.coordinator.evidence != evidence {
            let selection = view.selectedRange()
            context.coordinator.updating = true
            view.textStorage?.setAttributedString(Self.styled(text, evidence: evidence))
            if selection.location <= (text as NSString).length { view.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, (text as NSString).length - selection.location))) }
            context.coordinator.updating = false
            context.coordinator.evidence = evidence
            view.clearHover()
            view.window?.invalidateCursorRects(for: view)
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? EvidenceTextView)?.clearHover()
        NSCursor.arrow.set()
    }
    static func styled(_ text: String, evidence: [KeyImageReference]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 6
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph])
        let ns = text as NSString
        var location = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if length > 0 && length < 85 && (trimmed.hasPrefix("#") || (trimmed == trimmed.uppercased() && trimmed.rangeOfCharacter(from: .letters) != nil)) {
                result.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(Theme.muted)], range: NSRange(location: location, length: length))
            }
            location += length + 1
        }
        var linkedPhrases: Set<String> = []
        for reference in evidence {
            guard linkedPhrases.insert(reference.phrase).inserted else { continue }
            guard let range = reference.range(in: text), NSMaxRange(range) <= ns.length else { continue }
            result.addAttributes([.link: reference.id, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemTeal.withAlphaComponent(0.45)], range: range)
        }
        return result
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentEditor
        var evidence: [KeyImageReference] = []
        var updating = false
        init(_ parent: DocumentEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let id = (link as? String) ?? (link as? URL)?.absoluteString
            if let reference = parent.evidence.first(where: { $0.id == id }) { parent.pin(reference) }
            return true
        }
    }
}
