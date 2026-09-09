import Foundation

public struct KeyImageReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var phrase: String
    public var imageID: String
    public var imageIndex: Int
    public var studyUID: String
    public var sopInstanceUID: String?
    public var frame: Int?
    public var windowWidth: Double
    public var windowCenter: Double
    public init(phrase: String, imageID: String, imageIndex: Int, studyUID: String, windowWidth: Double, windowCenter: Double) {
        id = UUID().uuidString; self.phrase = phrase; self.imageID = imageID; self.imageIndex = imageIndex; self.studyUID = studyUID; self.windowWidth = windowWidth; self.windowCenter = windowCenter
    }
    public func range(in document: String) -> NSRange? {
        guard !phrase.isEmpty else { return nil }
        let range = (document as NSString).range(of: phrase)
        guard range.location != NSNotFound else { return nil }
        let tail = NSRange(location: NSMaxRange(range), length: (document as NSString).length - NSMaxRange(range))
        guard (document as NSString).range(of: phrase, range: tail).location == NSNotFound else { return nil }
        return range
    }
    public func contextUnchanged(from old: String, to new: String) -> Bool {
        guard let oldRange = range(in: old), let newRange = range(in: new) else { return false }
        let oldText = old as NSString, newText = new as NSString
        return oldText.substring(with: oldText.paragraphRange(for: oldRange)) == newText.substring(with: newText.paragraphRange(for: newRange))
    }
}

public struct ReportTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var modalities: [String]
    public var keywords: [String]
    public var document: String
    public var revision: Int?
    public var locallyModified: Bool?
    public init(id: String = UUID().uuidString, name: String, modalities: [String] = [], keywords: [String] = [], document: String) {
        self.id = id; self.name = name; self.modalities = modalities; self.keywords = keywords; self.document = document
    }
    public func score(modality: String, description: String) -> Int {
        if !modalities.isEmpty && !modalities.contains(where: { $0.caseInsensitiveCompare(modality) == .orderedSame }) { return 0 }
        let text = description.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let matches = keywords.filter { text.contains($0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))) }.count
        if !keywords.isEmpty && matches == 0 { return 0 }
        return 1 + (modalities.isEmpty ? 0 : 10) + matches * 20
    }
    public static let defaults: [ReportTemplate] = [
        ReportTemplate(id: "chest-radiograph", name: "Chest radiograph", modalities: ["CR", "DX"], keywords: ["chest", "torax"], document: "CHEST RADIOGRAPH\n\nINDICATION\n[Clinical indication]\n\nTECHNIQUE\n[Views and limitations]\n\nCOMPARISON\n[Available prior study]\n\nFINDINGS\n[Lungs and pleura]\n[Cardiomediastinal silhouette]\n[Bones and soft tissues]\n\nIMPRESSION\n[Interpretation after image review]"),
        ReportTemplate(id: "ct-head", name: "CT head", modalities: ["CT"], keywords: ["head", "brain", "cranio", "encefalo"], document: "CT HEAD\n\nINDICATION\n[Clinical indication]\n\nTECHNIQUE\n[Acquisition, contrast, and limitations]\n\nCOMPARISON\n[Available prior study]\n\nFINDINGS\n[Brain parenchyma]\n[Ventricles and extra-axial spaces]\n[Bones and extracranial structures]\n\nIMPRESSION\n[Interpretation after image review]"),
        ReportTemplate(id: "general", name: "General report", document: "INDICATION\n[Clinical indication]\n\nTECHNIQUE\n[Acquisition and limitations]\n\nCOMPARISON\n[Available prior study]\n\nFINDINGS\n[Image observations]\n\nIMPRESSION\n[Interpretation after image review]")
    ]
    public static func best(in templates: [ReportTemplate], modality: String, description: String) -> ReportTemplate? {
        templates.sorted { $0.score(modality: modality, description: description) > $1.score(modality: modality, description: description) }.first { $0.score(modality: modality, description: description) > 0 }
    }
}

public struct WorklistEntry: Codable, Identifiable, Sendable {
    public var study_uid: String
    public var patient_id: String
    public var patient_name: String
    public var accession: String
    public var description: String
    public var modality: String
    public var tags: [String]
    public var priority: String
    public var assignee: String
    public var status: String
    public var received_complete: Bool
    public var revision: Int
    public var received_at: Double
    public var lease_expires: Double?
    public var claim_token: String?
    public var id: String { study_uid }
}
