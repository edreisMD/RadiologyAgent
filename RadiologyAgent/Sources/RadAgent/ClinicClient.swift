import Foundation
import RadAgentCore

@MainActor final class ClinicClient: ObservableObject {
    private let session = PrivateHTTP.session()
    private var refreshing = false
    @Published var entries: [WorklistEntry] = []
    @Published var isConnected = false
    @Published var error: String?
    var baseURL: String { ProcessInfo.processInfo.environment["RADAGENT_BACKEND_URL"] ?? APIConfiguration.fileValues["RADAGENT_BACKEND_URL"] ?? "http://127.0.0.1:8043" }
    var token: String {
        if let configured = ProcessInfo.processInfo.environment["RADAGENT_BACKEND_TOKEN"] ?? APIConfiguration.fileValues["RADAGENT_BACKEND_TOKEN"] { return configured }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RadAgent/backend/api-token")
        return (try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
    var configured: Bool { !token.isEmpty }
    func request(_ route: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard !token.isEmpty else { throw RadError.message("The clinic backend token is not configured.") }
        var request = URLRequest(url: try PrivateHTTP.clinicURL(baseURL, route: route)); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw RadError.message(detail ?? "The clinic backend request failed.")
        }
        return data
    }
    func refresh() async {
        guard configured, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            struct Page: Decodable { let studies: [WorklistEntry]; let total: Int }
            // Paginate without exposing a partially loaded list to the user.
            var result: [WorklistEntry] = []
            var offset = 0
            repeat {
                let page = try JSONDecoder().decode(Page.self, from: await requestPage(offset: offset))
                result += page.studies; offset += page.studies.count
                if offset >= page.total || page.studies.isEmpty { break }
            } while true
            entries = result; isConnected = true; error = nil
        } catch { isConnected = false; self.error = error.localizedDescription }
    }
    private func requestPage(offset: Int) async throws -> Data {
        let url = try PrivateHTTP.clinicURL(baseURL, route: "/v1/studies", query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "500")])
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RadError.message("Worklist API unavailable or authentication failed.") }
        return data
    }
    func remoteTemplates() async throws -> [ReportTemplate] {
        struct Response: Decodable { let templates: [ReportTemplate] }
        return try JSONDecoder().decode(Response.self, from: await request("/v1/templates")).templates
    }
    func saveTemplate(_ template: ReportTemplate) async throws -> ReportTemplate {
        let body: [String: Any] = ["id": template.id, "name": template.name, "modalities": template.modalities, "keywords": template.keywords, "document": template.document, "expected_revision": template.revision ?? 0]
        return try JSONDecoder().decode(ReportTemplate.self, from: await request("/v1/templates/\(template.id)", method: "PUT", body: body))
    }
    func saveDraft(_ study: StudyRecord, claimToken: String? = nil) async throws -> Int {
        let evidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(study.draft.evidence ?? []))
        var body: [String: Any] = ["document": study.draft.body, "evidence": evidence, "expected_revision": study.backendDraftRevision ?? 0]
        if let claimToken { body["claim_token"] = claimToken }
        if let templateID = study.templateID { body["template_id"] = templateID }
        let result = try await request("/v1/studies/\(study.studyUID)/draft", method: "PUT", body: body)
        return ((try JSONSerialization.jsonObject(with: result)) as? [String: Any])?["revision"] as? Int ?? 0
    }
    func claim(_ entry: WorklistEntry) async throws -> WorklistEntry {
        let worker = UserDefaults.standard.string(forKey: "workerID") ?? UUID().uuidString
        UserDefaults.standard.set(worker, forKey: "workerID")
        return try JSONDecoder().decode(WorklistEntry.self, from: await request("/v1/studies/\(entry.study_uid)/claim", method: "POST", body: ["worker_id": worker, "expected_revision": entry.revision]))
    }
    func receiveIncoming(_ study: EngineStudy, ready: Bool) async throws -> WorklistEntry {
        var body: [String: Any] = ["study_uid": study.studyUID, "patient_id": study.patientID, "patient_name": study.patientName, "accession": study.accession, "description": study.title, "modality": study.modality]
        let existing = entries.first { $0.study_uid == study.studyUID }
        // Preserve API ownership, priority and externally supplied tags.
        if ready { body["tags"] = Array(Set((existing?.tags ?? []) + ["radagent-draft", "horos-arrival"])).sorted(); body["received_complete"] = true }
        else if existing == nil { body["received_complete"] = false; body["tags"] = ["horos-arrival"] }
        return try JSONDecoder().decode(WorklistEntry.self, from: await request("/v1/studies", method: "POST", body: body))
    }
    func renewClaim(uid: String, token: String) async throws {
        _ = try await request("/v1/studies/\(uid)/lease", method: "POST", body: ["claim_token": token])
    }
    func requeue(_ entry: WorklistEntry) async throws -> WorklistEntry {
        try JSONDecoder().decode(WorklistEntry.self, from: await request("/v1/studies/\(entry.study_uid)", method: "PATCH", body: ["status": "queued", "expected_revision": entry.revision]))
    }
    func releaseClaim(uid: String, token: String, failed: Bool) async throws {
        _ = try await request("/v1/studies/\(uid)/lease", method: "DELETE", body: ["claim_token": token, "failed": failed])
    }
    struct RemoteDraft: Decodable {
        let document: String
        let evidence: [KeyImageReference]
        let revision: Int
        let template_id: String?
    }
    func draft(uid: String) async throws -> RemoteDraft { try JSONDecoder().decode(RemoteDraft.self, from: await request("/v1/studies/\(uid)/draft")) }
}
