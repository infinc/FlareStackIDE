import Foundation

enum Refactor {
    private static let skipped: Set<String> = [".git", ".DS_Store", "node_modules", "build", ".build", ".idea"]
    private static let importLine = try! NSRegularExpression(
        pattern: #"^\s*(import|from|#include|#import|@import|require|use|using|include)\b.*$|^.*\b(require|import)\s*\(.*$"#,
        options: [.anchorsMatchLines])

    static func apply(in base: URL, from old: URL, to new: URL, isDirectory: Bool) -> Int {
        let oldName = old.lastPathComponent, newName = new.lastPathComponent
        let oldStem = isDirectory ? oldName : old.deletingPathExtension().lastPathComponent
        let newStem = isDirectory ? newName : new.deletingPathExtension().lastPathComponent
        let e = NSRegularExpression.escapedPattern(for:)

        var rules: [(NSRegularExpression, String, Bool)] = []
        if isDirectory {
            rules.append((try! NSRegularExpression(pattern: #"(?<![\w.\-])"# + e(oldName) + #"(?=/)"#), newName, false))
        } else {
            rules.append((try! NSRegularExpression(pattern: #"(?<![\w\-])"# + e(oldName) + #"(?![\w\-])"#), newName, false))
        }
        if oldStem != newStem, !oldStem.isEmpty {
            rules.append((try! NSRegularExpression(pattern: #"(?<![\w\-])"# + e(oldStem) + #"(?![\w\-])"#), newStem, true))
        }

        var changed = 0
        for file in textFiles(in: base) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let result = rewrite(text, rules)
            guard result != text, (try? result.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
            changed += 1
        }
        return changed
    }

    private static func rewrite(_ text: String, _ rules: [(NSRegularExpression, String, Bool)]) -> String {
        var result = text
        for (regex, replacement, importsOnly) in rules {
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            guard importsOnly else {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
                continue
            }
            let ns = result as NSString
            var pieces: [String] = []
            var cursor = 0
            for match in importLine.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                let line = ns.substring(with: match.range)
                pieces.append(regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: template))
                cursor = match.range.location + match.range.length
            }
            pieces.append(ns.substring(from: cursor))
            result = pieces.joined()
        }
        return result
    }

    private static func textFiles(in base: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 2_000_000,
                  let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
            files.append(url)
        }
        return files
    }
}
