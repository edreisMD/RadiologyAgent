import XCTest
import AppKit
@testable import RadAgentCore

final class IncomingStudiesTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    func study(_ uid: String = "1.2.3", count: Int = 2, patient: String = "fixture") -> EngineStudy {
        EngineStudy(id: "local-\(uid)", studyUID: uid, patientName: "Synthetic fixture", patientID: patient, title: "Chest", modality: "CR", date: 1, imageCount: count, accession: "")
    }
    func detail(_ study: EngineStudy, alternate: Bool = false) -> EngineStudyDetail {
        let frames = (0..<study.imageCount).map { EngineImage(id: "image-\($0)", index: $0, instance: $0 + 1, frame: 0, width: 2, height: 2, sopInstanceUID: "\(study.studyUID).\(alternate ? 20 : 10).\($0)") }
        return EngineStudyDetail(study: study, series: [EngineSeries(id: "series", uid: "\(study.studyUID).1", name: "Chest", modality: "CR", frames: frames)], frameCount: frames.count)
    }
    func readyQueue() -> IncomingStudyQueue {
        var queue = IncomingStudyQueue(); queue.observe([], now: start)
        for t in stride(from: 0, through: 75, by: 15) {
            let now = start.addingTimeInterval(Double(t)); queue.observe([study()], now: now)
            if t >= 60 { queue.confirmInventory(detail(study()), now: now) }
        }
        return queue
    }
    func testBaselineIsNotBackfilledAndNewArrivalNeedsQuietPeriodAndInventory() {
        var queue = IncomingStudyQueue(); queue.observe([study("1.1")], now: start)
        XCTAssertEqual(queue.studies["1.1"]?.status, .existing)
        queue.observe([study("1.1"), study()], now: start.addingTimeInterval(15))
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .receiving)
        XCTAssertFalse(queue.needsInventory("1.2.3", now: start.addingTimeInterval(30)))
        var ready = readyQueue()
        XCTAssertEqual(ready.next(available: ["1.2.3"], now: start.addingTimeInterval(75))?.id, "1.2.3")
        ready.enabled = false
        XCTAssertNil(ready.next(available: ["1.2.3"], now: start.addingTimeInterval(75)))
    }
    func testArrivalBurstAndInventoryReplacementResetReadiness() {
        var queue = readyQueue()
        queue.observe([study(count: 3)], now: start.addingTimeInterval(90))
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .receiving)
        XCTAssertFalse(queue.needsInventory("1.2.3", now: start.addingTimeInterval(100)))
        queue = readyQueue()
        queue.confirmInventory(detail(study(), alternate: true), now: start.addingTimeInterval(80))
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .receiving)
        XCTAssertNotEqual(IncomingStudyQueue.signature(detail(study())), IncomingStudyQueue.signature(detail(study(), alternate: true)))
    }
    func testMissingStudyAndOfflineGapCannotBeProcessedAsStable() {
        var queue = readyQueue()
        XCTAssertNil(queue.next(available: [], now: start.addingTimeInterval(80)))
        queue.observe([study()], now: start.addingTimeInterval(200))
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .receiving)
        XCTAssertFalse(queue.needsInventory("1.2.3", now: start.addingTimeInterval(200)))
    }
    func testRestartCatchesUpNewUIDAndDoesNotRegenerateSavedCandidate() throws {
        var queue = readyQueue(); queue.studies["1.2.3"]?.status = .processing
        var draft = ReportDraft(); draft.document = "Synthetic fixture only"; draft.purpose = "evaluation"
        queue.studies["1.2.3"]?.result = AutomaticDraft(report: draft, templateID: nil, reviewedFrames: 2, totalFrames: 2, message: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IncomingQueueStore(directory: directory); try store.save(queue)
        var restored = try store.load(); restored.recover(now: start.addingTimeInterval(200))
        restored.observe([study(), study("1.9")], now: start.addingTimeInterval(200))
        XCTAssertEqual(restored.studies["1.2.3"]?.status, .saving)
        XCTAssertEqual(restored.studies["1.2.3"]?.inventory, queue.studies["1.2.3"]?.inventory)
        XCTAssertEqual(restored.studies["1.2.3"]?.result?.report, draft)
        XCTAssertEqual(restored.studies["1.9"]?.status, .receiving)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testLateImagesAndUIDCollisionPreserveCompletedDraft() {
        var queue = readyQueue(); queue.studies["1.2.3"]?.status = .draft
        queue.observe([study(count: 3)], now: start.addingTimeInterval(90))
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .attention)
        XCTAssertNil(queue.next(available: ["1.2.3"], now: start.addingTimeInterval(200)))
        queue.observe([study(patient: "different")], now: start.addingTimeInterval(100))
        XCTAssertEqual(queue.studies["1.2.3"]?.study.patientID, "fixture")
        XCTAssertTrue(queue.studies["1.2.3"]?.issue?.contains("identity") == true)
    }
    func testFailuresBackOffAndRequireExplicitRetryAfterThreeAttempts() {
        var queue = readyQueue(); queue.studies["1.2.3"]?.attempts = 1
        queue.failed("1.2.3", message: "Fixture failure", now: start)
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .retry)
        XCTAssertEqual(queue.studies["1.2.3"]?.nextAttempt, start.addingTimeInterval(60))
        queue.studies["1.2.3"]?.attempts = 3
        queue.failed("1.2.3", message: "Fixture failure", now: start)
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .attention)
        queue.retry("1.2.3", now: start)
        XCTAssertEqual(queue.studies["1.2.3"]?.attempts, 0)
        XCTAssertEqual(queue.studies["1.2.3"]?.status, .receiving)
    }
    func testRadiologistEditsDuringGenerationAndSaveRecoveryAreProtected() throws {
        var queue = readyQueue()
        var local = StudyRecord(title: "Fixture", studyUID: "1.2.3")
        queue.studies[local.studyUID]?.originalDraft = local.draft
        var candidate = ReportDraft(); candidate.document = "Automatic synthetic fixture"; candidate.purpose = "evaluation"
        queue.studies[local.studyUID]?.result = AutomaticDraft(report: candidate, templateID: nil, reviewedFrames: 2, totalFrames: 2, message: "")
        let job = try XCTUnwrap(queue.studies[local.studyUID])
        XCTAssertFalse(job.conflicts(with: local))
        local.replaceDraft(ReportDraft(findings: "Radiologist dictation fixture"))
        XCTAssertTrue(job.conflicts(with: local))
        local.replaceDraft(candidate); local.automaticDraftJobID = job.jobID
        XCTAssertFalse(job.conflicts(with: local))
        local.draft.document = "Radiologist revision after local delivery, before clinic save"
        let reopened = try JSONDecoder().decode(StudyRecord.self, from: JSONEncoder().encode(local))
        XCTAssertTrue(job.conflicts(with: reopened))
    }
    func testCorruptQueueFailsClosedRatherThanRepeatingModelJobs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IncomingQueueStore(directory: directory); try store.save(readyQueue())
        try Data("incomplete write fixture".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
    }
}

