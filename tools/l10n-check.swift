import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let fm = FileManager.default
let japanese = try! NSRegularExpression(pattern: "[\\u3001\\u3002\\u3040-\\u30FF\\u3400-\\u9FFF\\uFF01-\\uFF5E]")
let separators = ["\n", "　·　", " · ", "：", ": ", "、"]

func hasJapanese(_ text: String) -> Bool {
    japanese.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
}

guard let tableSource = try? String(contentsOf: root.appendingPathComponent("Sources/Localization+English.swift"), encoding: .utf8),
      let start = tableSource.range(of: "#\"\"\"\n"), let end = tableSource.range(of: "\n\"\"\"#", range: start.upperBound..<tableSource.endIndex) else {
    FileHandle.standardError.write(Data("l10n-check: Localization+English.swift を読めません\n".utf8))
    exit(1)
}

var exact: Set<String> = []
var templates: [NSRegularExpression] = []
for line in tableSource[start.upperBound..<end.lowerBound].split(separator: "\n") {
    let parts = line.components(separatedBy: " => ")
    guard parts.count == 2 else { continue }
    let source = parts[0].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    exact.insert(source)
    if source.contains("{}") {
        let pattern = source.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern).joined(separator: "(.+?)")
        if let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) { templates.append(regex) }
    }
}

func translatable(_ text: String) -> Bool {
    guard hasJapanese(text) else { return true }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if exact.contains(trimmed) { return true }
    let range = NSRange(location: 0, length: (trimmed as NSString).length)
    for regex in templates {
        guard let match = regex.firstMatch(in: trimmed, range: range) else { continue }
        let groups = (1..<match.numberOfRanges).map { (trimmed as NSString).substring(with: match.range(at: $0)) }
        if groups.allSatisfy({ $0 == "{}" || translatable($0) }) { return true }
    }
    for separator in separators where text.contains(separator) {
        let parts = text.components(separatedBy: separator)
        if parts.count > 1 && parts.allSatisfy(translatable) { return true }
    }
    return false
}

func translatableFragment(_ text: String) -> Bool {
    translatable(text) || translatable(text + "{}") || translatable("{}" + text)
}

func literals(in source: String) -> [(line: Int, text: String)] {
    var result: [(Int, String)] = []
    let chars = Array(source)
    var i = 0, line = 1
    while i < chars.count {
        let c = chars[i]
        if c == "\n" { line += 1; i += 1; continue }
        if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
            while i < chars.count && chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "#" && i + 1 < chars.count && chars[i + 1] == "\"" {
            i += 2
            while i < chars.count && !(chars[i] == "\"" && i + 1 < chars.count && chars[i + 1] == "#") {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
            i += 2
            continue
        }
        if c == "\"" {
            if i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count && !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 3
                continue
            }
            let startLine = line
            var text = ""
            i += 1
            while i < chars.count && chars[i] != "\"" && chars[i] != "\n" {
                if chars[i] == "\\" && i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "(" {
                        var depth = 1
                        i += 2
                        while i < chars.count && depth > 0 {
                            if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                            i += 1
                        }
                        text += "{}"
                        continue
                    }
                    text += next == "n" ? "\n" : next == "t" ? "\t" : String(next)
                    i += 2
                    continue
                }
                text.append(chars[i])
                i += 1
            }
            i += 1
            result.append((startLine, text))
            continue
        }
        i += 1
    }
    return result
}

var files: [URL] = []
for folder in ["Sources", "plugins"] {
    let base = root.appendingPathComponent(folder)
    guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
    for case let url as URL in walker where url.pathExtension == "swift" && !url.lastPathComponent.hasPrefix("Localization") {
        files.append(url)
    }
}

let ignored = ((try? String(contentsOf: root.appendingPathComponent("tools/l10n-ignore.txt"), encoding: .utf8)) ?? "")
    .components(separatedBy: "\n").filter { !$0.isEmpty }

let skipPrefixes = ["print(", "warn(", "fail(", "NSLog(", "assert", "precondition", "fatalError(", "os_log", "logger."]
var missing: [String: [String]] = [:]
for url in files.sorted(by: { $0.path < $1.path }) {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let lines = source.components(separatedBy: "\n")
    for (number, text) in literals(in: source) where hasJapanese(text) && !ignored.contains(where: text.contains) && !translatableFragment(text) {
        let code = lines[number - 1].trimmingCharacters(in: .whitespaces)
        if skipPrefixes.contains(where: { code.hasPrefix($0) }) { continue }
        let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
        missing[text, default: []].append("\(path):\(number)")
    }
}

for text in missing.keys.sorted() {
    let escaped = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    print("\(escaped)\t\(missing[text]!.joined(separator: ", "))")
}
if !missing.isEmpty {
    FileHandle.standardError.write(Data("l10n-check: 英訳のない文字列が \(missing.count) 件あります（Sources/Localization+English.swift に追記してください）\n".utf8))
}
