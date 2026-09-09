import SwiftUI
import RadAgentCore

struct WorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("conversationVisible") private var conversationVisible = true
    @AppStorage("workspaceLayout") private var layout = "Split"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer().frame(width: 65)
                IconButton(symbol: "sidebar.left", help: "Toggle study sidebar") { withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() } }
                Text("Radiology Agent").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if let study = model.study {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(study.patientLabel).font(.system(size: 13, weight: .medium))
                        if let id = study.patientID, !id.isEmpty { Text("ID \(id)\(study.accession.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    }
                    Text(study.title).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                IconButton(symbol: "bubble.left", help: conversationVisible ? "Hide conversation" : "Show conversation", active: conversationVisible) { conversationVisible.toggle() }
                IconButton(symbol: "square.stack", help: "Open study") { model.showLibrary = true }
            }.padding(.horizontal, 16).frame(height: 51)
            Rule()
            HStack(spacing: 0) {
                if sidebarVisible { SidebarView().frame(width: 196); Rectangle().fill(Theme.line).frame(width: 1) }
                if model.showingWorklist { WorklistView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { HSplitView {
                    if conversationVisible { ChatView().frame(minWidth: 300, idealWidth: 360, maxWidth: 480) }
                    VStack(spacing: 0) {
                        HStack(spacing: 20) {
                            ForEach(["Images", "Report"], id: \.self) { tab in
                                Button { layout = tab } label: {
                                    Text(tab).font(.system(size: 12, weight: .medium)).foregroundStyle(layout == tab || layout == "Split" ? Theme.text : Theme.muted)
                                }.buttonStyle(HoverButton())
                            }
                            Spacer()
                            IconButton(symbol: "rectangle.split.1x2", help: "Show images and report", active: layout == "Split") { layout = "Split" }
                        }.padding(.horizontal, 18).frame(height: 43)
                        Rule()
                        if layout == "Split" {
                            VSplitView {
                                ViewerView().frame(minHeight: 260, idealHeight: 440)
                                ReportView().frame(minHeight: 190, idealHeight: 300)
                            }
                        } else if layout == "Images" { ViewerView() }
                        else { ReportView() }
                    }.frame(minWidth: 420, idealWidth: 640)
                }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { Text(toast).font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 9).background(Theme.raised, in: Capsule()).padding(14).allowsHitTesting(false) }
        }
        .background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 690)
        .sheet(isPresented: $model.showConnections) { ConnectionsView().environmentObject(model) }
        .sheet(isPresented: $model.showLibrary) { StudyLibraryView().environmentObject(model) }
        .sheet(isPresented: $model.showHoros) { HorosConnectionView().environmentObject(model) }
        .sheet(isPresented: $model.showTemplates) { TemplateManagerView().environmentObject(model) }
        .sheet(isPresented: $model.showHistory) { DraftHistoryView().environmentObject(model) }
        .alert("Radiology Agent", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.save() }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    var visibleStudies: [StudyRecord] {
        model.studies.filter { study in
            (study.id == model.selectedID || study.engineStudyID != nil || (!study.isDemo && !study.draft.isEmpty)) &&
            (search.isEmpty || "\(study.title) \(study.patientLabel)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.showLibrary = true } label: { Label("Open study", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(FlatButton()).padding(14).disabled(model.isRunning)
            if visibleStudies.count > 6 || !search.isEmpty {
                TextField("Search studies", text: $search).textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 19).padding(.bottom, 14)
            }
            Button { model.showingWorklist = true } label: { Label("Worklist", systemImage: "tray").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 19).padding(.vertical, 10) }.buttonStyle(HoverButton())
            Text("Recent studies").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 19).padding(.vertical, 12)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(visibleStudies) { study in
                        Button { model.selectStudy(study.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(study.patientLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(study.title).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                                if study.isDemo { Text("Synthetic demo").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(11).background(study.id == model.selectedID ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(HoverButton()).disabled(model.isRunning)
                    }
                }.padding(.horizontal, 9)
            }
            Spacer(minLength: 16)
            Button { model.showConnections = true } label: { Label("Settings", systemImage: "gearshape").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(19) }.buttonStyle(HoverButton())
        }.background(Theme.sidebar)
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        if model.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 15) {
                                Text("How can I help with this study?").font(.system(size: 23, weight: .medium)).tracking(-0.5)
                                Text(model.frames.isEmpty ? "Open a study to begin." : "Review the images, dictate your findings, or ask for a draft.").font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(4)
                                if !model.frames.isEmpty {
                                    HStack(spacing: 8) {
                                        suggestion("Draft report", "Create a draft for evaluation in \(model.language) based on the available images and supplied context.")
                                        suggestion("Review images", "Review the available study images. State which images you reviewed and any limitations.")
                                    }.padding(.top, 7)
                                }
                            }.padding(.top, 72).padding(.bottom, 25)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 9) {
                                if message.role == "assistant" {
                                    HStack(spacing: 7) { Image(systemName: "sparkle").font(.system(size: 12)); Text("Radiology Agent").font(.system(size: 12, weight: .medium)); if message.engine == "demo" { Text("Synthetic demo").font(.system(size: 10)).foregroundStyle(Theme.muted) } }.foregroundStyle(Theme.muted)
                                }
                                Text(.init(message.text)).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                            }.padding(message.role == "user" ? 14 : 0).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 12)).id(message.id)
                        }
                        if !model.activities.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) { ForEach(Array(model.activities.enumerated()), id: \.offset) { _, event in Text(event).font(.system(size: 11)).foregroundStyle(Theme.muted) } }.padding(.vertical, 8)
                            } label: { Text("\(model.activities.count) actions").font(.system(size: 11)).foregroundStyle(Theme.muted) }.tint(Theme.muted)
                        }
                        if model.isRunning { HStack(spacing: 9) { ProgressView().controlSize(.small); Text(model.activity).font(.system(size: 12)).foregroundStyle(Theme.muted) } }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                }
                .onChange(of: model.messages.count) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.activity) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
            }
            VStack(alignment: .leading, spacing: 14) {
                TextField("Ask or dictate findings…", text: $model.composer, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14)).lineLimit(2...6).focused($focused).onSubmit { if !NSEvent.modifierFlags.contains(.shift) { model.send() } }.disabled(model.isRunning)
                HStack(spacing: 8) {
                    IconButton(symbol: "plus", help: "Open study") { model.showLibrary = true }.disabled(model.isRunning)
                    Text(model.liveMode ? "GPT-6 Astra" : "Offline").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Menu { Button("English") { model.language = "English" }; Button("Português") { model.language = "Português" } } label: { Text(model.language == "English" ? "EN" : "PT").font(.system(size: 10)).foregroundStyle(Theme.muted) }.menuStyle(.borderlessButton).modifier(ControlHover()).frame(width: 40)
                    Button { model.isRunning ? model.stop() : model.send() } label: { Image(systemName: model.isRunning ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bg).frame(width: 30, height: 30).background(Theme.text, in: Circle()) }.buttonStyle(HoverButton()).accessibilityLabel(model.isRunning ? "Stop agent" : "Send message").disabled(!model.isRunning && model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(15).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(focused ? Theme.muted.opacity(0.4) : Theme.line)).padding(22)
        }.background(Theme.bg)
    }
    func suggestion(_ title: String, _ prompt: String) -> some View {
        Button { model.send(prompt) } label: { Text(title).font(.system(size: 12)).foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.vertical, 9).background(Theme.panel, in: Capsule()) }.buttonStyle(HoverButton())
    }
}
