import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var key = ""
    @State private var modelID = "gpt-6-astra"
    @State private var error: String?
    @State private var hasOverride = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("Settings").font(.system(size: 20, weight: .medium)); Spacer(); IconButton(symbol: "xmark", help: "Close settings") { dismiss() } }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Astra").font(.system(size: 13, weight: .medium)); Spacer(); Text(APIConfiguration.isConfigured ? "Connected" : "Not configured").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Text(hasOverride ? "Using your saved key override." : "Using the default connection from .env.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                DisclosureGroup("Connection options") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Optional API key override", text: $key).textFieldStyle(.roundedBorder)
                        Text("An override is stored in macOS Keychain. Leave blank to keep the current connection.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        TextField("Model", text: $modelID).textFieldStyle(.roundedBorder)
                        if hasOverride { Button("Use default connection") { do { try APIKeyStore.save(""); hasOverride = false; model.liveMode = APIConfiguration.isConfigured } catch { self.error = error.localizedDescription } }.buttonStyle(HoverButton()).foregroundStyle(Theme.muted) }
                    }.padding(.top, 14)
                }.font(.system(size: 12)).tint(Theme.muted)
            }
            Rule()
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Horos").font(.system(size: 13, weight: .medium)); Text(model.engine.isConnected ? "Connected to your study library" : "Backend unavailable").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Manage") { dismiss(); Task { try? await Task.sleep(for: .milliseconds(250)); model.showHoros = true } }.buttonStyle(FlatButton())
            }
            Text("Agent requests send the conversation and requested images to OpenAI. Reports stay as drafts for evaluation.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber) }
            HStack { Spacer(); Button("Done") { save() }.buttonStyle(FlatButton(primary: true)) }.disabled(model.isRunning)
        }.padding(28).frame(width: 470).background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .onAppear { hasOverride = !APIKeyStore.read().isEmpty; modelID = model.modelID }
    }
    func save() {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a model ID."; return }
        do {
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try APIKeyStore.save(key) }
            model.liveMode = APIConfiguration.isConfigured
            model.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(model.modelID, forKey: "modelID")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
