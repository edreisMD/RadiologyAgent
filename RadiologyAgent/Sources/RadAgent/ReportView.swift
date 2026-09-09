import SwiftUI
import RadAgentCore

struct ReportView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.study?.isDemo == true ? "Synthetic demo draft" : "Draft for evaluation").font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(model.templates) { template in Button(template.name) { model.applyTemplate(template) } }
                    Divider()
                    Button("Manage templates…") { model.showTemplates = true }
                } label: { Text(model.selectedTemplate?.name ?? "Template").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }.menuStyle(.borderlessButton).modifier(ControlHover()).frame(maxWidth: 160).disabled(model.isRunning)
                Menu {
                    Button("Copy draft") { model.copyDraft() }.disabled(model.study?.draft.isEmpty != false)
                    Button("Export draft…") { model.exportDraft() }.disabled(model.study?.draft.isEmpty != false)
                    Button("Version history") { model.showHistory = true }.disabled(model.isRunning)
                    if model.backend.isConnected { Button("Save draft to clinic") { Task { await model.syncCurrentDraft() } }.disabled(model.isRunning || model.syncingDraft) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.muted) }.menuStyle(.borderlessButton).modifier(ControlHover()).frame(width: 24).help("Report actions")
            }.padding(.horizontal, 20).frame(height: 43)
            DocumentEditor(text: Binding(get: { model.study?.draft.body ?? "" }, set: { model.editDocument($0) }), evidence: model.study?.draft.evidence ?? [], editable: !model.isRunning, hover: { model.hoverEvidence($0) }, pin: { model.pinEvidence($0) })
            Text("Not for medical use, research only.").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.vertical, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DraftHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Draft history").font(.title2); Spacer(); Button("Done") { dismiss() }.buttonStyle(FlatButton()) }
            Text("Agent replacements and restored versions are preserved for this study.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            if model.study?.history.isEmpty != false { ContentUnavailableView("No previous versions", systemImage: "clock.arrow.circlepath", description: Text("Previous drafts appear here when the agent replaces a report.")) }
            else {
                ScrollView { VStack(spacing: 14) { ForEach(Array((model.study?.history ?? []).enumerated().reversed()), id: \.offset) { index, draft in
                    VStack(alignment: .leading, spacing: 10) { HStack { Text("Version \(index + 1) · \(draft.updatedAt.formatted())").font(.system(size: 11, weight: .medium)); Spacer(); Button("Restore") { model.restoreDraft(draft) }.buttonStyle(FlatButton()) }; Text(draft.text).font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled) }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                } } }
            }
        }.padding(25).frame(width: 650, height: 540).background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
    }
}
