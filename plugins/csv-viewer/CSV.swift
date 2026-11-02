import Foundation

struct CSVDocument: Equatable {
    var rows: [[String]]
    let delimiter: Character
    let newline: String
    let bom: Bool
    let trailingNewline: Bool

    init(text: String, delimiter: Character) {
        self.delimiter = delimiter
        var body = Substring(text)
        bom = body.hasPrefix("\u{FEFF}")
        if bom { body = body.dropFirst() }
        newline = body.contains("\r\n") ? "\r\n" : "\n"
        trailingNewline = body.hasSuffix("\n") || body.hasSuffix("\r\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var started = false
        var iterator = body.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
                started = true
            } else if character == delimiter {
                row.append(field)
                field = ""
                started = true
            } else if character == "\n" || character == "\r\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                started = false
            } else if character != "\r" {
                field.append(character)
                started = true
            }
        }
        if started || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        self.rows = rows
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    private func encode(_ field: String) -> String {
        guard field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    var text: String {
        let body = rows.map { $0.map(encode).joined(separator: String(delimiter)) }.joined(separator: newline)
        return (bom ? "\u{FEFF}" : "") + body + (trailingNewline ? newline : "")
    }
}
