import XCTest
import AppKit
@testable import RadAgentCore

final class ReportingTests: XCTestCase {
    func testWordTemplateTextRoundTrip() throws {
        let document = NSAttributedString(string: "DRAFT FOR EVALUATION\n\nFINDINGS\nSynthetic fixture.")
        let data = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let result = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(result.string.contains("Synthetic fixture."))
    }
    func testTemplateSelectionMatchesModalityAndAnatomy() {
        XCTAssertEqual(ReportTemplate.best(in: ReportTemplate.defaults, modality: "CR", description: "RX Tórax 2 incidencias")?.id, "chest-radiograph")
        XCTAssertEqual(ReportTemplate.best(in: ReportTemplate.defaults, modality: "CT", description: "Abdomen")?.id, "general")
        XCTAssertEqual(ReportTemplate.best(in: ReportTemplate.defaults, modality: "CT", description: "Brain without contrast")?.id, "ct-head")
    }
    func testEvidenceRejectsMissingOrAmbiguousPhrasesAndPreservesUnicode() throws {
        let reference = KeyImageReference(phrase: "Achado à direita", imageID: "local-image", imageIndex: 1, studyUID: "1.2.3", windowWidth: 400, windowCenter: 40)
        XCTAssertNotNil(reference.range(in: "ACHADOS\nAchado à direita."))
        XCTAssertNil(reference.range(in: "Revised finding"))
        XCTAssertNil(reference.range(in: "Achado à direita; Achado à direita"))
        let decoded = try JSONDecoder().decode(KeyImageReference.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(decoded, reference)
        XCTAssertTrue(reference.contextUnchanged(from: "Header\nAchado à direita.\n", to: "Different header\nAchado à direita.\n"))
        XCTAssertFalse(reference.contextUnchanged(from: "Achado à direita.\n", to: "Sem Achado à direita.\n"))
    }
}

final class ConfigurationTests: XCTestCase {
    func testLocalEnvironmentValuesRemainLiteralAndOnlyKnownKeysLoad() {
        let values = EnvironmentFile.parse("# ignored\nexport OPENAI_API_KEY = 'test-key_with_underscores'\nOPENAI_MODEL=\"test-model\"\nUNRELATED=ignored\n")
        XCTAssertEqual(values, ["OPENAI_API_KEY": "test-key_with_underscores", "OPENAI_MODEL": "test-model"])
        XCTAssertEqual(EnvironmentFile.parse("OPENAI_API_KEY=$(never-run)")["OPENAI_API_KEY"], "$(never-run)")
    }
    func testEvaluationPurposeSurvivesAgentReplacementAndPersistence() throws {
        var study = StudyRecord(title: "Evaluation")
        study.draft.purpose = "evaluation"
        study.replaceDraft(ReportDraft(findings: "Supplied findings"))
        study.replaceDraft(ReportDraft(findings: "Revised supplied findings"))
        let decoded = try JSONDecoder().decode(StudyRecord.self, from: JSONEncoder().encode(study))
        XCTAssertTrue(decoded.draft.text.hasPrefix("DRAFT FOR EVALUATION"))
        XCTAssertEqual(decoded.history.first?.purpose, "evaluation")
    }
}

final class EngineProtocolTests: XCTestCase {
    func testObjectiveCBooleanCompatibility() throws {
        for representation in ["false", "0", "true", "1"] {
            let result = try JSONDecoder().decode(EngineStudyList.self, from: Data("{\"studies\":[],\"hasMore\":\(representation)}".utf8))
            XCTAssertEqual(result.hasMore, ["true", "1"].contains(representation))
        }
    }
    func testEngineConnectionCannotTargetAnotherHostOrArbitraryAction() throws {
        let connection = try JSONDecoder().decode(EngineConnection.self, from: Data(#"{"port":12345,"token":"abcdefghijklmnopqrstuvwxyz1234567890","protocolVersion":1,"pid":123}"#.utf8))
        XCTAssertEqual(try connection.validatedURL(route: "/render").host, "127.0.0.1")
        XCTAssertThrowsError(try connection.validatedURL(route: "/delete-study"))
        XCTAssertThrowsError(try connection.validatedURL(route: "https://example.invalid"))
    }
    func testMalformedEngineConnectionIsRejected() throws {
        for port in [-1, 0, 65536] {
            let connection = try JSONDecoder().decode(EngineConnection.self, from: Data("{\"port\":\(port),\"token\":\"abcdefghijklmnopqrstuvwxyz1234567890\",\"protocolVersion\":1,\"pid\":123}".utf8))
            XCTAssertThrowsError(try connection.validatedURL(route: "/health"))
        }
    }
}

final class DICOMTests: XCTestCase {
    func fixture(signed: Bool = false, mono1: Bool = false, syntax: String = "1.2.840.10008.1.2.1", pixelValues: [UInt16] = [0, 64, 128, 255]) -> Data {
        var data = Data(repeating: 0, count: 128); data.append(Data("DICM".utf8))
        func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
        func append(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: Data) {
            data.append(le16(group)); data.append(le16(element)); data.append(Data(vr.utf8))
            var padded = value; if padded.count % 2 != 0 { padded.append(0) }
            if vr == "OW" { data.append(Data([0, 0])); let n = UInt32(padded.count); data.append(Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)])) }
            else { data.append(le16(UInt16(padded.count))) }
            data.append(padded)
        }
        append(2, 0x10, "UI", Data(syntax.utf8))
        append(8, 0x60, "CS", Data("CT".utf8))
        append(0x20, 0x0D, "UI", Data("1.2.3.4".utf8))
        append(0x20, 0x0E, "UI", Data("1.2.3.4.5".utf8))
        append(0x28, 2, "US", le16(1))
        append(0x28, 4, "CS", Data((mono1 ? "MONOCHROME1" : "MONOCHROME2").utf8))
        append(0x28, 0x10, "US", le16(2)); append(0x28, 0x11, "US", le16(2))
        append(0x28, 0x100, "US", le16(16)); append(0x28, 0x101, "US", le16(12)); append(0x28, 0x102, "US", le16(11)); append(0x28, 0x103, "US", le16(signed ? 1 : 0))
        append(0x28, 0x1050, "DS", Data("128".utf8)); append(0x28, 0x1051, "DS", Data("256".utf8))
        append(0x7FE0, 0x10, "OW", pixelValues.reduce(into: Data()) { $0.append(le16($1)) })
        return data
    }
    func testPreviewPreservesPixelsAndUIDs() throws {
        let image = try DICOMImage(data: fixture())
        XCTAssertEqual(image.rows, 2); XCTAssertEqual(image.columns, 2)
        XCTAssertEqual(image.pixels, [0, 64, 128, 255]); XCTAssertEqual(image.studyUID, "1.2.3.4")
        XCTAssertEqual(image.grayscale(), [0, 64, 128, 255]); XCTAssertNotNil(image.rendered())
    }
    func testSignedStoredBits() throws {
        let image = try DICOMImage(data: fixture(signed: true, pixelValues: [0x0800, 0x0FFF, 0, 0x07FF]))
        XCTAssertEqual(image.pixels, [-2048, -1, 0, 2047])
    }
    func testMonochromeOneInverts() throws {
        let image = try DICOMImage(data: fixture(mono1: true))
        XCTAssertEqual(image.grayscale().first, 255); XCTAssertEqual(image.grayscale().last, 0)
    }
    func testThresholdWindow() throws {
        let image = try DICOMImage(data: fixture())
        XCTAssertEqual(image.grayscale(center: 128, width: 1), [0, 0, 255, 255])
    }
    func testTruncatedImageFailsClosed() {
        XCTAssertThrowsError(try DICOMImage(data: fixture().dropLast(3)))
        XCTAssertThrowsError(try DICOMImage(data: Data([1, 2, 3])))
    }
    func testCompressedSyntaxRequiresHoros() {
        XCTAssertThrowsError(try DICOMImage(data: fixture(syntax: "1.2.840.10008.1.2.4.90"))) { error in XCTAssertTrue(error.localizedDescription.contains("Horos")) }
    }
}

