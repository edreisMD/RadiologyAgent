import SwiftUI
import UniformTypeIdentifiers
import RadAgentCore

struct TemplateManagerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: String?
    @State private var name = ""
    @State private var modalities = ""
    @State private var keywords = ""
    @State private var document = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Report templates").font(.system(size: 20, weight: .medium)); Spacer(); Button("Import document…") { importDocument() }.buttonStyle(FlatButton()); Button("New") { selected = nil; name = "New template"; modalities = ""; keywords = ""; document = "FINDINGS\n[Image observations]\n\nIMPRESSION\n[Interpretation]" }.buttonStyle(FlatButton()); Button("Done") { dismiss() }.buttonStyle(FlatButton()) }.padding(22)
            Rule()
            HSplitView {
                List(model.templates) { template in Button { load(template) } label: { Text(template.name).font(.system(size: 12)).padding(.vertical, 6) }.buttonStyle(HoverButton()) }.frame(width: 190)
                VStack(spacing: 14) {
                    TextField("Template name", text: $name).textFieldStyle(.roundedBorder)
                    HStack { TextField("Modalities: CR, DX", text: $modalities); TextField("Match study: chest, torax", text: $keywords) }.textFieldStyle(.roundedBorder)
                    DocumentEditor(text: $document).background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Text("Templates provide structure; findings require image review.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        Spacer()
                        if model.backend.isConnected { Button("Share to clinic") { share() }.buttonStyle(FlatButton()) }
                        Button("Save template") { save() }.buttonStyle(FlatButton(primary: true))
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.isEmpty)
                }.padding(20).frame(minWidth: 480)
            }
        }.frame(width: 900, height: 640).background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .onAppear { if let template = model.selectedTemplate ?? model.templates.first { load(template) } }
    }
    func load(_ value: ReportTemplate) { selected = value.id; name = value.name; modalities = value.modalities.joined(separator: ", "); keywords = value.keywords.joined(separator: ", "); document = value.document }
    func save() {
        let list: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        var template = ReportTemplate(id: selected ?? UUID().uuidString, name: name, modalities: list(modalities).map { $0.uppercased() }, keywords: list(keywords), document: document)
        template.locallyModified = true
        if let i = model.templates.firstIndex(where: { $0.id == template.id }) { template.revision = model.templates[i].revision; model.templates[i] = template } else { model.templates.append(template) }
        selected = template.id; model.persistTemplates(); model.notify("Template saved")
    }
    func importDocument() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .rtf, UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 5_000_000 else { throw RadError.message("Use a template smaller than 5 MB.") }
            let text: String
            if ["docx", "rtf"].contains(url.pathExtension.lowercased()) { text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string }
            else { text = try String(contentsOf: url, encoding: .utf8) }
            selected = nil; name = url.deletingPathExtension().lastPathComponent; document = text; modalities = ""; keywords = ""
        } catch { model.error = error.localizedDescription }
    }
    func share() {
        save()
        guard let template = model.templates.first(where: { $0.id == selected }) else { return }
        Task {
            do {
                let shared = try await model.backend.saveTemplate(template)
                if let i = model.templates.firstIndex(where: { $0.id == shared.id }) { model.templates[i] = shared }
                model.persistTemplates(); model.notify("Template shared to clinic")
            } catch { model.error = error.localizedDescription }
        }
    }
}
