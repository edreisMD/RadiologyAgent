import Foundation
import CryptoKit

public enum IncomingStatus: String, Codable, Sendable {
    case existing, receiving, queued, processing, retry, saving, draft, attention
    public var label: String {
        switch self {
        case .existing: "New"
        case .receiving: "Receiving images"
        case .queued: "Queued"
        case .processing: "Drafting…"
        case .retry: "Retry scheduled"
        case .saving: "Saving draft…"
        case .draft: "Draft for evaluation"
        case .attention: "Needs attention"
        }
    }
}

public struct AutomaticDraft: Codable, Sendable {
    public var report: ReportDraft
    public var templateID: String?
    public var reviewedFrames: Int
    public var totalFrames: Int
    public var message: String
    public init(report: ReportDraft, templateID: String?, reviewedFrames: Int, totalFrames: Int, message: String) {
        self.report = report; self.templateID = templateID; self.reviewedFrames = reviewedFrames; self.totalFrames = totalFrames; self.message = message
    }
}

public struct IncomingStudy: Codable, Identifiable, Sendable {
    public var id: String { study.studyUID }
    public var jobID = UUID().uuidString
    public var study: EngineStudy
    public var status: IncomingStatus
    public var firstSeen: Date
    public var lastSeen: Date
    public var changedAt: Date
    public var inventory: String?
    public var inventoryAt: Date?
    public var lastInventoryCheck: Date?
    public var attempts = 0
    public var nextAttempt: Date?
    public var issue: String?
    public var result: AutomaticDraft?
    public var originalDraft: ReportDraft?
    public var claimToken: String?
    public var clinicRevision: Int?
    public var clinicSaved = false
    public var usesClinic = false
    public var isPending: Bool { [.receiving, .queued, .processing, .retry, .saving].contains(status) }
    public func conflicts(with local: StudyRecord) -> Bool {
        if local.automaticDraftJobID == jobID { return result.map { local.draft != $0.report } ?? false }
        return (local.workflowStatus == "draft" || local.backendDraftDirty == true) && local.draft != originalDraft
    }
}

/// A durable arrival journal, separate from whichever study the radiologist has open.
/// Acquisition dates are deliberately not used: an old exam can arrive today.
public struct IncomingStudyQueue: Codable, Sendable {
    public var version = 1
    public var initialized = false
    public var enabled = true
    public var studies: [String: IncomingStudy] = [:]
    public static let quietSeconds: TimeInterval = 60
    public init() {}

    public mutating func observe(_ snapshot: [EngineStudy], now: Date = Date()) {
        let baseline = !initialized
        for study in snapshot where !study.studyUID.isEmpty {
            guard var job = studies[study.studyUID] else {
                studies[study.studyUID] = IncomingStudy(study: study, status: baseline ? .existing : .receiving, firstSeen: now, lastSeen: now, changedAt: now)
                continue
            }
            // A UID collision must never silently retarget an existing report.
            if !job.study.patientID.isEmpty && job.study.patientID != study.patientID {
                job.status = .attention; job.issue = "Patient identity changed for this Study UID. Existing draft preserved."
                studies[study.studyUID] = job; continue
            }
            let changed = job.study.imageCount != study.imageCount || job.study.id != study.id
            let gap = now.timeIntervalSince(job.lastSeen) > 45
            if changed || (gap && job.isPending && job.result == nil) {
                job.changedAt = now; job.inventory = nil; job.inventoryAt = nil
                if changed && (job.status == .draft || job.result != nil) {
                    job.status = .attention; job.issue = "Images changed after drafting. Review the additional images; the existing draft was preserved."
                } else if [.receiving, .queued, .retry].contains(job.status) { job.status = .receiving }
            }
            job.study = study; job.lastSeen = now
            studies[study.studyUID] = job
        }
        initialized = true
    }

    public func needsInventory(_ uid: String, now: Date = Date()) -> Bool {
        guard let job = studies[uid], [.receiving, .queued, .retry].contains(job.status) else { return false }
        return job.study.imageCount > 0 && now.timeIntervalSince(job.lastSeen) <= 45 && now.timeIntervalSince(job.changedAt) >= Self.quietSeconds
    }

    public mutating func confirmInventory(_ detail: EngineStudyDetail, now: Date = Date()) {
        let uid = detail.study.studyUID
        guard var job = studies[uid], needsInventory(uid, now: now), detail.frameCount > 0 else { return }
        let signature = Self.signature(detail)
        if job.inventory != signature {
            job.inventory = signature; job.inventoryAt = now; job.status = .receiving
        } else if now.timeIntervalSince(job.inventoryAt ?? now) >= 15 && (job.nextAttempt ?? .distantPast) <= now {
            job.status = .queued
        }
        studies[uid] = job
    }

    public func next(available: Set<String>, now: Date = Date()) -> IncomingStudy? {
        guard enabled else { return nil }
        return studies.values.filter { $0.status == .queued && available.contains($0.id) && ( $0.nextAttempt ?? .distantPast ) <= now }
            .sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen < $1.firstSeen }.first
    }

    public mutating func recover(now: Date = Date()) {
        for uid in studies.keys {
            guard var job = studies[uid], job.isPending else { continue }
            if job.result != nil { job.status = .saving }
            else {
                job.status = .receiving; job.changedAt = now; job.inventory = nil; job.inventoryAt = nil
                if job.attempts >= 3 { job.status = .attention; job.issue = "Automatic drafting was interrupted repeatedly. Retry when ready." }
            }
            studies[uid] = job
        }
    }

    public mutating func failed(_ uid: String, message: String, now: Date = Date()) {
        guard var job = studies[uid] else { return }
        job.issue = message
        if job.result != nil { job.status = .saving; job.nextAttempt = now.addingTimeInterval(60) }
        else if job.attempts < 3 {
            job.status = .retry; job.nextAttempt = now.addingTimeInterval(pow(2, Double(max(0, job.attempts - 1))) * 60)
        } else { job.status = .attention }
        studies[uid] = job
    }

    public mutating func retry(_ uid: String, now: Date = Date()) {
        guard var job = studies[uid], job.status == .attention || job.status == .retry || job.status == .existing else { return }
        // A saved candidate is never thrown away or sent to the model a second time.
        guard job.result == nil else { return }
        job.status = .receiving; job.attempts = 0; job.nextAttempt = nil; job.issue = nil
        job.changedAt = now; job.inventory = nil; job.inventoryAt = nil
        studies[uid] = job
    }

    public static func signature(_ detail: EngineStudyDetail) -> String {
        let rows = detail.series.flatMap { series in series.frames.map { "\(series.uid)|\($0.sopInstanceUID ?? $0.id)|\($0.frame)|\($0.width)x\($0.height)" } }.sorted()
        return SHA256.hash(data: Data(([detail.study.studyUID, detail.study.patientID] + rows).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct IncomingQueueStore {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("incoming-studies.json") }
    public func load() throws -> IncomingStudyQueue {
        guard FileManager.default.fileExists(atPath: file.path) else { return IncomingStudyQueue() }
        let value = try JSONDecoder().decode(IncomingStudyQueue.self, from: Data(contentsOf: file))
        guard value.version == 1 else { throw RadError.message("The incoming-study queue needs a newer version of Radiology Agent.") }
        return value
    }
    public func save(_ queue: IncomingStudyQueue) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(queue).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
