import Foundation

/// Reads literal configuration values; never evaluates shell expressions.
public enum EnvironmentFile {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard ["OPENAI_API_KEY", "OPENAI_MODEL", "RADAGENT_BACKEND_URL", "RADAGENT_BACKEND_TOKEN"].contains(key) else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        return values
    }
}