final class WorkspaceTests: XCTestCase {
    func testSeparateStudiesAndDraftHistorySurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(directory: root)
        var a = StudyRecord(id: "a", title: "Study A"), b = StudyRecord(id: "b", title: "Study B")
        a.replaceDraft(ReportDraft(findings: "First findings", impression: "First impression"))
        a.replaceDraft(ReportDraft(findings: "Revised findings", impression: "Revised impression"))
        b.replaceDraft(ReportDraft(findings: "Other study"))
        try store.save(WorkspaceSnapshot(studies: [a, b], selectedID: "b"))
        let result = try XCTUnwrap(store.load())
        XCTAssertEqual(result.selectedID, "b"); XCTAssertEqual(result.studies[0].history[0].findings, "First findings")
        XCTAssertEqual(result.studies[0].draft.findings, "Revised findings"); XCTAssertEqual(result.studies[1].draft.findings, "Other study")
        XCTAssertFalse(String(data: try Data(contentsOf: store.file), encoding: .utf8)!.contains("apiKey"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testExportIsAlwaysClearlyDraft() {
        let d = ReportDraft(findings: "Findings", impression: "Impression")
        XCTAssertTrue(d.text.hasPrefix("DRAFT — REQUIRES RADIOLOGIST REVIEW"))
        XCTAssertTrue(d.text.contains("IMPRESSION\nImpression"))
    }
    func testHorosLinksRejectInjectedCommands() throws {
        let url = try StudyIdentity.horosURL(studyUID: "1.2.840.1")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first?.value, "displayStudy"); XCTAssertEqual(query.last?.value, "1.2.840.1")
        for bad in ["", "1.2&methodName=deleteStudy", "../../../study", "1..2", "hello"] { XCTAssertThrowsError(try StudyIdentity.horosURL(studyUID: bad)) }
    }
    func testToolsHaveNoFinalizeOrArbitraryExecution() {
        let names = Set(AgentClient.tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, Set(["list_series", "view_image", "set_window", "write_draft", "write_report", "list_templates", "select_template"]))
        for tool in AgentClient.tools {
            XCTAssertEqual(tool["strict"] as? Bool, true)
            let params = tool["parameters"] as! [String: Any]
            XCTAssertEqual(params["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(params["required"] as! [String]), Set((params["properties"] as! [String: Any]).keys))
        }
    }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AgentClientTests: XCTestCase {
    func testLocalRevisionAndRestoredHistoryRemainUnsyncedUntilClinicSave() {
        var study = StudyRecord(title: "Synthetic sync test")
        let remote = ReportDraft(findings: "Remote evaluation draft")
        study.replaceDraft(remote, fromClinic: true)
        XCTAssertEqual(study.backendDraftDirty, false)
        study.replaceDraft(ReportDraft(findings: "Local revision"))
        XCTAssertEqual(study.backendDraftDirty, true)
        XCTAssertEqual(study.workflowStatus, "draft")
        XCTAssertEqual(study.history.last, remote)
        study.backendDraftDirty = false
        study.replaceDraft(remote)
        XCTAssertEqual(study.backendDraftDirty, true)
    }
    func makeClient() -> AgentClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return AgentClient(session: URLSession(configuration: config))
    }
    func testResponsesRequestAndToolRoundTripShape() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); var output = Data(); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; output.append(bytes, count: n) }; body = output }
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as! [String: Any]
            XCTAssertEqual(json["store"] as? Bool, false); XCTAssertEqual(json["model"] as? String, "gpt-6-astra")
            let tools = json["tools"] as! [[String: Any]]
            XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").contains("horos") })
            return (200, Data(#"{"status":"completed","output":[{"type":"function_call","name":"view_image","call_id":"call_1","arguments":"{\"index\":0}"}]}"#.utf8))
        }
        let result = try await makeClient().request(apiKey: "test-key", model: "gpt-6-astra", input: [["role": "user", "content": "Inspect the image"]], allowHoros: false)
        XCTAssertEqual(result.output.first?["call_id"] as? String, "call_1")
    }
    func testIncompleteOutputIsRejectedBeforeTools() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"status":"incomplete","output":[{"type":"function_call","name":"write_draft"}]}"#.utf8)) }
        do { _ = try await makeClient().request(apiKey: "test-key", model: "gpt-6-astra", input: [], allowHoros: false); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not complete")) }
    }
    func testAPIErrorIsActionable() async throws {
        MockURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)) }
        do { _ = try await makeClient().request(apiKey: "test-key", model: "gpt-6-astra", input: [], allowHoros: false); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid API key") }
    }
}
