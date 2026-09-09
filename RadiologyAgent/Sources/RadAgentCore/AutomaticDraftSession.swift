import AppKit

/// An immutable study context with its own tool state. It has no reference to the UI,
/// current selection, report editor, or viewer, and returns a candidate atomically.
@MainActor public final class AutomaticDraftSession {
    public static var tools: [[String: Any]] {
        AgentClient.tools.filter { $0["name"] as? String != "write_draft" } + [
            AgentClient.function("view_images", "Review up to 12 consecutive or selected DICOM frames at their global indices. Each image is labeled separately. Does not move the radiologist's viewer.", ["indices": ["type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 1, "maxItems": 12]])
        ]
    }
    public let detail: EngineStudyDetail
    private let templates: [ReportTemplate]
    private let frames: [EngineImage]
    private let render: (EngineImage, Double?, Double?) async throws -> EngineRender
    private let request: ([[String: Any]]) async throws -> AgentResponse
    private let progress: (String) -> Void
    private var viewed: [String: (Double, Double)] = [:]
    private var currentImage: EngineImage?
    private var templateID: String?
    private var candidate: ReportDraft?
    public init(detail: EngineStudyDetail, templates: [ReportTemplate], render: @escaping (EngineImage, Double?, Double?) async throws -> EngineRender, request: @escaping ([[String: Any]]) async throws -> AgentResponse, progress: @escaping (String) -> Void = { _ in }) {
        self.detail = detail; self.templates = templates; self.render = render; self.request = request; self.progress = progress
        frames = detail.series.flatMap(\.frames)
        templateID = ReportTemplate.best(in: templates, modality: detail.study.modality, description: detail.study.title)?.id
    }
    public func run(language: String, maxRounds: Int = 64) async throws -> AutomaticDraft {
        try detail.validate(id: detail.study.id, expectedUID: detail.study.studyUID)
        guard !frames.isEmpty else { throw RadError.message("No DICOM frames are available yet.") }
        var input: [[String: Any]] = [["role": "user", "content": """
        Create a Draft for evaluation for this newly arrived Horos study. Modality: \(detail.study.modality). Study description: \(detail.study.title). Language: \(language).
        Review the actual images before writing. Use the best matching report template and add exact phrase-to-key-image links for supported findings. Use view_images to review frames in batches of up to 12. Review every available series and frame where possible. List any unreviewed coverage explicitly in the report; never imply sampled frames establish a normal whole study. This run has a maximum of \(maxRounds) model turns; prioritize image review and write the draft before that limit.
        Available local inventory (zero-based indices): \(inventory()). The arrival quiet period is a heuristic, not a DICOM transfer-completion signal. Do not invent a clinical history or a prior comparison. Do not finalize or sign.
        Suggested template: \(templateID ?? "none"). Template document is layout only, not evidence of normal findings:
        \(templates.first { $0.id == templateID }?.document ?? "Use a conventional radiology document.")
        """]]
        var messages: [String] = []
        for round in 0..<maxRounds {
            try Task.checkCancellation()
            progress("Reviewing images · \(viewed.count)/\(frames.count)")
            let response = try await request(input)
            try Task.checkCancellation()
            input += response.output
            if !response.text.isEmpty { messages.append(response.text) }
            let calls = response.output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty { throw RadError.message("Astra finished without saving a draft. Retry or open the study for manual review.") }
            for call in calls {
                guard let name = call["name"] as? String, let id = call["call_id"] as? String, let arguments = call["arguments"] as? String,
                      let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw RadError.message("Malformed model tool call.") }
                let output: Any
                do { output = try await execute(name, args) }
                catch is CancellationError { throw CancellationError() }
                catch { output = "Tool failed: \(error.localizedDescription)" }
                input.append(["type": "function_call_output", "call_id": id, "output": output])
                if let candidate {
                    return AutomaticDraft(report: candidate, templateID: templateID, reviewedFrames: viewed.count, totalFrames: frames.count, message: messages.suffix(3).joined(separator: "\n\n"))
                }
            }
            if round == maxRounds - 3 { input.append(["role": "user", "content": "Three turns remain. Write the evaluation draft now with explicit limitations for any images you have not reviewed."]) }
        }
        throw RadError.message("The automatic review reached its turn limit without a draft. Open the study to continue review.")
    }
    private func inventory() -> String {
        detail.series.map { "\($0.name): \($0.frames.count) frames, indices \($0.frames.first?.index ?? 0)…\($0.frames.last?.index ?? 0)" }.joined(separator: "; ")
    }
    private func image(_ index: Int, center: Double? = nil, width: Double? = nil) async throws -> [[String: Any]] {
        guard frames.indices.contains(index) else { throw RadError.message("Image index is outside this study.") }
        let frame = frames[index]
        let value = try await render(frame, center, width)
        try Task.checkCancellation()
        guard value.studyID == detail.study.id, value.imageID == frame.id, value.width > 0, value.height > 0,
              value.width <= 16384, value.height <= 16384, value.windowWidth.isFinite, value.windowWidth >= 1, value.windowCenter.isFinite,
              let data = Data(base64Encoded: value.png), let source = NSImage(data: data) else { throw RadError.message("The engine returned an invalid image or mismatched identity.") }
        let scale = min(1, 2048 / Double(max(value.width, value.height)))
        let width = max(1, Int(Double(value.width) * scale)), height = max(1, Int(Double(value.height) * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RadError.message("Could not allocate the model image.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height)); NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RadError.message("Could not encode the model image.") }
        viewed[frame.id] = (value.windowWidth, value.windowCenter); currentImage = frame
        progress("Reviewing images · \(viewed.count)/\(frames.count)")
        return [["type": "input_text", "text": "Image index \(index), series \(detail.series.first { $0.frames.contains { $0.id == frame.id } }?.name ?? ""), W \(value.windowWidth)/L \(value.windowCenter). Native DICOM rendering resized to at most 2048 pixels."], ["type": "input_image", "image_url": "data:image/png;base64,\(png.base64EncodedString())", "detail": "high"]]
    }
    private func execute(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "list_series": return inventory()
        case "list_templates": return String(data: try JSONEncoder().encode(templates), encoding: .utf8) ?? "[]"
        case "select_template":
            guard let id = args["id"] as? String, let template = templates.first(where: { $0.id == id }) else { throw RadError.message("Unknown template.") }
            templateID = id; return template.document
        case "view_image":
            guard let index = args["index"] as? Int else { throw RadError.message("Image index is required.") }
            return try await image(index)
        case "view_images":
            guard let indices = args["indices"] as? [Int], (1...12).contains(indices.count), Set(indices).count == indices.count, indices.allSatisfy({ frames.indices.contains($0) }) else { throw RadError.message("Provide 1–12 distinct valid image indices.") }
            var output: [[String: Any]] = []
            for index in indices { try Task.checkCancellation(); output += try await image(index) }
            return output
        case "set_window":
            guard let frame = currentImage, let center = args["center"] as? Double, let width = args["width"] as? Double, center.isFinite, width.isFinite, abs(center) <= 1_000_000, (1...1_000_000).contains(width) else { throw RadError.message("View an image first and provide valid window settings.") }
            return try await image(frame.index, center: center, width: width)
        case "write_report":
            guard !viewed.isEmpty, let document = args["document"] as? String, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, document.count <= 200_000,
                  let links = args["key_images"] as? [[String: Any]], links.count <= 300 else { throw RadError.message("Review the images before writing a report document with key_images.") }
            var references: [KeyImageReference] = []
            for link in links {
                guard let phrase = link["phrase"] as? String, let index = link["image_index"] as? Int, frames.indices.contains(index), let window = viewed[frames[index].id] else { throw RadError.message("Every key image must have been reviewed in this run.") }
                let frame = frames[index]
                var reference = KeyImageReference(phrase: phrase, imageID: frame.id, imageIndex: index, studyUID: detail.study.studyUID, windowWidth: window.0, windowCenter: window.1)
                reference.sopInstanceUID = frame.sopInstanceUID; reference.frame = frame.frame
                guard reference.range(in: document) != nil else { throw RadError.message("Each key-image phrase must occur exactly once in the document.") }
                references.append(reference)
            }
            var draft = ReportDraft(); draft.document = document; draft.evidence = references; draft.purpose = "evaluation"; candidate = draft
            return "Draft for evaluation prepared."
        default: throw RadError.message("Unsupported automatic drafting tool.")
        }
    }
}
