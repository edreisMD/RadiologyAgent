import SwiftUI
import RadAgentCore

struct WorklistView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { WorklistContent(backend: model.backend).environmentObject(model) }
}
private struct WorklistContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var backend: ClinicClient
    @State private var query = ""
    @State private var filter = "All"
    var rows: [WorklistRow] {
        var result = model.worklistStudies.map { native -> WorklistRow in
            let entry = backend.entries.first { $0.study_uid == native.studyUID }
            let saved = model.studies.first { $0.studyUID == native.studyUID }
            let incoming = model.incomingQueue.studies[native.studyUID]
            let savedStatus = saved?.backendDraftDirty == true && saved?.workflowStatus == "draft" ? "draft" : entry?.status ?? saved?.workflowStatus ?? "new"
            let status = incoming.flatMap { $0.status == .existing ? nil : $0.status.rawValue } ?? savedStatus
            return WorklistRow(id: native.studyUID, name: native.patientName, description: native.title, modality: native.modality, status: status, priority: entry?.priority ?? "routine", native: native, entry: entry, incoming: incoming, hasDraft: saved?.workflowStatus == "draft" || entry?.status == "draft")
        }
        result += backend.entries.filter { entry in !result.contains { $0.id == entry.study_uid } }.map { WorklistRow(id: $0.study_uid, name: $0.patient_name, description: $0.description, modality: $0.modality, status: "awaiting images", priority: $0.priority, native: nil, entry: $0) }
        return result.filter { row in (filter == "All" || (filter == "To read" ? !row.hasDraft : row.hasDraft || row.status == "draft")) && (query.isEmpty || "\(row.name) \(row.description) \(row.entry?.accession ?? "")".localizedCaseInsensitiveContains(query)) }.sorted {
            if ($0.priority == "urgent") != ($1.priority == "urgent") { return $0.priority == "urgent" }
            let first = $0.incoming?.firstSeen.timeIntervalSince1970 ?? $0.entry?.received_at ?? 0, second = $1.incoming?.firstSeen.timeIntervalSince1970 ?? $1.entry?.received_at ?? 0
            return first == second ? $0.id < $1.id : first > second
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Worklist").font(.system(size: 25, weight: .medium)); Spacer(); Button("Templates") { model.showTemplates = true }.buttonStyle(FlatButton()); IconButton(symbol: "arrow.clockwise", help: "Refresh worklist") { Task { await model.refreshWorklist() } } }
            HStack(spacing: 18) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted); TextField("Find patient or study", text: $query).textFieldStyle(.plain) }.padding(11).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                Picker("Filter", selection: $filter) { ForEach(["All", "To read", "Drafts"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 120)
            }.font(.system(size: 12))
            HStack { Text("Patient / study"); Spacer(); Text("Modality").frame(width: 70); Text("Status").frame(width: 125, alignment: .leading) }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(rows) { row in
                        Button { open(row) } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 7) { HStack { Text(row.name.isEmpty ? "Patient \(row.entry?.patient_id ?? "")" : row.name).font(.system(size: 14, weight: .medium)); if row.priority == "urgent" { Text("Urgent").font(.system(size: 10)).foregroundStyle(Theme.amber) } }; Text(row.description).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                                Spacer()
                                Text(row.modality).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 70)
                                Text(row.statusLabel).font(.system(size: 12)).foregroundStyle(row.status == "attention" ? Theme.amber : Theme.muted).frame(width: 125, alignment: .leading).help(row.incoming?.issue ?? row.statusLabel)
                            }.padding(15).background(Theme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(HoverButton()).disabled(model.isRunning || row.native == nil)
                            .contextMenu {
                                if row.incoming?.result == nil && ["attention", "retry"].contains(row.status) {
                                    Button("Retry automatic draft") { model.retryIncomingStudy(row.id) }
                                }
                                if row.incoming?.status == .existing && !row.hasDraft {
                                    Button("Queue evaluation draft") { model.retryIncomingStudy(row.id) }
                                }
                            }
                    }
                    if rows.isEmpty { Text("No studies in this view.").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(40) }
                }
            }
            HStack {
                Text(model.incomingSummary).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Toggle("Draft new studies automatically", isOn: $model.autoDraftEnabled).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).onChange(of: model.autoDraftEnabled) { _, value in model.setAutomaticDrafting(value) }.help("Watches Horos while Radiology Agent is running, including when its window is closed. Pausing stops new jobs; the current draft finishes.")
            }
            if let error = backend.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber) }
            if let error = model.incomingError { Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber) }
        }.padding(30).task { await model.refreshWorklist() }
    }
    func open(_ row: WorklistRow) {
        guard let native = row.native else { return }
        Task {
            await model.openEngineStudy(native)
            guard model.study?.studyUID == native.studyUID else { return }
            if let entry = row.entry, let i = model.currentIndex {
                model.studies[i].tags = entry.tags
                model.studies[i].backendRevision = entry.revision
                if model.studies[i].backendDraftDirty != true { model.studies[i].workflowStatus = entry.status }
                model.save()
            }
            if row.entry?.status == "draft" { await model.loadClinicDraft() }
        }
    }
}
private struct WorklistRow: Identifiable {
    let id: String
    let name: String
    let description: String
    let modality: String
    let status: String
    let priority: String
    let native: EngineStudy?
    let entry: WorklistEntry?
    var incoming: IncomingStudy? = nil
    var hasDraft = false
    var statusLabel: String {
        if let incoming, incoming.status != .existing { return incoming.status.label }
        return status == "draft" ? "Draft for evaluation" : status.capitalized
    }
}
