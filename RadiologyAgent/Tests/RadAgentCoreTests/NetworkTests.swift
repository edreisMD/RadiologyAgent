import XCTest
@testable import RadAgentCore

final class NetworkTests: XCTestCase {
    func testClinicAddressRejectsCredentialAndRedirectTricks() throws {
        for base in ["http://clinic.example", "https://user:secret@clinic.example", "https://clinic.example?token=secret", "https://clinic.example#fragment", "https:///missing"] {
            XCTAssertThrowsError(try PrivateHTTP.clinicURL(base, route: "/v1/studies"))
        }
        for route in ["https://other.example", "/v1/../outside", "/v1/studies?token=secret"] { XCTAssertThrowsError(try PrivateHTTP.clinicURL("https://clinic.example", route: route)) }
        let url = try PrivateHTTP.clinicURL("https://clinic.example/radagent", route: "/v1/studies", query: [URLQueryItem(name: "offset", value: "10")])
        XCTAssertEqual(url.absoluteString, "https://clinic.example/radagent/v1/studies?offset=10")
    }
    func testPrivateSessionHasNoPersistentCookiesOrCacheAndRejectsRedirect() {
        let session = PrivateHTTP.session(); defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache); XCTAssertNil(session.configuration.httpCookieStorage)
        let url = URL(string: "https://clinic.example/v1/studies")!
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://other.example"])!
        let delegate = PrivateHTTP()
        var called = false
        delegate.urlSession(session, task: session.dataTask(with: url), willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://other.example")!)) { request in called = true; XCTAssertNil(request) }
        XCTAssertTrue(called)
    }
}

final class InventoryValidationTests: XCTestCase {
    func testChangedStudyAndDuplicateFramesAreRejected() throws {
        var payload: [String: Any] = ["study": ["id":"study-a","studyUID":"1.2.3","patientName":"Synthetic","patientID":"test","title":"Test","modality":"CT","date":0,"imageCount":1,"accession":""],"series":[["id":"series-a","uid":"1.2.4","name":"Test","modality":"CT","frames":[["id":"frame-a","index":0,"instance":1,"frame":0,"width":2,"height":2]]]],"frameCount":1]
        func decode() throws -> EngineStudyDetail { try JSONDecoder().decode(EngineStudyDetail.self, from: JSONSerialization.data(withJSONObject: payload)) }
        try decode().validate(id: "study-a", expectedUID: "1.2.3")
        XCTAssertThrowsError(try decode().validate(id: "study-a", expectedUID: "9.9.9"))
        XCTAssertThrowsError(try decode().validate(id: "different", expectedUID: "1.2.3"))
        payload["frameCount"] = 2
        XCTAssertThrowsError(try decode().validate(id: "study-a", expectedUID: "1.2.3"))
        payload["series"] = [["id":"series-a","uid":"1.2.4","name":"Test","modality":"CT","frames":[["id":"frame-a","index":0,"instance":1,"frame":0,"width":2,"height":2],["id":"frame-a","index":1,"instance":1,"frame":0,"width":2,"height":2]]]]
        XCTAssertThrowsError(try decode().validate(id: "study-a", expectedUID: "1.2.3"))
    }
}
