import Foundation

final class EmmetNode {
    var tag = ""
    var id = ""
    var classes: [String] = []
    var attributes: [(String, String)] = []
    var text = ""
    var count = 1
    var children: [EmmetNode] = []
    var isGroup = false
}

enum Emmet {
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    static let knownTags: Set<String> = ["a", "abbr", "address", "article", "aside", "audio", "b", "blockquote", "body", "br", "button", "canvas", "caption", "code", "col", "dd", "details", "div", "dl", "dt", "em", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "i", "iframe", "img", "input", "label", "legend", "li", "link", "main", "meta", "nav", "ol", "optgroup", "option", "p", "pre", "script", "section", "select", "small", "source", "span", "strong", "style", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr", "u", "ul", "video"]
    private static let defaults: [String: [(String, String)]] = [
        "a": [("href", "")], "img": [("src", ""), ("alt", "")], "input": [("type", "text")], "link": [("rel", "stylesheet"), ("href", "")],
        "script": [("src", "")], "form": [("action", "")], "label": [("for", "")], "iframe": [("src", "")],
    ]
    private static let implicit = ["ul": "li", "ol": "li", "table": "tr", "tbody": "tr", "thead": "tr", "tfoot": "tr", "tr": "td", "select": "option", "optgroup": "option"]
    private static let document = "<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n\t<meta charset=\"UTF-8\">\n\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n\t<title>|</title>\n</head>\n<body>\n\t\n</body>\n</html>"

    private struct Parser {
        let characters: [Character]
        var index = 0

        var current: Character? { index < characters.count ? characters[index] : nil }

        mutating func list(parent: String) -> [EmmetNode]? {
            var siblings: [EmmetNode] = []
            guard var last = item(parent: parent) else { return nil }
            siblings.append(last)
            var stack: [(nodes: [EmmetNode], owner: EmmetNode?, parent: String)] = []
            var currentParent = parent
            func attach(_ nodes: [EmmetNode], to owner: EmmetNode?) { owner?.children.append(contentsOf: nodes) }
            while let op = current, op != ")" {
                index += 1
                switch op {
                case ">":
                    stack.append((siblings, last, currentParent))
                    siblings = []
                    currentParent = last.tag
                case "+":
                    break
                case "^":
                    while current == "^" { index += 1 }
                    guard let top = stack.popLast() else { return nil }
                    attach(siblings, to: top.owner)
                    siblings = top.nodes
                    currentParent = top.parent
                default:
                    return nil
                }
                guard let next = item(parent: currentParent) else { return nil }
                siblings.append(next)
                last = next
            }
            while let top = stack.popLast() {
                attach(siblings, to: top.owner)
                siblings = top.nodes
            }
            return siblings
        }

        mutating func item(parent: String) -> EmmetNode? {
            let node = EmmetNode()
            if current == "(" {
                index += 1
                guard let inner = list(parent: parent), current == ")" else { return nil }
                index += 1
                node.isGroup = true
                node.children = inner
            } else {
                guard element(node, parent: parent) else { return nil }
            }
            if current == "*" {
                index += 1
                guard let number = Int(word { $0.isNumber }), number > 0, number <= 1000 else { return nil }
                node.count = number
            }
            return node
        }

        mutating func word(_ allowed: (Character) -> Bool) -> String {
            let start = index
            while let character = current, allowed(character) { index += 1 }
            return String(characters[start..<index])
        }

        private static func nameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":" || character == "$"
        }

        mutating func element(_ node: EmmetNode, parent: String) -> Bool {
            node.tag = word(Self.nameCharacter)
            var explicit = !node.tag.isEmpty
            while let character = current {
                switch character {
                case "#":
                    index += 1
                    node.id = word(Self.nameCharacter)
                case ".":
                    index += 1
                    node.classes.append(word(Self.nameCharacter))
                case "[":
                    index += 1
                    guard attributes(node) else { return false }
                case "{":
                    index += 1
                    let start = index
                    while let inner = current, inner != "}" { _ = inner; index += 1 }
                    guard current == "}" else { return false }
                    node.text = String(characters[start..<index])
                    index += 1
                default:
                    if !explicit, node.id.isEmpty, node.classes.isEmpty, node.attributes.isEmpty, node.text.isEmpty { return false }
                    explicit = true
                    finish(node, parent: parent)
                    return true
                }
            }
            if !explicit, node.id.isEmpty, node.classes.isEmpty, node.attributes.isEmpty, node.text.isEmpty { return false }
            finish(node, parent: parent)
            return true
        }

        private func finish(_ node: EmmetNode, parent: String) {
            if node.tag.isEmpty { node.tag = Emmet.implicit[parent] ?? "div" }
        }

        mutating func attributes(_ node: EmmetNode) -> Bool {
            while let character = current, character != "]" {
                if character == " " {
                    index += 1
                    continue
                }
                let name = word { $0 != "=" && $0 != "]" && $0 != " " }
                guard !name.isEmpty else { return false }
                var value = ""
                if current == "=" {
                    index += 1
                    if let quote = current, quote == "\"" || quote == "'" {
                        index += 1
                        value = word { $0 != quote }
                        guard current == quote else { return false }
                        index += 1
                    } else {
                        value = word { $0 != "]" && $0 != " " }
                    }
                }
                node.attributes.append((name, value))
            }
            guard current == "]" else { return false }
            index += 1
            return true
        }
    }

