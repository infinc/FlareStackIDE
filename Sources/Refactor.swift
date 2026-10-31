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

    private static let pathToken = try! NSRegularExpression(pattern: #"(?<=["'`(<])[^"'`()<>\s]+(?=["'`)>])"#)

    static func move(in base: URL, from old: URL, to new: URL, isDirectory: Bool) -> Int {
        let root = canonical(base), oldPath = canonical(old), newPath = canonical(new)
        let forward = { (path: String) in relocate(path, oldPath, newPath) }
        let back = { (path: String) in relocate(path, newPath, oldPath) }
        let oldBare = isDirectory ? nil : (oldPath as NSString).deletingPathExtension
        let newBare = (newPath as NSString).deletingPathExtension
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }

        var changed = 0
        for file in textFiles(in: base) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let here = canonical(file)
            let dir = (here as NSString).deletingLastPathComponent
            let oldDir = (back(here) as NSString).deletingLastPathComponent
            let selfMoved = back(here) != here
            let own = file.pathExtension

            func target(_ token: String, from folder: String) -> String? {
                let path = normalize(folder + "/" + token)
                if path == oldPath || path.hasPrefix(oldPath + "/") { return forward(path) }
                let pathLike = token.hasPrefix(".") || token.contains("/")
                if path == oldBare, pathLike { return newBare }
                guard selfMoved, folder == oldDir, pathLike || token.contains(".") else { return nil }
                return exists(path) || (pathLike && exists(path + "." + own)) ? path : nil
            }

            func rewritten(_ token: String) -> String? {
                guard !token.contains("://"), !token.hasPrefix("/"), !token.hasPrefix("#"), !token.hasPrefix("@") else { return nil }
                let cut = token.firstIndex { $0 == "#" || $0 == "?" } ?? token.endIndex
                let path = String(token[..<cut]), rest = token[cut...]
                guard !path.isEmpty else { return nil }
                if let found = target(path, from: oldDir) {
                    var result = relative(found, from: dir)
                    if path.hasPrefix("."), !result.hasPrefix(".") { result = "./" + result }
                    return result == path ? nil : result + rest
                }
                if !path.hasPrefix("."), let found = target(path, from: root), found.hasPrefix(root + "/") {
                    let result = String(found.dropFirst(root.count + 1))
                    return result == path ? nil : result + rest
                }
                return nil
            }

            let ns = text as NSString
            var result = text
            for match in pathToken.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let range = Range(match.range, in: text), let value = rewritten(String(text[range])),
                      let current = Range(match.range, in: result) else { continue }
                result.replaceSubrange(current, with: value)
            }
            if file.pathExtension == "py" { result = moveModules(result, root: root, oldPath: oldPath, newPath: newPath, isDirectory: isDirectory) }
            guard result != text, (try? result.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
            changed += 1
        }
        return changed
    }

    private static func moveModules(_ text: String, root: String, oldPath: String, newPath: String, isDirectory: Bool) -> String {
        func module(_ path: String) -> String? {
            guard path.hasPrefix(root + "/") else { return nil }
            let inner = String(path.dropFirst(root.count + 1))
            return (isDirectory ? inner : (inner as NSString).deletingPathExtension).replacingOccurrences(of: "/", with: ".")
        }
        guard isDirectory || oldPath.hasSuffix(".py"), let oldName = module(oldPath), let newName = module(newPath), oldName != newName else { return text }
        let e = NSRegularExpression.escapedPattern(for:)
        let split = { (name: String) -> (String, String) in
            let parts = name.components(separatedBy: ".")
            return (parts.dropLast().joined(separator: "."), parts.last ?? name)
        }
        let (oldParent, stem) = split(oldName), (newParent, _) = split(newName)
        var result = text
        func replace(_ pattern: String, _ value: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
        if oldName.contains(".") {
            replace(#"(?<![\w.])"# + e(oldName) + #"(?!\w)"#, newName)
        } else {
            replace(#"(?m)^from\s+"# + e(oldName) + #"(?=\s+import\b)"#, "from \(newName)")
            replace(#"(?m)^import\s+"# + e(oldName) + #"[ \t]*$"#, newParent.isEmpty ? "import \(newName)" : "from \(newParent) import \(stem)")
        }
        if !oldParent.isEmpty, !newParent.isEmpty, oldParent != newParent {
            replace(#"(?m)^from\s+"# + e(oldParent) + #"\s+import\s+"# + e(stem) + #"[ \t]*$"#, "from \(newParent) import \(stem)")
        }
        return result
    }

    private static func canonical(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    private static func relocate(_ path: String, _ from: String, _ to: String) -> String {
        if path == from { return to }
        return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }

    private static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.components(separatedBy: "/") where part != "." && !part.isEmpty {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func relative(_ path: String, from folder: String) -> String {
        let to = path.components(separatedBy: "/"), from = folder.components(separatedBy: "/")
        var shared = 0
        while shared < min(to.count, from.count), to[shared] == from[shared] { shared += 1 }
        return (Array(repeating: "..", count: from.count - shared) + to[shared...]).joined(separator: "/")
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
