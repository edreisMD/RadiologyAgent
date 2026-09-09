import SwiftUI

@main struct RadAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @AppStorage("useSharedCodexWorkspace") private var useSharedCodexWorkspace = true
    var body: some Scene {
        Window("Radiology Agent", id: "workspace") {
            Group {
                if useSharedCodexWorkspace {
                    SharedWorkspaceView().frame(minWidth: 900, minHeight: 680)
                } else {
                    WorkspaceView().environmentObject(model)
                        .task { await model.startEngine() }
                }
            }
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Study") { model.newStudy() }.keyboardShortcut("n").disabled(useSharedCodexWorkspace || model.isRunning)
                Button("Import Images…") { model.importImages() }.keyboardShortcut("o").disabled(useSharedCodexWorkspace || model.isRunning)
                Button("Import DICOM Folder…") { model.importImages(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(useSharedCodexWorkspace || model.isRunning)
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.showConnections = true }.keyboardShortcut(",").disabled(useSharedCodexWorkspace) }
            CommandMenu("Study") {
                Toggle("Shared Codex Workspace", isOn: $useSharedCodexWorkspace)
                Divider()
                Button("Copy Draft") { model.copyDraft() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(useSharedCodexWorkspace)
                Button("Export Draft…") { model.exportDraft() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(useSharedCodexWorkspace)
                Button("Draft History") { model.showHistory = true }.disabled(useSharedCodexWorkspace)
                Divider()
                Button("Connect Horos…") { model.showHoros = true }.disabled(useSharedCodexWorkspace || model.isRunning)
                Button("Study Library…") { model.showLibrary = true }.keyboardShortcut("l").disabled(useSharedCodexWorkspace)
                Divider()
                Button("Stop Agent") { model.stop() }.keyboardShortcut(".").disabled(useSharedCodexWorkspace || !model.isRunning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows { window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(Theme.bg) }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = NSApplication.shared.windows.first, let view = window.contentView else { return }
                window.setContentSize(NSSize(width: 1440, height: 900)); view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}
