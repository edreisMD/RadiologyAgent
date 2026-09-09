import AppKit
import RadAgentCore

@MainActor final class HorosEngineClient: ObservableObject {
    @Published var isConnected = false
    @Published var status = "Horos backend not connected"
    @Published var studies: [EngineStudy] = []
    @Published var nodes: [EngineNode] = []
    @Published var hasMore = false
    @Published var loading = false
    @Published var query = ""
    @Published var lastError: String?
    private let session: URLSession
    var installed: Bool { FileManager.default.fileExists(atPath: pluginDestination.path) }
    var pluginDestination: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Horos/Plugins/RadAgentEngine.horosplugin") }
    var connectionFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RadAgent/engine-connection.json") }
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "org.horosproject.horos").isEmpty }
    init() {
        session = PrivateHTTP.session()
    }
    func request(_ route: String, body: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Data {
        guard let data = try? Data(contentsOf: connectionFile), let connection = try? JSONDecoder().decode(EngineConnection.self, from: data) else { throw RadError.message("The Horos backend has not started. Install the engine plugin, then restart Horos once.") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "org.horosproject.horos").contains(where: { Int($0.processIdentifier) == connection.pid }) else { throw RadError.message("The saved engine connection belongs to a closed Horos session. Start Horos and reconnect.") }
        var request = URLRequest(url: try connection.validatedURL(route: route)); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (result, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = ((try? JSONSerialization.jsonObject(with: result)) as? [String: Any])?["error"] as? String
            throw RadError.message(message ?? "The Horos backend could not complete the request.")
        }
        return result
    }
    func connect() async {
        loading = true; lastError = nil
        defer { loading = false }
        do {
            let health = try await request("/health", timeout: 5)
            let json = try JSONSerialization.jsonObject(with: health) as? [String: Any]
            guard json?["databaseReady"] as? Bool == true else { throw RadError.message("Horos is running; its database is still opening.") }
            isConnected = true; status = "Horos \(json?["version"] as? String ?? "") · native engine"
            try await refreshStudies()
            struct NodesResponse: Decodable { let nodes: [EngineNode] }
            nodes = try JSONDecoder().decode(NodesResponse.self, from: await request("/pacs/nodes")).nodes
        } catch { isConnected = false; status = "Backend unavailable"; lastError = error.localizedDescription }
    }
    func refreshStudies(more: Bool = false) async throws {
        let result = try JSONDecoder().decode(EngineStudyList.self, from: await request("/studies", body: ["search": query, "limit": 100, "offset": more ? studies.count : 0]))
        if more { studies += result.studies } else { studies = result.studies }; hasMore = result.hasMore
    }
    func detail(_ id: String, expectedUID: String? = nil) async throws -> EngineStudyDetail {
        let result = try JSONDecoder().decode(EngineStudyDetail.self, from: await request("/study", body: ["id": id]))
        try result.validate(id: id, expectedUID: expectedUID); return result
    }
    func render(studyID: String, imageID: String, center: Double? = nil, width: Double? = nil) async throws -> EngineRender {
        var body: [String: Any] = ["studyID": studyID, "imageID": imageID]
        if let center { body["center"] = center }; if let width { body["width"] = width }
        let result = try JSONDecoder().decode(EngineRender.self, from: await request("/render", body: body, timeout: 90))
        guard result.imageID == imageID, result.studyID == studyID else { throw RadError.message("The engine returned pixels for a different study or frame; display rejected.") }
        return result
    }
    func retrieve(node: Int, uid: String, accession: String) async throws -> String {
        let result = try await request("/pacs/retrieve", body: ["node": node, "studyUID": uid, "accession": accession], timeout: 180)
        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        return json?["message"] as? String ?? "Retrieval requested. Refresh the library to verify receipt."
    }
    func openSeries(studyID: String, seriesID: String, imageID: String? = nil, width: Double? = nil, center: Double? = nil) async throws {
        var body: [String: Any] = ["studyID": studyID, "seriesID": seriesID]
        if let imageID { body["imageID"] = imageID }
        if let width, let center { body["width"] = width; body["center"] = center }
        _ = try await request("/open-series", body: body, timeout: 90)
    }
    func installPlugin() throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("RadAgentEngine.horosplugin"), FileManager.default.fileExists(atPath: source.path) else { throw RadError.message("The engine plugin is missing from this build. Run the complete app build script.") }
        try FileManager.default.createDirectory(at: pluginDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: pluginDestination.path) {
            let backup = pluginDestination.deletingLastPathComponent().appendingPathComponent("../RadAgentEngine-backup-\(UUID().uuidString).horosplugin").standardizedFileURL
            try FileManager.default.moveItem(at: pluginDestination, to: backup)
        }
        try FileManager.default.copyItem(at: source, to: pluginDestination)
        status = "Installed · restart Horos once"
    }
    func launchInBackground() throws {
        guard !running else { return }
        let installedURL = URL(fileURLWithPath: "/Applications/Horos.app")
        guard let url = FileManager.default.fileExists(atPath: installedURL.path) ? installedURL : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.horosproject.horos") else { throw RadError.message("Install Horos in Applications to start the DICOM backend.") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
