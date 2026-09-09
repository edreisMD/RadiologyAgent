import Foundation
import Security
import RadAgentCore

enum APIConfiguration {
    static var fileValues: [String: String] {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RadAgent")
        let roots = [support, Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent(), sourceRoot]
        var result: [String: String] = [:]
        for root in roots.reversed() {
            if let text = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) {
                let values = EnvironmentFile.parse(text)
                result.merge(values) { _, newer in newer }
            }
        }
        return result
    }
    static var defaultKey: String { ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? fileValues["OPENAI_API_KEY"] ?? "" }
    static var key: String { let override = APIKeyStore.read(); return override.isEmpty ? defaultKey : override }
    static var model: String { UserDefaults.standard.string(forKey: "modelID") ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? fileValues["OPENAI_MODEL"] ?? "gpt-6-astra" }
    static var isConfigured: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum APIKeyStore {
    static let service = "ai.radiologyagent.RadAgent"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "openai"] }
    static func read() -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query; q.merge(attributes) { _, value in value }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(q as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw RadError.message("Could not save the key in macOS Keychain (\(result)).") }
    }
}
