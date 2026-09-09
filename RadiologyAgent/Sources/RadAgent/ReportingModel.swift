import AppKit
import RadAgentCore

struct EvidencePreview {
    let reference: KeyImageReference
    let image: NSImage
}

extension AppModel {
    var selectedTemplate: ReportTemplate? { templates.first { $0.id == study?.templateID } }
    var templatesURL: URL { storage.directory.appendingPathComponent("templates.json") }
    func loadTemplates() {
        guard FileManager.default.fileExists(atPath: templatesURL.path) else { return }
        do { templates = try JSONDecoder().decode([ReportTemplate].self, from: Data(contentsOf: templatesURL)) }
        catch { self.error = "Could not load saved templates; the file has been preserved." }
    }
    func persistTemplates() {
        do {
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(templates).write(to: templatesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: templatesURL.path)
        } catch { self.error = error.localizedDescription }
    }
    func chooseTemplateIfNeeded() {
        guard let i = currentIndex, studies[i].templateID == nil, !studies[i].isDemo,
              let template = ReportTemplate.best(in: templates, modality: studies[i].modality, description: studies[i].title) else { return }
        studies[i].templateID = template.id
        if studies[i].draft.isEmpty { studies[i].draft.document = template.document; studies[i].draft.purpose = "evaluation" }
    }
    func applyTemplate(_ template: ReportTemplate) {
        guard let i = currentIndex, !isRunning else { return }
        var draft = ReportDraft(); draft.document = template.document; draft.purpose = "evaluation"
        studies[i].replaceDraft(draft); studies[i].templateID = template.id; save()
    }
    func editDocument(_ value: String) {
        guard let i = currentIndex, !isRunning else { return }
        let previous = studies[i].draft.body
        studies[i].draft.document = value
        studies[i].draft.evidence = studies[i].draft.evidence?.filter { $0.contextUnchanged(from: previous, to: value) }
        studies[i].draft.updatedAt = Date(); studies[i].backendDraftDirty = true; studies[i].workflowStatus = "draft"; scheduleSave()
    }
    func hoverEvidence(_ reference: KeyImageReference?) {
        evidenceTask?.cancel()
        guard let reference else { evidencePreview = nil; return }
        guard let index = resolveEvidence(reference), let image = frames[index].backend, let engineID = study?.engineStudyID else { return }
        let studyID = selectedID
        evidenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let render = try await engine.render(studyID: engineID, imageID: image.id, center: reference.windowCenter, width: reference.windowWidth)
                try Task.checkCancellation()
                guard selectedID == studyID, let png = Data(base64Encoded: render.png), let ns = NSImage(data: png) else { return }
                var resolved = reference; resolved.imageIndex = index
                evidencePreview = EvidencePreview(reference: resolved, image: ns)
            } catch { }
        }
    }
    func pinEvidence(_ reference: KeyImageReference) {
        guard let index = resolveEvidence(reference) else { return }
        evidenceTask?.cancel(); evidencePreview = nil
        selectFrame(index); pinnedEvidenceID = reference.id; windowWidth = reference.windowWidth; windowCenter = reference.windowCenter; applyWindow()
    }
    var activeEvidence: KeyImageReference? { evidencePreview?.reference ?? study?.draft.evidence?.first { $0.id == pinnedEvidenceID } }
    var activeEvidenceGroup: [KeyImageReference] { guard let active = activeEvidence else { return [] }; return study?.draft.evidence?.filter { $0.phrase == active.phrase } ?? [] }
    func nextEvidenceImage() {
        let group = activeEvidenceGroup
        guard !group.isEmpty, let index = group.firstIndex(where: { $0.id == activeEvidence?.id }) else { return }
        pinEvidence(group[(index + 1) % group.count])
    }
    func resolveEvidence(_ reference: KeyImageReference) -> Int? {
        guard reference.studyUID == study?.studyUID else { return nil }
        if let uid = reference.sopInstanceUID, !uid.isEmpty, let frame = reference.frame {
            return frames.firstIndex { $0.backend?.sopInstanceUID == uid && $0.backend?.frame == frame }
        }
        return frames.firstIndex { $0.backend?.id == reference.imageID }
    }
    @discardableResult func syncCurrentDraft(studyID: String? = nil, claimToken: String? = nil) async -> Bool {
        guard !syncingDraft else { return false }
        guard let value = studies.first(where: { $0.id == (studyID ?? selectedID) }), backend.entries.contains(where: { $0.study_uid == value.studyUID }) else { error = "This study has no clinic worklist entry yet."; return false }
        syncingDraft = true; defer { syncingDraft = false }
        do {
            let revision = try await backend.saveDraft(value, claimToken: claimToken)
            if let i = studies.firstIndex(where: { $0.id == value.id }) { studies[i].backendDraftRevision = revision; studies[i].backendDraftDirty = studies[i].draft != value.draft; studies[i].workflowStatus = "draft"; save() }
            await backend.refresh(); notify("Evaluation draft saved to clinic backend"); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadClinicDraft() async {
        guard let value = study, value.backendDraftDirty != true else { return }
        do {
            let remote = try await backend.draft(uid: value.studyUID)
            guard let i = studies.firstIndex(where: { $0.id == value.id }), studies[i].backendDraftDirty != true else { return }
            if studies[i].backendDraftRevision != remote.revision {
                var draft = ReportDraft(); draft.document = remote.document; draft.evidence = remote.evidence; draft.purpose = "evaluation"
                studies[i].replaceDraft(draft, fromClinic: true); studies[i].templateID = remote.template_id; studies[i].backendDraftRevision = remote.revision; save()
            }
        } catch { self.error = error.localizedDescription }
    }
    func refreshWorklist() async {
        guard !refreshingWorklist else { return }; refreshingWorklist = true; defer { refreshingWorklist = false }
        if !engine.isConnected { await engine.connect() }
        if engine.isConnected {
            do {
                var result: [EngineStudy] = [], offset = 0
                while true {
                    let page = try JSONDecoder().decode(EngineStudyList.self, from: await engine.request("/studies", body: ["search": "", "offset": offset, "limit": 200]))
                    result += page.studies; offset += page.studies.count
                    if !page.hasMore || page.studies.isEmpty { break }
                }
                worklistStudies = result
                observeIncomingStudies(result)
            } catch { engine.isConnected = false; engine.lastError = error.localizedDescription }
        }
        await backend.refresh()
        if backend.isConnected {
            if let shared = try? await backend.remoteTemplates() {
                for template in shared {
                    if let i = templates.firstIndex(where: { $0.id == template.id }) {
                        if templates[i].locallyModified != true && (template.revision ?? 0) > (templates[i].revision ?? 0) { templates[i] = template }
                    } else { templates.append(template) }
                }
            }
        }
    }
    func watchWorklist() async {
        guard worklistTask == nil else { return }
        worklistTask = Task { await monitorWorklist() }
    }
    private func monitorWorklist() async {
        while !Task.isCancelled {
            await refreshWorklist()
            await processIncomingStudies()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }
}
