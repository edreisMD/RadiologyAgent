import SwiftUI
import RadAgentCore

struct StudyLibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { StudyLibraryContent(engine: model.engine).environmentObject(model) }
}
struct StudyLibraryContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var engine: HorosEngineClient
    @State private var busy = false
    @State private var error: String?
    @State private var node = 0
    @State private var uid = ""
    @State private var accession = ""
    @State private var retrievalStatus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { AgentMark(size: 36); VStack(alignment: .leading, spacing: 4) { Text("Study library").font(.system(size: 24, weight: .medium)); Text("Native DICOM · powered by your Horos database").font(.system(size: 12)).foregroundStyle(Theme.muted) }; Spacer(); IconButton(symbol: "xmark", help: "Close study library") { dismiss() } }
            HStack(spacing: 12) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted); TextField("Patient, study, ID, or accession", text: $engine.query).textFieldStyle(.plain).onSubmit { refresh() } }.padding(11).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                Button("Search") { refresh() }.buttonStyle(FlatButton(primary: true)).disabled(busy || !engine.isConnected)
                IconButton(symbol: "arrow.clockwise", help: "Refresh Horos study library") { refresh() }.disabled(busy)
            }
            HStack { StatusPill(title: engine.isConnected ? "Horos engine connected" : "Engine offline", color: engine.isConnected ? Theme.accent : Theme.amber); Spacer(); Text("\(engine.studies.count) studies").font(.system(size: 11)).foregroundStyle(Theme.muted); if busy { ProgressView().controlSize(.small) } }
            if !engine.isConnected {
                VStack(spacing: 14) { Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 30)).foregroundStyle(Theme.accent); Text("Start the native Horos backend").font(.system(size: 17)); Text(engine.lastError ?? "Install the engine plugin and start Horos in the background.").font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center); Button("Engine setup") { dismiss(); Task { try? await Task.sleep(for: .milliseconds(200)); model.showHoros = true } }.buttonStyle(FlatButton(primary: true)) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack { Text("PATIENT / STUDY"); Spacer(); Text("MODALITY").frame(width: 65); Text("IMAGES").frame(width: 55); Text("DATE").frame(width: 95) }.font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted).padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(engine.studies) { study in
                            Button { busy = true; Task { await model.openEngineStudy(study); busy = false } } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 6) { Text(study.patientName.isEmpty ? "Patient \(study.patientID)" : study.patientName).font(.system(size: 12, weight: .medium)); Text(study.title.isEmpty ? "DICOM study" : study.title).font(.system(size: 11)).foregroundStyle(Theme.muted); Text("ID \(study.patientID) · Accession \(study.accession)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }
                                    Spacer()
                                    Text(study.modality).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent).frame(width: 65)
                                    Text("\(study.imageCount)").font(.system(size: 11, design: .monospaced)).frame(width: 55)
                                    Text(Date(timeIntervalSince1970: study.date).formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 95)
                                }.padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(HoverButton()).disabled(busy || model.isRunning)
                        }
                        if engine.hasMore { Button("Load more studies") { refresh(more: true) }.buttonStyle(FlatButton()).padding(12) }
                        if engine.studies.isEmpty { Text("No studies match this search.").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(35) }
                    }
                }
                DisclosureGroup("Retrieve from PACS") {
                    VStack(alignment: .leading, spacing: 12) {
                        if engine.nodes.isEmpty { Text("No PACS nodes are configured in Horos. Configure your DICOM nodes in Horos once; Radiology Agent will use the same connections.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        else {
                            Picker("DICOM node", selection: $node) { ForEach(engine.nodes) { n in Text("\(n.name) · \(n.aet)").tag(n.index) } }.font(.system(size: 11))
                            HStack { TextField("Study Instance UID", text: $uid); Text("or").foregroundStyle(Theme.muted); TextField("Accession number", text: $accession) }.textFieldStyle(.roundedBorder)
                            HStack { Text("Uses Horos’s DICOM query/retrieve and receiving listener.").font(.system(size: 10)).foregroundStyle(Theme.muted); Spacer(); Button("Retrieve study") { retrieve() }.buttonStyle(FlatButton()).disabled(busy || (uid.isEmpty && accession.isEmpty)) }
                            if let retrievalStatus { Text(retrievalStatus).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                        }
                    }.padding(.top, 12)
                }.font(.system(size: 12)).tint(Theme.muted)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber) }
            Rule()
            Text("Opening a study loads its complete local series inventory. Frames are decoded on demand by Horos; the original DICOM files stay in its database.").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(4)
        }.padding(26).frame(width: 850, height: 620).background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .task { if !engine.isConnected { await engine.connect() } }
    }
    func refresh(more: Bool = false) { busy = true; error = nil; Task { do { if engine.isConnected { try await engine.refreshStudies(more: more) } else { await engine.connect() } } catch { self.error = error.localizedDescription }; busy = false } }
    func retrieve() { busy = true; error = nil; Task { do { retrievalStatus = try await engine.retrieve(node: node, uid: uid, accession: accession); try await engine.refreshStudies() } catch { self.error = error.localizedDescription }; busy = false } }
}

struct HorosConnectionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { EngineSetupView(engine: model.engine).environmentObject(model) }
}
struct EngineSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var engine: HorosEngineClient
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("Horos engine").font(.system(size: 24, weight: .medium)); Text("DICOM and PACS, native to your workspace.").font(.system(size: 12)).foregroundStyle(Theme.muted) }; Spacer(); IconButton(symbol: "xmark", help: "Close engine setup") { dismiss() } }
            StatusPill(title: engine.status, color: engine.isConnected ? Theme.accent : Theme.amber)
            VStack(alignment: .leading, spacing: 16) {
                feature("externaldrive", "Your existing study database", "Browse the studies already in Horos without importing or copying them.")
                feature("square.stack.3d.up", "Every series. Every frame.", "Radiology Agent requests DICOM pixels directly from Horos’s decoder, including compressed images and multiframe instances supported by Horos.")
                feature("slider.horizontal.3", "A shared imaging engine", "Window/level runs on DICOM pixels. Open a series in Horos’s full viewer to measure, manipulate, and verify.")
                feature("network", "Your existing PACS connections", "Query and retrieve through Horos’s configured DICOM nodes and receiving listener.")
            }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            Text("The small backend plugin runs inside Horos. A private connection on this Mac links it to Radiology Agent. Screen Recording and Accessibility permissions are not needed.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
            if let error = error ?? engine.lastError { Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber).lineSpacing(4) }
            HStack {
                if !engine.isConnected { Button(engine.installed ? "Reinstall plugin" : "Install plugin") { do { try engine.installPlugin(); error = "Plugin installed. Restart Horos once, then connect. Your studies remain in the existing database." } catch { self.error = error.localizedDescription } }.buttonStyle(FlatButton()) }
                Spacer()
                Button(engine.isConnected ? "Browse studies" : "Start & connect") {
                    if engine.isConnected { dismiss(); Task { try? await Task.sleep(for: .milliseconds(200)); model.showLibrary = true } }
                    else { Task { do { try engine.launchInBackground(); try await Task.sleep(for: .seconds(1)); await engine.connect() } catch { self.error = error.localizedDescription } } }
                }.buttonStyle(FlatButton(primary: true)).disabled(engine.loading)
            }
        }.padding(28).frame(width: 600).background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .task { await engine.connect() }
    }
    func feature(_ icon: String, _ title: String, _ detail: String) -> some View { HStack(alignment: .top, spacing: 13) { Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 22); VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4) } } }
}
