import SwiftUI
import UniformTypeIdentifiers
import RadAgentCore
import RadAgentImaging

struct ImageFrame: Identifiable {
    let id = UUID()
    let name: String
    let series: String
    let image: NSImage
    let dicom: DICOMImage?
    let path: String?
    var backend: EngineImage? = nil
}

private final class NativeFrame {
    let image: NSImage
    let width: Double
    let center: Double
    let spacing: (Double, Double)
    init(image: NSImage, render: EngineRender) { self.image = image; width = render.windowWidth; center = render.windowCenter; spacing = (render.pixelSpacingX, render.pixelSpacingY) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var studies: [StudyRecord] = []
    @Published var selectedID: String = ""
    @Published var frames: [ImageFrame] = []
    @Published var selectedFrame = 0
    @Published var composer = ""
    @Published var isRunning = false
    @Published var activity = ""
    @Published var activities: [String] = []
    @Published var error: String?
    @Published var toast: String?
    @Published var showConnections = false
    @Published var showHoros = false
    @Published var showLibrary = false
    @Published var series: [EngineSeries] = []
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var loadingFrame = false
    @Published var openingSeriesID: String?
    @Published var pixelSpacing: (Double, Double) = (0, 0)
    @Published var showHistory = false
    @Published var showingWorklist = false
    @Published var showTemplates = false
    @Published var templates = ReportTemplate.defaults
    @Published var worklistStudies: [EngineStudy] = []
    @Published var evidencePreview: EvidencePreview?
    @Published var pinnedEvidenceID: String?
    @Published var autoDraftEnabled = true
    @Published var incomingQueue = IncomingStudyQueue()
    @Published var incomingActivity = "Watching for new studies"
    @Published var incomingError: String?
    @Published var incomingStudyUID: String?
    var incomingTask: Task<Void, Never>?
    var worklistTask: Task<Void, Never>?
    var incomingLock: Int32 = -1
    var incomingReady = false
    var evidenceTask: Task<Void, Never>?
    var viewedImages: Set<String> = []
    var viewedWindows: [String: (Double, Double)] = [:]
    var refreshingWorklist = false
    @Published var syncingDraft = false
    let backend = ClinicClient()
    @Published var liveMode = APIConfiguration.isConfigured
    @Published var modelID = APIConfiguration.model
    @Published var zoom: Double = 1
    @Published var viewerTool: ViewerTool = .window
    @Published var viewerResetID = 0
    @Published var displayedWindowWidth: Double = 400
    @Published var displayedWindowCenter: Double = 0
    @Published var openingStudy = false
    private var studyOpenID = UUID()
    private var agentFrameIndex: Int?
    @Published var inverted = false
    @Published var windowCenter: Double = 0
    @Published var windowWidth: Double = 400
    @Published var renderedImage: NSImage?
    @Published var saveStatus = "Saved on this Mac"
    @Published var language = "English"
    let engine = HorosEngineClient()
    let storage: WorkspaceStore
    private var frameCache: [String: [ImageFrame]] = [:]
    private var runTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var runID: UUID?
    private var canSave = true
    private var frameTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var windowRequestID = UUID()
    private var pendingWindow: (Double, Double)?
    private let nativeImageCache: NSCache<NSString, NativeFrame> = {
        let cache = NSCache<NSString, NativeFrame>(); cache.totalCostLimit = 96 * 1024 * 1024; cache.countLimit = 32; return cache
    }()
    var currentIndex: Int? { studies.firstIndex { $0.id == selectedID } }
    var study: StudyRecord? { currentIndex.map { studies[$0] } }
    var currentFrame: ImageFrame? { frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil }
    var currentSeries: EngineSeries? { series.first { s in s.frames.contains { $0.id == currentFrame?.backend?.id } } }
    var currentSeriesIndices: [Int] {
        guard let series = currentSeries else { return Array(frames.indices) }
        let ids = Set(series.frames.map(\.id)); return frames.indices.filter { frames[$0].backend.map { ids.contains($0.id) } ?? false }
    }
    var seriesFramePosition: Int { currentSeriesIndices.firstIndex(of: selectedFrame) ?? 0 }
    var framePositionLabel: String {
        if let preview = evidencePreview { return "Key image · \(preview.reference.imageIndex + 1) / \(frames.count)" }
        let name = currentSeries.map { $0.name.isEmpty || $0.name == "unnamed" ? "Series \((series.firstIndex { $0.id == currentSeries?.id } ?? 0) + 1)" : $0.name } ?? "Image"
        return "\(name) · \(seriesFramePosition + 1) / \(currentSeriesIndices.count)"
    }
    func stepFrame(_ delta: Int) {
        let indices = currentSeriesIndices
        guard !indices.isEmpty else { return }
        let target = min(indices.count - 1, max(0, seriesFramePosition + delta))
        if indices[target] != selectedFrame { selectFrame(indices[target], preservePresentation: true) }
    }
    func fitViewer() { zoom = 1; viewerResetID += 1 }
    func restoreDefaultWindow() { inverted = false; if currentFrame?.backend != nil { scheduleEngineRender() } else { resetViewer() } }
    func changeWindow(_ width: Double, _ center: Double) {
        guard width.isFinite, center.isFinite, renderedImage != nil, currentFrame?.backend != nil || currentFrame?.dicom != nil else { return }
        windowWidth = max(1, min(1_000_000, width)); windowCenter = max(-1_000_000, min(1_000_000, center)); applyWindow()
    }
    var messages: [ChatMessage] { study?.messages ?? [] }

    init() {
        let custom = ProcessInfo.processInfo.environment["RADAGENT_DATA_DIR"]
        let root = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RadAgent")
        storage = WorkspaceStore(directory: root)
        do {
            if let snapshot = try storage.load() { studies = snapshot.studies; selectedID = snapshot.selectedID ?? studies.first?.id ?? "" }
        } catch {
            let backup = root.appendingPathComponent("workspace-recovery-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: storage.file, to: backup)
                self.error = "Could not read the saved workspace. A recovery copy was preserved at \(backup.path). A new teaching workspace is open."
            } catch {
                canSave = false
                self.error = "Could not read the saved workspace or create a recovery copy. Saving is disabled so the existing workspace is preserved. Check \(storage.file.path)."
            }
        }
        if studies.isEmpty { studies = [Self.demoStudy()]; selectedID = studies[0].id }
        for i in studies.indices where studies[i].engineStudyID != nil { studies[i].draft.purpose = "evaluation" }
        loadTemplates()
        if canSave { loadIncomingQueue() }
        else { incomingError = "Automatic intake paused until workspace recovery is complete." }
        if study?.engineStudyID == nil || engine.running { loadFrames() }
    }

    func startEngine() async {
        do { try engine.launchInBackground() }
        catch { engine.lastError = error.localizedDescription; return }
        for attempt in 0..<12 {
            await engine.connect()
            if engine.isConnected {
                if study?.engineStudyID != nil && frames.isEmpty { loadFrames() }
                return
            }
            if attempt < 11 { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    static func demoStudy() -> StudyRecord {
        var s = StudyRecord(id: "demo-chest", title: "Chest radiograph", patientLabel: "Teaching case 001", modality: "DX", isDemo: true)
        s.draft = demoDraft()
        s.messages = [
            ChatMessage(role: "user", text: "Create a draft from this teaching dictation: PA chest, no prior available. Clear lungs, no pleural effusion or pneumothorax. Cardiomediastinal silhouette within normal limits."),
            ChatMessage(role: "assistant", text: "Your teaching draft is ready on the right. I’ve organized the supplied dictation into findings and impression.\n\nThe image is a synthetic illustration; these findings come from the example dictation, not image interpretation. You can edit any section or ask me to revise it.", engine: "demo")
        ]
        return s
    }
    static func demoDraft(portuguese: Bool = false) -> ReportDraft {
        if portuguese {
            return ReportDraft(indication: "Caso didático. Indicação clínica não fornecida.", technique: "Radiografia de tórax em PA, conforme ditado fornecido.", comparison: "Exame anterior não disponível, conforme ditado.", findings: "Texto do ditado didático: campos pulmonares sem opacidades focais. Ausência de derrame pleural ou pneumotórax. Silhueta cardiomediastinal dentro dos limites da normalidade.\n\nA ilustração sintética não foi interpretada como exame clínico.", impression: "Conforme ditado didático: sem alterações cardiopulmonares agudas.\nRascunho de demonstração; requer revisão do radiologista.")
        }
        return ReportDraft(indication: "Teaching case. Clinical indication not supplied.", technique: "PA chest radiograph, as stated in the supplied dictation.", comparison: "No prior available, per dictation.", findings: "From the supplied teaching dictation: lungs are clear. No pleural effusion or pneumothorax. Cardiomediastinal silhouette is within normal limits.\n\nThe synthetic illustration was not interpreted as a clinical image.", impression: "Per teaching dictation: no acute cardiopulmonary abnormality.\nDemo draft for radiologist review.")
    }

    func selectStudy(_ id: String) {
        guard !isRunning, studies.contains(where: { $0.id == id }) else { return }
        studyOpenID = UUID(); openingStudy = false
        save(); showingWorklist = false; evidencePreview = nil; pinnedEvidenceID = nil; selectedID = id; composer = ""; activities = []; loadFrames(); save()
    }
    func newStudy() {
        guard !isRunning else { return }
        let s = StudyRecord(title: "Untitled study", patientLabel: "Local study", modality: "—")
        studies.append(s); selectStudy(s.id)
    }
    func resetDemo() {
        guard !isRunning else { return }
        if let i = studies.firstIndex(where: { $0.id == "demo-chest" }) { studies[i] = Self.demoStudy() }
        else { studies.insert(Self.demoStudy(), at: 0) }
        liveMode = false; selectStudy("demo-chest")
    }
    func loadFrames() {
        guard let s = study else { return }
        cancelWindowRendering()
        frameTask?.cancel(); series = []; thumbnails = [:]; loadingFrame = false
        if let engineID = s.engineStudyID {
            frames = []; renderedImage = nil
            frameTask = Task {
                do { let detail = try await engine.detail(engineID, expectedUID: s.studyUID.isEmpty ? nil : s.studyUID); try Task.checkCancellation(); guard selectedID == s.id else { return }; applyEngineDetail(detail) }
                catch is CancellationError { }
                catch { self.error = "Could not load this study from Horos: \(error.localizedDescription)" }
            }
            return
        }
        if let cached = frameCache[s.id] { frames = cached }
        else if s.isDemo { frames = [ImageFrame(name: "PA · schematic", series: "Teaching illustration", image: DemoImages.chest(), dicom: nil, path: nil)] }
        else {
            var failures = 0
            frames = s.imagePaths.compactMap { path in
                do { return try Self.loadFrame(URL(fileURLWithPath: path)) } catch { failures += 1; return nil }
            }
            if failures > 0 { error = "\(failures) saved image(s) could not be reopened. Their paths remain saved. Reimport them or use Horos." }
        }
        frameCache[s.id] = frames; selectedFrame = 0; resetViewer()
    }
    static func loadFrame(_ url: URL) throws -> ImageFrame {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 128_000_000 else { throw RadError.message("\(url.lastPathComponent) exceeds the 128 MB preview limit. Open it in Horos.") }
        let data = try Data(contentsOf: url)
        if data.count >= 132, String(data: data[128..<132], encoding: .ascii) == "DICM" {
            let d = try DICOMImage(data: data)
            guard let cg = d.rendered() else { throw RadError.message("Could not render DICOM pixels.") }
            return ImageFrame(name: "Image \(d.instanceNumber)", series: d.seriesDescription.isEmpty ? "DICOM series" : d.seriesDescription, image: NSImage(cgImage: cg, size: NSSize(width: d.columns, height: d.rows)), dicom: d, path: url.path)
        }
        guard let image = NSImage(data: data), image.isValid else { throw RadError.message("\(url.lastPathComponent): unsupported image. Open DICOM files in Horos if the integrated preview cannot decode them.") }
        return ImageFrame(name: url.lastPathComponent, series: "Attached images", image: image, dicom: nil, path: url.path)
    }
    func selectFrame(_ index: Int, requestRender: Bool = true, preservePresentation: Bool = false) {
        guard frames.indices.contains(index) else { return }
        cancelWindowRendering()
        evidenceTask?.cancel(); evidencePreview = nil; pinnedEvidenceID = nil; selectedFrame = index
        if preservePresentation { renderedImage = currentFrame?.backend == nil ? currentFrame?.image : nil }
        else { resetViewer() }
        if currentFrame?.backend != nil && requestRender { scheduleEngineRender(center: preservePresentation ? windowCenter : nil, width: preservePresentation ? windowWidth : nil) }
    }
    func resetViewer() {
        zoom = 1; inverted = false; viewerResetID += 1; pixelSpacing = (0, 0)
        windowCenter = currentFrame?.dicom?.windowCenter ?? 0; windowWidth = currentFrame?.dicom?.windowWidth ?? 400
        renderedImage = currentFrame?.backend == nil ? currentFrame?.image : nil
    }
    func applyWindow() {
        if currentFrame?.backend != nil { queueWindowRender(); return }
        guard let dicom = currentFrame?.dicom, let cg = dicom.rendered(center: windowCenter, width: windowWidth) else { return }
        renderedImage = NSImage(cgImage: cg, size: NSSize(width: dicom.columns, height: dicom.rows))
        displayedWindowWidth = windowWidth; displayedWindowCenter = windowCenter
    }
    private func cancelWindowRendering() {
        windowRequestID = UUID(); windowTask?.cancel(); windowTask = nil; pendingWindow = nil
    }
    /// Coalesce pointer updates while one native render is in flight. Long drags keep updating
    /// instead of waiting for the user to release the mouse or flooding Horos with renders.
    private func queueWindowRender() {
        pendingWindow = (windowWidth, windowCenter)
        guard windowTask == nil, let engineID = study?.engineStudyID, let image = currentFrame?.backend else { return }
        frameTask?.cancel(); let localID = selectedID, index = selectedFrame, token = UUID(); windowRequestID = token
        loadingFrame = true
        windowTask = Task {
            defer { if windowRequestID == token { windowTask = nil; loadingFrame = false } }
            do {
                while let request = pendingWindow {
                    pendingWindow = nil
                    let native = try await nativeFrame(studyID: engineID, image: image, center: request.1, width: request.0)
                    try Task.checkCancellation()
                    guard windowRequestID == token, selectedID == localID, selectedFrame == index else { return }
                    renderedImage = native.image; displayedWindowWidth = native.width; displayedWindowCenter = native.center; pixelSpacing = native.spacing
                    if pendingWindow == nil { windowWidth = native.width; windowCenter = native.center }
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch is CancellationError { }
            catch { if windowRequestID == token { self.error = error.localizedDescription } }
        }
    }
    func openEngineStudy(_ remote: EngineStudy) async {
        guard !isRunning else { return }
        let requestID = UUID(); studyOpenID = requestID; openingStudy = true
        defer { if studyOpenID == requestID { openingStudy = false } }
        do {
            let detail = try await engine.detail(remote.id, expectedUID: remote.studyUID)
            guard studyOpenID == requestID, !isRunning, detail.study.studyUID == remote.studyUID else { return }
            save()
            if let existing = studies.first(where: { $0.engineStudyID == remote.id }) {
                guard existing.studyUID.isEmpty || existing.studyUID == remote.studyUID else { throw RadError.message("The saved study identity differs from Horos. The existing report was preserved.") }
                selectedID = existing.id
            }
            else {
                var record = StudyRecord(title: remote.title.isEmpty ? "\(remote.modality) study" : remote.title, patientLabel: remote.patientName.isEmpty ? remote.patientID : remote.patientName, modality: remote.modality, studyUID: remote.studyUID)
                record.engineStudyID = remote.id; record.draft.purpose = "evaluation"; studies.append(record); selectedID = record.id
            }
            composer = ""; activities = []; showLibrary = false; showingWorklist = false; evidencePreview = nil; pinnedEvidenceID = nil
            chooseTemplateIfNeeded(); applyEngineDetail(detail); save()
        } catch { if studyOpenID == requestID { self.error = error.localizedDescription } }
    }
    private func applyEngineDetail(_ detail: EngineStudyDetail) {
        cancelWindowRendering()
        if let i = currentIndex {
            studies[i].patientID = detail.study.patientID; studies[i].accession = detail.study.accession
            studies[i].studyDate = detail.study.date > 0 ? Date(timeIntervalSince1970: detail.study.date) : nil
        }
        frameTask?.cancel(); series = detail.series; thumbnails = [:]; nativeImageCache.removeAllObjects()
        frames = detail.series.enumerated().flatMap { index, s in s.frames.map { image in
            ImageFrame(name: "Image \(image.instance) · frame \(image.frame + 1)", series: s.name.isEmpty ? "\(s.modality) · Series \(index + 1)" : s.name, image: NSImage(size: NSSize(width: 1, height: 1)), dicom: nil, path: nil, backend: image)
        } }
        selectedFrame = 0; resetViewer(); if !frames.isEmpty { scheduleEngineRender() }
        chooseTemplateIfNeeded()
    }
    private func scheduleEngineRender(center: Double? = nil, width: Double? = nil) {
        cancelWindowRendering()
        frameTask?.cancel(); let index = selectedFrame; loadingFrame = true
        frameTask = Task {
            do { try await Task.sleep(for: .milliseconds(35)); _ = try await loadEngineFrame(index: index, center: center, width: width) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { loadingFrame = false; self.error = error.localizedDescription } }
        }
    }
    func loadEngineFrame(index: Int, center: Double? = nil, width: Double? = nil) async throws -> NSImage {
        guard let engineID = study?.engineStudyID, frames.indices.contains(index), let image = frames[index].backend else { throw RadError.message("Select a Horos DICOM frame.") }
        let localID = selectedID
        loadingFrame = true
        let native = try await nativeFrame(studyID: engineID, image: image, center: center, width: width)
        try Task.checkCancellation()
        guard localID == selectedID, selectedFrame == index else { throw CancellationError() }
        renderedImage = native.image; windowWidth = native.width; windowCenter = native.center
        displayedWindowWidth = native.width; displayedWindowCenter = native.center
        pixelSpacing = native.spacing; loadingFrame = false
        return native.image
    }
    func loadThumbnail(_ s: EngineSeries) async {
        guard thumbnails[s.id] == nil, let first = s.frames.first, let engineID = study?.engineStudyID else { return }
        let localID = selectedID
        do {
            let native = try await nativeFrame(studyID: engineID, image: first)
            guard selectedID == localID else { return }
            let scale = min(1, 160 / max(native.image.size.width, native.image.size.height))
            let size = NSSize(width: native.image.size.width * scale, height: native.image.size.height * scale)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(size.width)), pixelsHigh: max(1, Int(size.height)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            native.image.draw(in: NSRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
            if let cg = bitmap.cgImage { thumbnails[s.id] = NSImage(cgImage: cg, size: size) }
        }
        catch { /* A failed thumbnail never replaces or mislabels the active frame. */ }
    }
    private func nativeFrame(studyID: String, image: EngineImage, center: Double? = nil, width: Double? = nil) async throws -> NativeFrame {
        let key = "\(studyID)|\(image.id)|\(center.map(String.init(describing:)) ?? "default")|\(width.map(String.init(describing:)) ?? "default")" as NSString
        if let cached = nativeImageCache.object(forKey: key) { return cached }
        let render = try await engine.render(studyID: studyID, imageID: image.id, center: center, width: width)
        try Task.checkCancellation()
        guard render.width > 0, render.height > 0, render.width <= 16384, render.height <= 16384,
              let data = Data(base64Encoded: render.png), let decoded = NSImage(data: data) else { throw RadError.message("Could not decode the native DICOM frame.") }
        decoded.size = NSSize(width: render.width, height: render.height)
        let native = NativeFrame(image: decoded, render: render)
        nativeImageCache.setObject(native, forKey: key, cost: render.width * render.height * 4)
        return native
    }
    func selectSeries(_ s: EngineSeries, openNative: Bool = false) {
        guard let first = s.frames.first, let index = frames.firstIndex(where: { $0.backend?.id == first.id }) else { return }
        selectFrame(index)
        if openNative { openNativeSeries(s) }
    }
    func openNativeSeries(_ s: EngineSeries) {
        guard openingSeriesID == nil, let engineID = study?.engineStudyID else { return }
        let frame = currentFrame?.backend.flatMap { image in s.frames.contains { $0.id == image.id } ? image : nil }
        let width = renderedImage != nil ? displayedWindowWidth : nil, center = renderedImage != nil ? displayedWindowCenter : nil
        openingSeriesID = s.id
        Task {
            defer { openingSeriesID = nil }
            do { try await engine.openSeries(studyID: engineID, seriesID: s.id, imageID: frame?.id, width: width, center: center) }
            catch { self.error = error.localizedDescription }
        }
    }
    func importImages(folder: Bool = false) {
        guard !isRunning else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = true
        panel.title = folder ? "Import a DICOM study folder" : "Attach images or DICOM files"
        panel.message = "DICOM files are grouped by Study Instance UID. Raster images attach to the current local study."
        guard panel.runModal() == .OK else { return }
        var urls = panel.urls
        if folder {
            urls = urls.flatMap { root -> [URL] in
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
                return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }
        }
        importURLs(urls)
    }
    func importURLs(_ urls: [URL]) {
        guard !isRunning else { return }
        guard urls.count <= 500 else { error = "This import contains \(urls.count) files. Import up to 500 at a time, or review the full study in Horos."; return }
        var failures: [String] = [], targetID: String?
        for url in urls {
            do {
                let frame = try Self.loadFrame(url)
                var id: String
                if let d = frame.dicom {
                    id = StudyIdentity.groupedID(studyUID: d.studyUID, fallback: url.path)
                    if !studies.contains(where: { $0.id == id }) {
                        studies.append(StudyRecord(id: id, title: d.studyDescription.isEmpty ? "\(d.modality) study" : d.studyDescription, patientLabel: d.patientName.isEmpty ? "DICOM study" : d.patientName, modality: d.modality, studyUID: d.studyUID))
                    }
                } else {
                    if study?.isDemo != false { newStudy() }
                    id = selectedID
                }
                guard let i = studies.firstIndex(where: { $0.id == id }) else { continue }
                if studies[i].imagePaths.contains(url.path) { continue }
                if frameCache[id] == nil { frameCache[id] = studies[i].imagePaths.compactMap { try? Self.loadFrame(URL(fileURLWithPath: $0)) } }
                studies[i].imagePaths.append(url.path)
                frameCache[id, default: []].append(frame)
                frameCache[id]?.sort { a, b in a.series == b.series ? (a.dicom?.instanceNumber ?? 0) < (b.dicom?.instanceNumber ?? 0) : a.series < b.series }
                targetID = id
            } catch { failures.append(error.localizedDescription) }
        }
        if let id = targetID { selectStudy(id); notify("Images attached to study") }
        if !failures.isEmpty { error = "\(failures.count) file(s) could not be previewed.\n\n" + failures.prefix(4).joined(separator: "\n\n") }
        save()
    }

    func editDraft(_ key: WritableKeyPath<ReportDraft, String>, _ value: String) {
        guard !isRunning, let i = currentIndex else { return }
        studies[i].draft[keyPath: key] = value; studies[i].draft.updatedAt = Date(); scheduleSave()
    }
    func copyDraft() {
        guard let draft = study?.draft else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.text, forType: .string); notify("Draft copied")
    }
    func exportDraft() {
        guard let s = study else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Radiology Agent - Draft for evaluation.docx"; panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "docx" {
                let attributed = DocumentEditor.styled(s.draft.text, evidence: [])
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                try data.write(to: url, options: .atomic)
            } else { try s.draft.text.write(to: url, atomically: true, encoding: .utf8) }
            notify("Draft exported")
        } catch { self.error = error.localizedDescription }
    }
    func restoreDraft(_ draft: ReportDraft) {
        guard !isRunning, let i = currentIndex else { return }
        studies[i].replaceDraft(draft); save(); showHistory = false; notify("Draft version restored")
    }
    func scheduleSave() {
        saveStatus = "Saving…"; saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { save() } }
    }
    func save() {
        guard canSave else { saveStatus = "Recovery required · saving paused"; return }
        do { try storage.save(WorkspaceSnapshot(studies: studies, selectedID: selectedID)); saveStatus = "Saved on this Mac" }
        catch { saveStatus = "Save failed"; self.error = "Could not save the workspace: \(error.localizedDescription)" }
    }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(3)); if toast == text { toast = nil } }
    }
    func log(_ value: String) { activity = value; activities.append(value) }
    func append(_ role: String, _ text: String, to id: String) {
        if let i = studies.firstIndex(where: { $0.id == id }) { studies[i].messages.append(ChatMessage(role: role, text: text, engine: role == "assistant" ? (liveMode ? modelID : "demo") : nil)) }
    }
    func send(_ prompt: String? = nil) {
        let text = (prompt ?? composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !openingStudy, let s = study else { return }
        if !liveMode && !s.isDemo { error = "Astra is unavailable. Check the local .env configuration or your Settings override."; showConnections = true; return }
        composer = ""; isRunning = true; activities = []; viewedImages = []; viewedWindows = [:]; agentFrameIndex = nil; let token = UUID(); runID = token
        append("user", text, to: s.id); save()
        let live = liveMode
        runTask = Task {
            do {
                if live { try await runLive(studyID: s.id, token: token) }
                else { try await runDemo(prompt: text, studyID: s.id) }
            } catch is CancellationError { append("assistant", "Stopped. Any draft changes already made remain available for review.", to: s.id) }
            catch { append("assistant", "I couldn’t complete that request. \(error.localizedDescription)", to: s.id); self.error = error.localizedDescription }
            if runID == token { isRunning = false; activity = ""; runTask = nil; runID = nil }
            save()
        }
    }
    func stop() { runTask?.cancel() }

    private func runDemo(prompt: String, studyID: String) async throws {
        log("Reading teaching dictation")
        try await Task.sleep(for: .milliseconds(600)); try Task.checkCancellation()
        let lower = prompt.lowercased()
        if lower.contains("view") || lower.contains("image") || lower.contains("zoom") {
            selectFrame(0); log("Opening teaching illustration")
            if lower.contains("zoom") { zoom = 1.4 }
            append("assistant", "The teaching illustration is open in the viewer. This is an original synthetic schematic, so it cannot support a clinical interpretation. Open an exam from the Horos study library, then select Live Astra for image review.", to: studyID)
        } else if lower.contains("draft") || lower.contains("report") || lower.contains("portugu") || lower.contains("laudo") {
            log("Preparing an editable demo draft")
            try await Task.sleep(for: .milliseconds(650)); try Task.checkCancellation()
            if let i = studies.firstIndex(where: { $0.id == studyID }) { studies[i].replaceDraft(Self.demoDraft(portuguese: lower.contains("portugu") || lower.contains("laudo") || language == "Português")) }
            append("assistant", "I’ve loaded the scripted teaching draft from the example dictation. It’s editable on the right, and the previous version is in History.\n\nDemo mode uses a fixed example. Connect Astra to follow new dictation and make free-form revisions.", to: studyID)
        } else {
            append("assistant", "You’re in the offline teaching demo. Try “Show the image,” “Create a draft report,” or “Write the report in Portuguese.”\n\nFor your own exams and conversational revisions, add your API key in Connections and switch to Live Astra.", to: studyID)
        }
    }

    private func runLive(studyID: String, token: UUID) async throws {
        guard let s = studies.first(where: { $0.id == studyID }) else { return }
        let key = APIConfiguration.key
        let inventory = s.engineStudyID == nil ? frames.enumerated().map { "\($0.offset): \($0.element.series) / \($0.element.name)" }.joined(separator: "; ") : series.map { "\($0.name): \($0.frames.count) frames, indices \($0.frames.first?.index ?? 0)...\($0.frames.last?.index ?? 0)" }.joined(separator: "; ")
        var input: [[String: Any]] = [["role": "user", "content": "Current study: modality \(s.modality). Synthetic demo: \(s.isDemo). Source: \(s.engineStudyID == nil ? "attached images; exam completeness unknown" : "full series/frame inventory from the active Horos database; additional PACS instances may still be outstanding"). Available images (zero-based indices): \(inventory). Report language: \(language). Current editable draft:\n\(s.draft.text)"]]
        input += s.messages.suffix(24).filter { ["user", "assistant"].contains($0.role) }.map { ["role": $0.role, "content": $0.text] }
        if let template = selectedTemplate { input.insert(["role": "user", "content": "Selected report template: \(template.id) — \(template.name). Template document (layout only, not verified findings):\n\(template.document)"], at: 1) }
        let client = AgentClient()
        for _ in 0..<16 {
            try Task.checkCancellation()
            guard selectedID == studyID, runID == token else { throw CancellationError() }
            log("Astra is reviewing the study context")
            let response = try await client.request(apiKey: key, model: modelID, input: input, allowHoros: study?.engineStudyID != nil)
            try Task.checkCancellation()
            input += response.output
            if !response.text.isEmpty { append("assistant", response.text, to: studyID) }
            let calls = response.output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty { if response.text.isEmpty { throw RadError.message("Astra returned no message or tool action.") }; return }
            for call in calls {
                try Task.checkCancellation()
                guard let name = call["name"] as? String, let callID = call["call_id"] as? String, let arguments = call["arguments"] as? String,
                      let data = arguments.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RadError.message("Malformed model tool call.") }
                let output: Any
                do { output = try await executeTool(name, args, studyID: studyID) }
                catch is CancellationError { throw CancellationError() }
                catch { output = "Tool failed: \(error.localizedDescription)"; log("\(name): \(error.localizedDescription)") }
                input.append(["type": "function_call_output", "call_id": callID, "output": output]); save()
            }
        }
        throw RadError.message("Stopped at the 16-step limit. Review the current draft and continue with a focused request.")
    }
    private func imageOutput(_ image: NSImage, index: Int, width: Double? = nil, center: Double? = nil) throws -> [[String: Any]] {
        let maxSize: CGFloat = 2048, scale = min(1, maxSize / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RadError.message("Could not allocate an image preview.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RadError.message("Could not encode the selected image.") }
        let source = frames[index].backend == nil ? "Attached image preview, image index \(index)" : "Native Horos DICOM rendering, image index \(index), series \(frames[index].series), W \(Int(width ?? 0)) / L \(Int(center ?? 0))"
        return [["type": "input_text", "text": "\(source). Resized to at most 2048 pixels. This frame alone does not establish full exam coverage."], ["type": "input_image", "image_url": "data:image/png;base64,\(png.base64EncodedString())", "detail": "high"]]
    }
    private func executeTool(_ name: String, _ args: [String: Any], studyID: String) async throws -> Any {
        guard selectedID == studyID else { throw RadError.message("Study context changed; tool rejected.") }
        switch name {
        case "list_templates":
            return String(data: try JSONEncoder().encode(templates), encoding: .utf8) ?? "[]"
        case "select_template":
            guard let id = args["id"] as? String, let template = templates.first(where: { $0.id == id }), let i = currentIndex else { throw RadError.message("Choose a template ID from list_templates.") }
            studies[i].templateID = id; log("Selected template: \(template.name)")
            return template.document
        case "write_report":
            guard let document = args["document"] as? String, !document.isEmpty, document.count <= 200_000, let links = args["key_images"] as? [[String: Any]], links.count <= 300, let i = currentIndex else { throw RadError.message("A report document and key_images array are required.") }
            var references: [KeyImageReference] = []
            for link in links {
                guard let phrase = link["phrase"] as? String, let index = link["image_index"] as? Int, frames.indices.contains(index), let frame = frames[index].backend, viewedImages.contains(frame.id), let window = viewedWindows[frame.id] else { throw RadError.message("Every key image must reference a native DICOM frame viewed during this request.") }
                var reference = KeyImageReference(phrase: phrase, imageID: frame.id, imageIndex: index, studyUID: studies[i].studyUID, windowWidth: window.0, windowCenter: window.1)
                reference.sopInstanceUID = frame.sopInstanceUID; reference.frame = frame.frame
                guard reference.range(in: document) != nil else { throw RadError.message("Key-image phrase must occur exactly once in the report: \(phrase)") }
                references.append(reference)
            }
            var draft = ReportDraft(); draft.document = document; draft.evidence = references; draft.purpose = "evaluation"
            studies[i].replaceDraft(draft); studies[i].workflowStatus = "draft"; studies[i].backendDraftDirty = true; log("Updated evaluation draft · \(references.count) key-image links")
            return "Document saved as Draft for evaluation. Key-image phrases preview on hover and pin on click. No finalization performed."
        case "list_series":
            let inventory = series.enumerated().map { i, s in ["series": i, "description": s.name, "modality": s.modality, "frames": s.frames.count, "firstImageIndex": s.frames.first?.index ?? 0, "lastImageIndex": s.frames.last?.index ?? 0] as [String: Any] }
            log("Read native series inventory · \(frames.count) frames")
            return String(data: try JSONSerialization.data(withJSONObject: ["series": inventory, "totalImages": frames.count]), encoding: .utf8) ?? "No series"
        case "view_image":
            guard let index = args["index"] as? Int, frames.indices.contains(index) else { throw RadError.message("Image index is outside the attached study.") }
            agentFrameIndex = index; log("Reviewing image \(index + 1) of \(frames.count)")
            if let frame = frames[index].backend, let engineID = study?.engineStudyID {
                let native = try await nativeFrame(studyID: engineID, image: frame)
                viewedImages.insert(frame.id); viewedWindows[frame.id] = (native.width, native.center)
                return try imageOutput(native.image, index: index, width: native.width, center: native.center)
            }
            return try imageOutput(frames[index].image, index: index)
        case "set_window":
            guard let index = agentFrameIndex, frames.indices.contains(index), let center = args["center"] as? Double, let width = args["width"] as? Double, center.isFinite, width.isFinite, width >= 1, width <= 1_000_000, abs(center) <= 1_000_000 else { throw RadError.message("View a DICOM image before setting valid center/width values.") }
            if let frame = frames[index].backend, let engineID = study?.engineStudyID {
                log("Adjusting agent image window/level")
                let native = try await nativeFrame(studyID: engineID, image: frame, center: center, width: width)
                viewedImages.insert(frame.id); viewedWindows[frame.id] = (native.width, native.center)
                return try imageOutput(native.image, index: index, width: native.width, center: native.center)
            }
            guard let dicom = frames[index].dicom, let cg = dicom.rendered(center: center, width: width) else { throw RadError.message("No DICOM image available for windowing.") }
            return try imageOutput(NSImage(cgImage: cg, size: NSSize(width: dicom.columns, height: dicom.rows)), index: index, width: width, center: center)
        case "write_draft":
            let fields = ["indication", "technique", "comparison", "findings", "impression"]
            guard fields.allSatisfy({ args[$0] is String }), let i = currentIndex else { throw RadError.message("The draft is missing required sections.") }
            let d = ReportDraft(indication: args["indication"] as! String, technique: args["technique"] as! String, comparison: args["comparison"] as! String, findings: args["findings"] as! String, impression: args["impression"] as! String)
            studies[i].replaceDraft(d); log("Updated report draft · previous version preserved"); return "Draft updated locally. It is unsigned and requires radiologist review."
        default: throw RadError.message("Unknown tool rejected: \(name)")
        }
    }
}
