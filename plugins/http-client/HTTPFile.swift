import Foundation

struct HTTPRequestSpec {
    var line: NSRange
    var name: String?
    var method: String
    var url: String
    var headers: [(String, String)]
    var body: String
}

enum HTTPFile {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT"]
    static let extensions: Set<String> = ["http", "rest"]

    static func parse(_ text: NSString) -> (requests: [HTTPRequestSpec], variables: [String: String]) {
        var requests: [HTTPRequestSpec] = []
        var variables: [String: String] = [:]
        var current: HTTPRequestSpec?
        var name: String?
        var inBody = false
        var bodyLines: [String] = []

        func finish() {
            guard var request = current else { return }
            while bodyLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { bodyLines.removeLast() }
            request.body = bodyLines.joined(separator: "\n")
            requests.append(request)
            current = nil
            bodyLines = []
            inBody = false
        }

        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var content = text.substring(with: range)
            while content.hasSuffix("\n") || content.hasSuffix("\r") { content.removeLast() }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("###") {
                finish()
                let title = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                name = title.isEmpty ? nil : title
                continue
            }
            if current == nil || !inBody {
                if trimmed.hasPrefix("@"), let eq = trimmed.firstIndex(of: "="), current == nil {
                    let key = trimmed[trimmed.index(after: trimmed.startIndex)..<eq].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { variables[key] = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
                    continue
                }
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                    let comment = trimmed.drop { $0 == "#" || $0 == "/" }.trimmingCharacters(in: .whitespaces)
                    if comment.hasPrefix("@name ") { name = comment.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                    continue
                }
            }
            if current == nil {
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                let method = parts.first.map { $0.uppercased() } ?? "GET"
                let hasMethod = methods.contains(method)
                let url = hasMethod ? (parts.count > 1 ? parts[1] : "") : parts[0]
                guard !url.isEmpty else { continue }
                current = HTTPRequestSpec(line: range, name: name, method: hasMethod ? method : "GET", url: url, headers: [], body: "")
                name = nil
                continue
            }
            if inBody {
                bodyLines.append(content)
            } else if trimmed.isEmpty {
                inBody = true
            } else if trimmed.hasPrefix("?") || trimmed.hasPrefix("&") {
                current?.url += trimmed
            } else if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current?.headers.append((key, value))
            }
        }
        finish()
        return (requests, variables)
    }

    static func substitute(_ text: String, _ variables: [String: String]) -> String {
        var result = text
        for _ in 0..<3 {
            guard result.contains("{{") else { break }
            var output = ""
            var rest = result[...]
            while let open = rest.range(of: "{{") {
                output += rest[..<open.lowerBound]
                guard let close = rest[open.upperBound...].range(of: "}}") else {
                    output += rest[open.lowerBound...]
                    rest = rest[rest.endIndex...]
                    break
                }
                let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                output += value(key, variables) ?? "{{\(key)}}"
                rest = rest[close.upperBound...]
            }
            output += rest
            result = output
        }
        return result
    }

    private static func value(_ key: String, _ variables: [String: String]) -> String? {
        switch key {
        case "$timestamp": return String(Int(Date().timeIntervalSince1970))
        case "$uuid", "$guid": return UUID().uuidString.lowercased()
        case "$isoTimestamp", "$datetime iso8601": return ISO8601DateFormatter().string(from: Date())
        default:
            if key.hasPrefix("$processEnv ") { return ProcessInfo.processInfo.environment[String(key.dropFirst(12))] }
            return variables[key]
        }
    }
}