final class AutomaticDraftSessionTests: XCTestCase {
    func call(_ name: String, _ args: [String: Any]) throws -> AgentResponse {
        AgentResponse(output: [["type": "function_call", "name": name, "call_id": UUID().uuidString, "arguments": String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!]], text: "")
    }
    @MainActor func fixtureRender(_ detail: EngineStudyDetail, _ frame: EngineImage, mismatch: Bool = false) throws -> EngineRender {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * 2)
        return EngineRender(png: bitmap.representation(using: .png, properties: [:])!.base64EncodedString(), width: 2, height: 2, windowWidth: 400, windowCenter: 40, pixelSpacingX: 1, pixelSpacingY: 1, imageID: frame.id, studyID: mismatch ? "another-study" : detail.study.id, source: "synthetic test")
    }
    @MainActor func testFullStudyReviewProducesEvaluationDraftWithExactEvidence() async throws {
        let fixtures = IncomingStudiesTests(), detail = fixtures.detail(fixtures.study())
        var requests = 0, rendered: [Int] = []
        let session = AutomaticDraftSession(detail: detail, templates: ReportTemplate.defaults, render: { frame, _, _ in
            rendered.append(frame.index); return try self.fixtureRender(detail, frame)
        }, request: { input in
            requests += 1
            if requests == 1 { return try self.call("view_images", ["indices": [0, 1]]) }
            let outputs = input.filter { $0["type"] as? String == "function_call_output" }
            XCTAssertEqual((outputs.last?["output"] as? [[String: Any]])?.filter { $0["type"] as? String == "input_image" }.count, 2)
            return try self.call("write_report", ["document": "FINDINGS\nSynthetic fixture.", "key_images": [["phrase": "Synthetic fixture", "image_index": 1]]])
        })
        let result = try await session.run(language: "English")
        XCTAssertEqual(rendered, [0, 1]); XCTAssertEqual(result.reviewedFrames, 2); XCTAssertEqual(result.totalFrames, 2)
        XCTAssertEqual(result.report.purpose, "evaluation"); XCTAssertEqual(result.report.evidence?.first?.sopInstanceUID, detail.series[0].frames[1].sopInstanceUID)
    }
    @MainActor func testUnviewedEvidenceAndMismatchedStudyCannotBecomeReport() async throws {
        let fixtures = IncomingStudiesTests(), detail = fixtures.detail(fixtures.study())
        for mismatch in [false, true] {
            var requests = 0
            let session = AutomaticDraftSession(detail: detail, templates: [], render: { frame, _, _ in try self.fixtureRender(detail, frame, mismatch: mismatch) }, request: { _ in
                requests += 1
                if requests == 1 { return try self.call("view_image", ["index": 0]) }
                return try self.call("write_report", ["document": "Fixture.", "key_images": [["phrase": "Fixture", "image_index": 1]]])
            })
            do { _ = try await session.run(language: "English", maxRounds: 2); XCTFail("Unverified report accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("turn limit")) }
        }
    }
    @MainActor func testTextOnlyCompletionIsFailureAndPartialCoverageIsCounted() async throws {
        let fixtures = IncomingStudiesTests(), detail = fixtures.detail(fixtures.study())
        let noReport = AutomaticDraftSession(detail: detail, templates: [], render: { _, _, _ in throw RadError.message("Must not render") }, request: { _ in AgentResponse(output: [], text: "Finished") })
        do { _ = try await noReport.run(language: "English"); XCTFail("Text-only answer accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("without saving")) }
        var requests = 0
        let partial = AutomaticDraftSession(detail: detail, templates: [], render: { frame, _, _ in try self.fixtureRender(detail, frame) }, request: { _ in
            requests += 1
            return requests == 1 ? try self.call("view_image", ["index": 0]) : try self.call("write_report", ["document": "Limited fixture review.", "key_images": []])
        })
        let result = try await partial.run(language: "English")
        XCTAssertEqual(result.reviewedFrames, 1); XCTAssertEqual(result.totalFrames, 2)
    }
}
