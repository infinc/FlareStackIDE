import AppKit
@testable import FlareStackIDE

enum CodeInterpolator {
    static let pluginID = "interpolate-code"
    private static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`"]
    private static let closers: Set<String> = [")", "]", "}", "\"", "`"]
    private static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let python: Set<String> = ["py", "pyw", "pyi"]

    private static func char(_ text: NSString, _ index: Int) -> String {
        index >= 0 && index < text.length ? text.substring(with: NSRange(location: index, length: 1)) : ""
    }

    private static func replace(_ textView: NSTextView, _ range: NSRange, with text: String, caret: Int, selection: Int = 0) {
        textView.insertText(text, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + caret, length: selection))
    }

    static func shouldChange(_ textView: NSTextView, range: NSRange, text: String) -> Bool {
        guard !textView.hasMarkedText(), (text as NSString).length == 1 else { return true }
        let string = textView.string as NSString
        let next = char(string, NSMaxRange(range))
        if range.length == 0, closers.contains(text), next == text {
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return false
        }
        guard let close = pairs[text] else { return true }
        if range.length > 0 {
            let inner = string.substring(with: range)
            guard !inner.contains("\n") || text != "\"" else { return true }
            replace(textView, range, with: text + inner + close, caret: 1, selection: range.length)
            return false
        }
        if text == close, char(string, range.location - 1) == text, char(string, range.location - 2) == text { return true }
        if text == close, char(string, range.location - 1).range(of: #"[A-Za-z0-9_]"#, options: .regularExpression) != nil { return true }
        if !next.isEmpty, next.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !closers.contains(next), !",;:".contains(next) {
            return true
        }
        replace(textView, range, with: text + close, caret: 1)
        return false
    }

    static func deleteBackward(_ textView: NSTextView) -> Bool {
        let range = textView.selectedRange()
        guard !textView.hasMarkedText(), range.length == 0, range.location > 0 else { return false }
        let string = textView.string as NSString
        guard let close = pairs[char(string, range.location - 1)], char(string, range.location) == close else { return false }
        replace(textView, NSRange(location: range.location - 1, length: 2), with: "", caret: 0)
        return true
    }

    static func newline(_ textView: NSTextView, ext: String) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let range = textView.selectedRange()
        let string = textView.string as NSString
        let line = string.lineRange(for: NSRange(location: range.location, length: 0))
        let before = string.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let unit = indent.contains("\t") ? "\t" : "    "

        if markdown.contains(ext), let continued = listMarker(before) {
            if continued.isEmpty {
                replace(textView, NSRange(location: line.location, length: range.location - line.location + range.length), with: "", caret: 0)
            } else {
                let text = "\n" + continued
                replace(textView, range, with: text, caret: (text as NSString).length)
            }
            return true
        }

        let prev = char(string, range.location - 1)
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if ["(", "[", "{"].contains(prev), let close = pairs[prev] {
            let inner = "\n" + indent + unit
            if char(string, NSMaxRange(range)) == close {
                replace(textView, range, with: inner + "\n" + indent, caret: (inner as NSString).length)
            } else {
                replace(textView, range, with: inner, caret: (inner as NSString).length)
            }
            return true
        }
        if python.contains(ext), trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
            let text = "\n" + indent + unit
            replace(textView, range, with: text, caret: (text as NSString).length)
            return true
        }
        guard !indent.isEmpty else { return false }
        let text = "\n" + indent
        replace(textView, range, with: text, caret: (text as NSString).length)
        return true
    }

    private static func listMarker(_ line: String) -> String? {
        let pattern = #"^([ \t]*)([-*+]|(\d+)([.)])|>)([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let ns = line as NSString
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let content = group(7) ?? ""
        if content.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        let indent = group(1) ?? "", space = group(5) ?? " "
        var marker = group(2) ?? "-"
        if let number = group(3).flatMap(Int.init) { marker = "\(number + 1)\(group(4) ?? ".")" }
        return indent + marker + space + (group(6) != nil ? "[ ] " : "")
    }
}
