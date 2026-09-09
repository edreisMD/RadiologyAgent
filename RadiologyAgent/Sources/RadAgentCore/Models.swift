import Foundation

public struct ReportDraft: Codable, Equatable, Sendable {
    public var indication: String
    public var technique: String
    public var comparison: String
    public var findings: String
    public var impression: String
    public var updatedAt: Date
    public var purpose: String?
    public var document: String?
    public var evidence: [KeyImageReference]?
    public init(indication: String = "", technique: String = "", comparison: String = "", findings: String = "", impression: String = "") {
        self.indication = indication; self.technique = technique; self.comparison = comparison
        self.findings = findings; self.impression = impression; self.updatedAt = Date()
    }
    public var isEmpty: Bool { document.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? (findings.isEmpty && impression.isEmpty) }
    public var body: String {
        document ?? "INDICATION\n\(indication)\n\nTECHNIQUE\n\(technique)\n\nCOMPARISON\n\(comparison)\n\nFINDINGS\n\(findings)\n\nIMPRESSION\n\(impression)"
    }
    public var text: String {
        "\(purpose == "evaluation" ? "DRAFT FOR EVALUATION" : "DRAFT") — REQUIRES RADIOLOGIST REVIEW\n\n\(body)"
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var role: String
    public var text: String
    public var date: Date
    public var engine: String?
    public init(role: String, text: String, engine: String? = nil) { id = UUID(); self.role = role; self.text = text; date = Date(); self.engine = engine }
}

public struct StudyRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var patientLabel: String
    public var modality: String
    public var studyUID: String
    public var isDemo: Bool
    public var engineStudyID: String?
    public var patientID: String?
    public var accession: String?
    public var studyDate: Date?
    public var templateID: String?
    public var backendRevision: Int?
    public var backendDraftRevision: Int?
    public var backendDraftDirty: Bool?
    public var tags: [String]?
    public var workflowStatus: String?
    public var automaticDraftJobID: String?
    public var imagePaths: [String]
    public var draft: ReportDraft
    public var history: [ReportDraft]
    public var messages: [ChatMessage]
    public init(id: String = UUID().uuidString, title: String, patientLabel: String = "Local study", modality: String = "DX", studyUID: String = "", isDemo: Bool = false, imagePaths: [String] = []) {
        self.id = id; self.title = title; self.patientLabel = patientLabel; self.modality = modality
        self.studyUID = studyUID; self.isDemo = isDemo; self.imagePaths = imagePaths
        draft = ReportDraft(); history = []; messages = []
    }
    public mutating func replaceDraft(_ newDraft: ReportDraft, fromClinic: Bool = false) {
        let purpose = draft.purpose
        if !draft.isEmpty { history.append(draft) }
        if history.count > 30 { history.removeFirst(history.count - 30) }
        draft = newDraft
        if draft.purpose == nil { draft.purpose = purpose }
        backendDraftDirty = !fromClinic
        workflowStatus = "draft"
    }
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var version: Int = 1
    public var studies: [StudyRecord]
    public var selectedID: String?
    public init(studies: [StudyRecord], selectedID: String?) { self.studies = studies; self.selectedID = selectedID }
}

public struct WorkspaceStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var file: URL { directory.appendingPathComponent("workspace.json") }
    public func load() throws -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: file))
    }
    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public enum RadError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum StudyIdentity {
    public static func groupedID(studyUID: String, fallback: String) -> String { studyUID.isEmpty ? fallback : "dicom-\(studyUID)" }
    public static func horosURL(studyUID: String) throws -> URL {
        guard !studyUID.isEmpty, studyUID.count <= 64,
              studyUID.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else {
            throw RadError.message("Enter a valid DICOM Study Instance UID (numbers separated by periods).")
        }
        var c = URLComponents(); c.scheme = "horos"; c.host = ""
        c.queryItems = [URLQueryItem(name: "methodName", value: "displayStudy"), URLQueryItem(name: "StudyInstanceUID", value: studyUID)]
        guard let url = c.url else { throw RadError.message("Could not construct the Horos study link.") }
        return url
    }
}
