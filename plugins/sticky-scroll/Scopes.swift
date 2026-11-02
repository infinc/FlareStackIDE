import Foundation

struct StickyScope: Equatable {
    let header: Int
    let end: Int
}

enum StickyScopes {
    private static let header = try! NSRegularExpression(pattern:
        #"^\s*(?:(?:export|default|public|private|protected|internal|fileprivate|open|static|final|abstract|async|override|pub(?:\([a-z]+\))?|unsafe|extern|inline|virtual|const|mutating)\s+)*(?:class|struct|enum|interface|trait|impl|extension|protocol|namespace|module|actor|func|function|def|fn|fun|sub|type\s+\w+\s+(?:struct|interface))\b"#)

    private static func indent(_ line: Substring) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    static func find(in text: String) -> [StickyScope] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var scopes: [StickyScope] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: text)
            guard header.firstMatch(in: text, range: range) != nil else { continue }
            let base = indent(line)
            var end = index
            var cursor = index + 1
            while cursor < lines.count {
                let next = lines[cursor]
                let trimmed = next.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
                if trimmed.isEmpty {
                    cursor += 1
                    continue
                }
                if indent(next) > base {
                    end = cursor
                } else if trimmed.hasPrefix(")") || trimmed.hasPrefix("{") {
                    end = cursor
                } else if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") || trimmed.lowercased().hasPrefix("end") {
                    end = cursor
                    break
                } else {
                    break
                }
                cursor += 1
            }
            if end > index { scopes.append(StickyScope(header: index, end: end)) }
        }
        return scopes
    }

    static func active(_ scopes: [StickyScope], line: Int) -> [StickyScope] {
        scopes.filter { $0.header < line && line <= $0.end }
    }
}
