import SwiftUI
import WebKit

/// The exact same DICOM viewer/report workspace used by the Codex plugin.
/// No remote website, separate model client, or screenshot import is involved.
struct SharedWorkspaceView: View {
    @State private var url: URL?
    @State private var failure: String?
    var body: some View {
        Group {
            if let url { SharedWorkspaceWebView(url: url) }
            else if let failure {
                VStack(spacing: 16) {
                    BrandMark(size: 64)
                    Text("Connect the shared workspace").font(.title3)
                    Text(failure).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Reconnect") { Task { await connect() } }.buttonStyle(FlatButton())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) { ProgressView().controlSize(.small); BrandMark(size: 56); Text("Opening your reading room…").font(.system(size: 12)).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Theme.bg).task { await connect() }
    }
    @MainActor private func connect() async {
        failure = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let root = FileManager.default.homeDirectoryForCurrentUser
                let python = root.appendingPathComponent("Library/Application Support/RadAgent/connector/runtime/bin/python")
                let installed = root.appendingPathComponent("plugins/horos-connector/scripts/workspace.py")
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("HorosConnector/scripts/workspace.py")
                let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? (FileManager.default.fileExists(atPath: installed.path) ? installed : nil)
                guard FileManager.default.isExecutableFile(atPath: python.path), let script, FileManager.default.fileExists(atPath: script.path) else {
                    throw NSError(domain: "RadAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install the Horos Connector runtime first. Radiology Agent and Codex then share the same studies, viewer actions, and evaluation drafts."])
                }
                let process = Process(); let output = Pipe(); let errors = Pipe()
                process.executableURL = python; process.arguments = [script.path]
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = json["url"] as? String, let url = URL(string: value),
                      url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1024...65535).contains(port) else {
                    throw NSError(domain: "RadAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "The local workspace could not start. Open Horos and verify the connector installation."])
                }
                return url
            }.value
            url = result
        } catch { failure = error.localizedDescription }
    }
}

private struct SharedWorkspaceWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(origin: url) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        init(origin: URL) { self.origin = origin }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            decisionHandler(target.scheme == origin.scheme && target.host == origin.host && target.port == origin.port ? .allow : .cancel)
        }
    }
}

private struct BrandMark: View {
    var size: CGFloat
    var body: some View {
        if let url = Bundle.main.url(forResource: "RadiologyAgentLogo", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}
