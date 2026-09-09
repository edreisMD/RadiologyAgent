import AppKit
import Darwin
import RadAgentCore

extension AppModel {
    var incomingStore: IncomingQueueStore { IncomingQueueStore(directory: storage.directory) }

    func loadIncomingQueue() {
        do {
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            incomingLock = Darwin.open(storage.directory.appendingPathComponent("incoming-worker.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard incomingLock >= 0, flock(incomingLock, LOCK_EX | LOCK_NB) == 0 else { throw RadError.message("Another Radiology Agent instance is watching this worklist.") }
            incomingQueue = try incomingStore.load(); incomingQueue.recover()
            autoDraftEnabled = incomingQueue.enabled; incomingReady = true
            try incomingStore.save(incomingQueue)
        } catch { incomingReady = false; incomingError = "Automatic intake paused: \(error.localizedDescription) The saved queue was preserved." }
    }
    @discardableResult func persistIncomingQueue() -> Bool {
        guard incomingReady else { return false }
        do { try incomingStore.save(incomingQueue); return true }
        catch { incomingReady = false; incomingError = "Automatic intake paused because its queue could not be saved: \(error.localizedDescription)"; return false }
    }
    func setAutomaticDrafting(_ enabled: Bool) {
        incomingQueue.enabled = enabled; autoDraftEnabled = enabled
        persistIncomingQueue()
    }
    func observeIncomingStudies(_ snapshot: [EngineStudy]) {
        guard incomingReady else { return }
        incomingQueue.observe(snapshot)
        persistIncomingQueue()
    }
    func retryIncomingStudy(_ uid: String) {
        incomingQueue.retry(uid); persistIncomingQueue()
    }
    var incomingSummary: String {
        if !incomingReady { return "Automatic intake paused" }
        if incomingStudyUID != nil { return incomingActivity }
        if !autoDraftEnabled { return "Automatic drafting paused" }
        if !engine.isConnected { return "Waiting for Horos" }
        if !APIConfiguration.isConfigured { return "Waiting for Astra connection" }
        if backend.configured && !backend.isConnected { return "Waiting for clinic API" }
        let count = incomingQueue.studies.values.filter { $0.isPending }.count
        return count == 0 ? "Watching for new studies" : "\(count) studies pending"
    }

    func processIncomingStudies() async {
        guard incomingReady, engine.isConnected else { return }
        let available = Set(worklistStudies.map(\.studyUID))
        // API-triggered work is still supported, including an explicitly queued baseline study.
        if backend.isConnected {
            for entry in backend.entries where (entry.status == "queued" || (entry.status == "processing" && (entry.lease_expires ?? .greatestFiniteMagnitude) <= Date().timeIntervalSince1970)) && entry.received_complete && entry.tags.contains("radagent-draft") {
                if incomingQueue.studies[entry.study_uid]?.status == .existing { incomingQueue.retry(entry.study_uid) }
            }
            let unregistered = incomingQueue.studies.values.filter { job in job.status != .existing && available.contains(job.id) && !backend.entries.contains(where: { $0.study_uid == job.id }) }
            for job in unregistered.prefix(5) {
                // Use an explicit lookup; UID identity is shared by both APIs.
                if !backend.entries.contains(where: { $0.study_uid == job.id }) {
                    do { let entry = try await backend.receiveIncoming(job.study, ready: false); backend.entries.append(entry) }
                    catch { incomingError = error.localizedDescription }
                }
            }
        }
        let pending = incomingQueue.studies.values.filter { $0.status != .queued && incomingQueue.needsInventory($0.id) && available.contains($0.id) }.sorted { ($0.lastInventoryCheck ?? .distantPast) < ($1.lastInventoryCheck ?? .distantPast) }.prefix(5)
        for job in pending {
            incomingQueue.studies[job.id]?.lastInventoryCheck = Date()
            do {
                let detail = try await engine.detail(job.study.id, expectedUID: job.id)
                incomingQueue.confirmInventory(detail)
            } catch { incomingError = "Waiting for the Horos image inventory: \(error.localizedDescription)" }
        }
        guard persistIncomingQueue(), incomingTask == nil else { return }
        // Recovery delivers the already generated candidate without charging for another run.
        if let job = incomingQueue.studies.values.first(where: { $0.status == .saving && $0.result != nil && available.contains($0.id) && ($0.nextAttempt ?? .distantPast) <= Date() }) {
            launchIncoming(job, resume: true); return
        }
        guard autoDraftEnabled, APIConfiguration.isConfigured, !backend.configured || backend.isConnected,
              let job = incomingQueue.next(available: available) else { return }
        if selectedID == studies.first(where: { $0.studyUID == job.id })?.id && isRunning { return }
        launchIncoming(job, resume: false)
    }

    private func launchIncoming(_ value: IncomingStudy, resume: Bool) {
        incomingStudyUID = value.id; incomingActivity = resume ? "Saving evaluation draft" : "Preparing evaluation draft"; incomingError = nil
        incomingTask = Task {
            defer { incomingStudyUID = nil; incomingTask = nil }
            do {
                if !resume { try await generateIncoming(value.id) }
                try Task.checkCancellation()
                try await deliverIncoming(value.id)
            } catch {
                if let job = incomingQueue.studies[value.id], let token = job.claimToken, job.result == nil {
                    try? await backend.releaseClaim(uid: value.id, token: token, failed: job.attempts >= 3)
                }
                incomingQueue.failed(value.id, message: error is CancellationError ? "Drafting was interrupted; it will resume after restart." : error.localizedDescription)
                persistIncomingQueue()
            }
        }
    }

    private func generateIncoming(_ uid: String) async throws {
        guard var job = incomingQueue.studies[uid] else { return }
        if let local = studies.first(where: { $0.studyUID == uid }), local.workflowStatus == "draft" || local.backendDraftDirty == true {
            job.status = .attention; job.issue = "An existing report was preserved. Open this study to review or continue drafting."; incomingQueue.studies[uid] = job; persistIncomingQueue(); return
        }
        let detail = try await engine.detail(job.study.id, expectedUID: uid)
        guard IncomingStudyQueue.signature(detail) == job.inventory else {
            incomingQueue.studies[uid]?.status = .receiving; incomingQueue.studies[uid]?.changedAt = Date(); incomingQueue.studies[uid]?.inventory = nil
            persistIncomingQueue(); return
        }
        job.usesClinic = backend.configured
        if job.usesClinic {
            var entry = try await backend.receiveIncoming(job.study, ready: true)
            if entry.status == "attention" && job.attempts == 0 { entry = try await backend.requeue(entry) }
            if ["draft", "reviewed"].contains(entry.status) {
                job.status = .attention; job.issue = "A clinic report already exists. Open the study to review it."; incomingQueue.studies[uid] = job; persistIncomingQueue(); return
            }
            if let token = job.claimToken, (try? await backend.renewClaim(uid: uid, token: token)) != nil { }
            else { job.claimToken = try await backend.claim(entry).claim_token }
            job.clinicRevision = 0
        }
        job.status = .processing; job.attempts += 1; job.issue = nil
        job.originalDraft = studies.first(where: { $0.studyUID == uid })?.draft
        incomingQueue.studies[uid] = job
        guard persistIncomingQueue() else { throw RadError.message("The queue could not be saved before starting Astra.") }
        let client = AgentClient(), key = APIConfiguration.key, model = modelID, reportLanguage = language
        let claimToken = job.claimToken, usesClinic = job.usesClinic, engineID = detail.study.id
        let session = AutomaticDraftSession(detail: detail, templates: templates, render: { [engine] image, center, width in
            try await engine.render(studyID: engineID, imageID: image.id, center: center, width: width)
        }, request: { [backend] input in
            if usesClinic, let claimToken { try await backend.renewClaim(uid: uid, token: claimToken) }
            return try await client.request(apiKey: key, model: model, input: input, allowHoros: true, toolsOverride: AutomaticDraftSession.tools)
        }, progress: { [weak self] text in self?.incomingActivity = text })
        let result = try await session.run(language: reportLanguage)
        let after = try await engine.detail(engineID, expectedUID: uid)
        guard IncomingStudyQueue.signature(after) == job.inventory else { throw RadError.message("Images changed during drafting. Waiting to review the updated study.") }
        incomingQueue.studies[uid]?.result = result; incomingQueue.studies[uid]?.status = .saving
        guard persistIncomingQueue() else { throw RadError.message("The generated draft could not be stored. Automatic work is paused.") }
    }

    private func deliverIncoming(_ uid: String) async throws {
        guard var job = incomingQueue.studies[uid], let result = job.result, job.status == .saving else { return }
        let current = try await engine.detail(job.study.id, expectedUID: uid)
        guard IncomingStudyQueue.signature(current) == job.inventory else {
            job.status = .attention; job.issue = "Images changed after drafting. The candidate was retained in the incoming queue for review."; incomingQueue.studies[uid] = job; persistIncomingQueue(); return
        }
        var local = studies.first(where: { $0.studyUID == uid }) ?? StudyRecord(id: StudyIdentity.groupedID(studyUID: uid, fallback: job.study.id), title: job.study.title, patientLabel: job.study.patientName, modality: job.study.modality, studyUID: uid)
        if job.conflicts(with: local) {
            // Keep the candidate in history; never replace edits made during the model run.
            if !local.history.contains(result.report) { local.history.append(result.report) }
            if local.history.count > 30 { local.history.removeFirst(local.history.count - 30) }
            local.automaticDraftJobID = job.jobID
            local.messages.append(ChatMessage(role: "assistant", text: "An automatic evaluation draft is available in History. Your current report was preserved.", engine: modelID))
            try upsertIncomingRecord(local)
            job.status = .attention; job.issue = "Your report was preserved; the automatic draft is in History."
            if let token = job.claimToken { try? await backend.releaseClaim(uid: uid, token: token, failed: true) }
            incomingQueue.studies[uid] = job; persistIncomingQueue(); return
        }
        if local.automaticDraftJobID != job.jobID {
            local.engineStudyID = job.study.id; local.patientID = job.study.patientID; local.accession = job.study.accession
            local.studyDate = job.study.date > 0 ? Date(timeIntervalSince1970: job.study.date) : nil
            local.replaceDraft(result.report); local.templateID = result.templateID; local.automaticDraftJobID = job.jobID
            local.messages.append(ChatMessage(role: "assistant", text: "Automatic Draft for evaluation prepared. Reviewed \(result.reviewedFrames) of \(result.totalFrames) available frames.\(result.reviewedFrames < result.totalFrames ? " Coverage is incomplete and needs further review." : "")" + (result.message.isEmpty ? "" : "\n\n" + result.message), engine: modelID))
            try upsertIncomingRecord(local)
        }
        if job.usesClinic && !job.clinicSaved {
            // Reconcile an uncertain prior save before retrying; never re-run the model.
            if let remote = try? await backend.draft(uid: uid) {
                guard remote.document == result.report.body, remote.evidence == (result.report.evidence ?? []) else {
                    job.status = .attention; job.issue = "The clinic report changed. The local evaluation draft was preserved."; incomingQueue.studies[uid] = job; persistIncomingQueue(); return
                }
                job.clinicRevision = remote.revision
            } else {
                await backend.refresh()
                guard let entry = backend.entries.first(where: { $0.study_uid == uid }), backend.isConnected else { throw RadError.message("Waiting for the clinic API to save the completed draft.") }
                if let token = job.claimToken, (try? await backend.renewClaim(uid: uid, token: token)) != nil { }
                else {
                    job.claimToken = try await backend.claim(entry).claim_token
                    incomingQueue.studies[uid] = job
                    guard persistIncomingQueue() else { throw RadError.message("Could not save the draft ownership token.") }
                }
                var candidate = local; candidate.draft = result.report; candidate.backendDraftRevision = 0
                job.clinicRevision = try await backend.saveDraft(candidate, claimToken: job.claimToken)
            }
            job.clinicSaved = true
            if let i = studies.firstIndex(where: { $0.studyUID == uid }) {
                studies[i].backendDraftRevision = job.clinicRevision
                studies[i].backendDraftDirty = studies[i].draft != result.report
                try storage.save(WorkspaceSnapshot(studies: studies, selectedID: selectedID))
            }
            await backend.refresh()
        }
        job.status = result.reviewedFrames == result.totalFrames ? .draft : .attention
        job.issue = result.reviewedFrames == result.totalFrames ? nil : "Draft available; \(result.reviewedFrames) of \(result.totalFrames) frames reviewed."
        job.claimToken = nil; job.nextAttempt = nil
        incomingQueue.studies[uid] = job; persistIncomingQueue()
        notify("New evaluation draft added to the worklist")
    }

    private func upsertIncomingRecord(_ record: StudyRecord) throws {
        var updated = studies
        if let i = updated.firstIndex(where: { $0.studyUID == record.studyUID }) { updated[i] = record }
        else { updated.append(record) }
        // This throwing save is the delivery boundary. Do not mark a job complete on a failed save.
        try storage.save(WorkspaceSnapshot(studies: updated, selectedID: selectedID))
        studies = updated
    }
}
