import Foundation

public struct EngineStudyList: Decodable, Sendable {
    public let studies: [EngineStudy]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey { case studies, hasMore }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        studies = try c.decode([EngineStudy].self, forKey: .studies)
        if let boolean = try? c.decode(Bool.self, forKey: .hasMore) { hasMore = boolean }
        else { hasMore = try c.decode(Int.self, forKey: .hasMore) != 0 }
    }
}

public struct EngineStudy: Identifiable, Codable, Sendable {
    public let id: String
    public let studyUID: String
    public let patientName: String
    public let patientID: String
    public let title: String
    public let modality: String
    public let date: Double
    public let imageCount: Int
    public let accession: String
}
public struct EngineImage: Identifiable, Codable, Sendable {
    public let id: String
    public let index: Int
    public let instance: Int
    public let frame: Int
    public let width: Int
    public let height: Int
    public let sopInstanceUID: String?
}
public struct EngineSeries: Identifiable, Codable, Sendable {
    public let id: String
    public let uid: String
    public let name: String
    public let modality: String
    public let frames: [EngineImage]
}
public struct EngineStudyDetail: Codable, Sendable {
    public let study: EngineStudy
    public let series: [EngineSeries]
    public let frameCount: Int
    public func validate(id: String, expectedUID: String?) throws {
        let frames = series.flatMap(\.frames)
        guard study.id == id, expectedUID == nil || study.studyUID == expectedUID,
              frameCount == frames.count, Set(series.map(\.id)).count == series.count,
              Set(frames.map(\.id)).count == frames.count,
              frames.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.frame >= 0 }) else {
            throw RadError.message("Horos returned an inconsistent study or frame inventory. Images were not opened.")
        }
    }
}
public struct EngineRender: Codable, Sendable {
    public let png: String
    public let width: Int
    public let height: Int
    public let windowWidth: Double
    public let windowCenter: Double
    public let pixelSpacingX: Double
    public let pixelSpacingY: Double
    public let imageID: String
    public let studyID: String
    public let source: String
}
public struct EngineNode: Identifiable, Codable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let aet: String
    public let address: String
    public let port: String
}
public struct EngineConnection: Codable, Sendable {
    public let port: Int
    public let token: String
    public let protocolVersion: Int
    public let pid: Int
    public func validatedURL(route: String) throws -> URL {
        guard (1...65535).contains(port), protocolVersion == 1, token.count >= 32,
              ["/health", "/studies", "/study", "/render", "/open-series", "/pacs/nodes", "/pacs/retrieve"].contains(route),
              let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { throw RadError.message("Invalid Horos engine connection.") }
        return url
    }
}
