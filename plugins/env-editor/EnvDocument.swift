import Foundation

struct EnvEntry: Equatable {
    var key: String
    var value: String
    var comment: String
    var exported = false
    var quote: Character?
    var isComment = false
    var source: String?

    var isVariable: Bool { !isComment }

    static func comment(_ line: String) -> EnvEntry { EnvEntry(key: "", value: "", comment: "", isComment: true, source: line) }
}

struct EnvDocument {
    var entries: [EnvEntry]
    var trailingNewline: Bool

    init(text: String) {
        trailingNewline = text.hasSuffix("\n") || text.isEmpty
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        if text.isEmpty { lines = [] }
        entries = lines.map { line in
            var entry = Self.parse(line)
            entry.source = line
            return entry
        }
    }

    private static let keyPattern = try! NSRegularExpression(pattern: #"^[ \t]*(export[ \t]+)?([A-Za-z_][A-Za-z0-9_.\-]*)[ \t]*=[ \t]*(.*)$"#)

    static func parse(_ line: String) -> EnvEntry {
        let ns = line as NSString
        guard let match = keyPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return .comment(line) }
        let key = ns.substring(with: match.range(at: 2))
        let exported = match.range(at: 1).location != NSNotFound
        let rest = ns.substring(with: match.range(at: 3))
        if let first = rest.first, first == "\"" || first == "'" || first == "`" {
            var value = ""
            var escaped = false
            var index = rest.index(after: rest.startIndex)
            while index < rest.endIndex {
                let c = rest[index]
                if escaped {
                    value.append(first == "\"" && c == "n" ? "\n" : c)
                    escaped = false
                } else if c == "\\" && first == "\"" {
                    escaped = true
                } else if c == first {
                    let after = rest[rest.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    let comment = after.hasPrefix("#") ? String(after.dropFirst()).trimmingCharacters(in: .whitespaces) : ""
                    guard after.isEmpty || after.hasPrefix("#") else { return .comment(line) }
                    return EnvEntry(key: key, value: value, comment: comment, exported: exported, quote: first)
                } else {
                    value.append(c)
                }
                index = rest.index(after: index)
            }
            return .comment(line)
        }
        var value = rest
        var comment = ""
        if let hash = rest.range(of: " #") ?? rest.range(of: "\t#") {
            value = String(rest[..<hash.lowerBound])
            comment = String(rest[hash.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("#") {
            value = ""
            comment = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return EnvEntry(key: key, value: value.trimmingCharacters(in: .whitespaces), comment: comment, exported: exported)
    }

    static func line(_ entry: EnvEntry) -> String {
        if let source = entry.source { return source }
        var value = entry.value
        var quote = entry.quote
        if quote == nil, value.contains(where: { " #\"'\n\t".contains($0) }) || value != value.trimmingCharacters(in: .whitespaces) {
            quote = "\""
        }
        if quote == "\"" {
            value = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        } else if let quote, value.contains(quote) {
            var requoted = entry
            requoted.quote = "\""
            return line(requoted)
        }
        let body = quote.map { "\($0)\(value)\($0)" } ?? value
        let comment = entry.comment.isEmpty ? "" : " # " + entry.comment
        return (entry.exported ? "export " : "") + entry.key + "=" + body + comment
    }

    var text: String {
        let lines = entries.map(Self.line)
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    var duplicateKeys: Set<String> {
        var seen = Set<String>(), duplicates = Set<String>()
        for entry in entries where entry.isVariable && !seen.insert(entry.key).inserted { duplicates.insert(entry.key) }
        return duplicates
    }
}