    private static func numbered(_ text: String, _ number: Int, _ total: Int) -> String {
        guard text.contains("$") else { return text }
        var result = "", digits = 0
        func flush() {
            guard digits > 0 else { return }
            result += String(repeating: "0", count: max(digits - String(number).count, 0)) + String(number)
            digits = 0
        }
        for character in text {
            if character == "$" {
                digits += 1
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    private static func render(_ nodes: [EmmetNode], indent: String, unit: String, number: Int) -> [String] {
        nodes.flatMap { node in
            (1...node.count).flatMap { i -> [String] in
                let n = node.count > 1 ? i : number
                if node.isGroup { return render(node.children, indent: indent, unit: unit, number: n) }
                return render(element: node, indent: indent, unit: unit, number: n)
            }
        }
    }

    private static func render(element node: EmmetNode, indent: String, unit: String, number: Int) -> [String] {
        let tag = numbered(node.tag, number, node.count)
        var attributes: [(String, String)] = []
        if !node.id.isEmpty { attributes.append(("id", numbered(node.id, number, node.count))) }
        if !node.classes.isEmpty { attributes.append(("class", node.classes.map { numbered($0, number, node.count) }.joined(separator: " "))) }
        for (name, value) in defaults[tag] ?? [] where !node.attributes.contains(where: { $0.0 == name }) { attributes.append((name, value)) }
        attributes += node.attributes.map { ($0.0, numbered($0.1, number, node.count)) }
        let open = "<" + tag + attributes.map { " \($0.0)=\"\($0.1.isEmpty ? "|" : $0.1)\"" }.joined()
        if voidTags.contains(tag) { return [indent + open + ">"] }
        let text = numbered(node.text, number, node.count)
        if node.children.isEmpty {
            return [indent + open + ">" + (text.isEmpty ? "|" : text) + "</\(tag)>"]
        }
        var lines = [indent + open + ">"]
        if !text.isEmpty { lines.append(indent + unit + text) }
        lines += render(node.children, indent: indent + unit, unit: unit, number: number)
        lines.append(indent + "</\(tag)>")
        return lines
    }

    private static func finished(_ text: String) -> (text: String, cursor: Int) {
        var first: Int?
        var result = ""
        for character in text {
            if character == "|" {
                if first == nil { first = result.utf16.count }
            } else {
                result.append(character)
            }
        }
        return (result, first ?? result.utf16.count)
    }

    static func expandHTML(_ abbreviation: String, indent: String, unit: String) -> (text: String, cursor: Int)? {
        if abbreviation == "!" {
            let lines = document.replacingOccurrences(of: "\t", with: unit).components(separatedBy: "\n")
            return finished(lines.enumerated().map { $0.offset == 0 ? $0.element : indent + $0.element }.joined(separator: "\n"))
        }
        let operators = CharacterSet(charactersIn: ">+*.#[{(^")
        guard abbreviation.rangeOfCharacter(from: operators) != nil || knownTags.contains(abbreviation) else { return nil }
        var parser = Parser(characters: Array(abbreviation))
        guard let nodes = parser.list(parent: ""), parser.index == parser.characters.count else { return nil }
        let lines = render(nodes, indent: indent, unit: unit, number: 1)
        return finished(String(lines.joined(separator: "\n").dropFirst(indent.count)))
    }

    private static let cssKeywords: [String: String] = [
        "df": "display: flex;", "dib": "display: inline-block;", "db": "display: block;", "di": "display: inline;", "dn": "display: none;", "dg": "display: grid;",
        "posa": "position: absolute;", "posr": "position: relative;", "posf": "position: fixed;", "poss": "position: sticky;",
        "fxc": "flex-direction: column;", "fxr": "flex-direction: row;", "jcc": "justify-content: center;", "jcsb": "justify-content: space-between;",
        "aic": "align-items: center;", "tac": "text-align: center;", "tal": "text-align: left;", "tar": "text-align: right;",
        "fwb": "font-weight: bold;", "fwn": "font-weight: normal;", "tdn": "text-decoration: none;", "cup": "cursor: pointer;", "ovh": "overflow: hidden;", "bxzb": "box-sizing: border-box;",
    ]
    private static let cssColors = ["c": "color", "bgc": "background-color", "bdc": "border-color"]
    private static let cssLengths = [
        "m": "margin", "mt": "margin-top", "mr": "margin-right", "mb": "margin-bottom", "ml": "margin-left",
        "p": "padding", "pt": "padding-top", "pr": "padding-right", "pb": "padding-bottom", "pl": "padding-left",
        "w": "width", "h": "height", "maw": "max-width", "mah": "max-height", "miw": "min-width", "mih": "min-height",
        "t": "top", "r": "right", "b": "bottom", "l": "left", "fz": "font-size", "lh": "line-height", "bdrs": "border-radius", "g": "gap",
    ]

    private static func cssValue(_ text: String) -> String? {
        var body = text, unit = "px"
        if body.hasSuffix("p") { body.removeLast(); unit = "%" }
        else if body.hasSuffix("e") { body.removeLast(); unit = "em" }
        else if body.hasSuffix("r") { body.removeLast(); unit = "rem" }
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        let values = body.split(separator: "-", omittingEmptySubsequences: true).map { $0 == "0" ? "0" : $0 + unit }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    static func expandCSS(_ abbreviation: String) -> (text: String, cursor: Int)? {
        let key = abbreviation.replacingOccurrences(of: ":", with: "")
        if let found = cssKeywords[key] { return (found, found.utf16.count) }
        var result: String?
        if key.hasPrefix("fw"), let number = Int(key.dropFirst(2)) { result = "font-weight: \(number);" }
        if let hash = key.firstIndex(of: "#"), let property = cssColors[String(key[..<hash])] {
            let digits = key[key.index(after: hash)...]
            if digits.count >= 1, digits.count <= 8, digits.allSatisfy(\.isHexDigit) {
                let text = String(digits)
                let color = text.count == 1 ? String(repeating: text, count: 6) : text.count == 2 ? String(repeating: text, count: 3)
                    : text.count == 3 ? text.map { "\($0)\($0)" }.joined() : text
                result = "\(property): #\(color);"
            }
        }
        if result == nil, let split = key.firstIndex(where: { $0.isNumber || $0 == "-" }),
           let property = cssLengths[String(key[..<split])], let value = cssValue(String(key[split...])) {
            result = "\(property): \(value);"
        }
        return result.map { ($0, $0.utf16.count) }
    }

    static func abbreviation(before text: NSString, at caret: Int) -> Int {
        var start = caret
        var brace = 0, bracket = 0
        while start > 0 {
            let unit = text.character(at: start - 1)
            guard let scalar = UnicodeScalar(unit) else { break }
            let character = Character(scalar)
            if character == "}" { brace += 1 }
            else if character == "{" {
                if brace == 0 { break }
                brace -= 1
            } else if character == "]" { bracket += 1 }
            else if character == "[" {
                if bracket == 0 { break }
                bracket -= 1
            } else if brace == 0, bracket == 0, character == " " || character == "\t" || character == "\n" || character == "<" || character == ">" && start == caret { break }
            start -= 1
        }
        return start
    }
}
