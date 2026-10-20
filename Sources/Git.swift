import AppKit

enum GitFileState: Int {
    case modified, added, untracked

    var color: NSColor {
        switch self {
        case .untracked: return .systemOrange
        case .added: return .systemGreen
        case .modified: return .systemCyan
        }
    }
}

struct GitSnapshot {
    let top: String
    let branch: String
    let states: [String: GitFileState]
    let untrackedDirs: [String]

    func state(of path: String) -> GitFileState? {
        if let state = states[path] { return state }
        return untrackedDirs.contains { path == $0 || path.hasPrefix($0 + "/") } ? .untracked : nil
    }
}

enum Git {
    static func run(_ args: [String], in dir: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func lines(_ args: [String], in dir: URL) -> [String] {
        (run(args, in: dir) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func branch(in dir: URL) -> String? {
        if let name = run(["symbolic-ref", "--short", "HEAD"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return name
        }
        return run(["rev-parse", "--short", "HEAD"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasUpstream(_ dir: URL) -> Bool {
        run(["rev-parse", "--abbrev-ref", "@{u}"], in: dir) != nil
    }

    static func snapshot(for dir: URL) -> GitSnapshot? {
        guard let top = run(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else { return nil }
        let topPath = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        var states: [String: GitFileState] = [:]
        var untrackedDirs: [String] = []
        func mark(_ rel: String, _ state: GitFileState) {
            let key = topPath + "/" + rel
            if (states[key]?.rawValue ?? -1) < state.rawValue { states[key] = state }
        }

        let range: [String]?
        if hasUpstream(dir) {
            range = ["@{u}..HEAD"]
        } else if !lines(["remote"], in: dir).isEmpty {
            range = ["HEAD", "--not", "--remotes"]
        } else {
            range = nil
        }
        if let range {
            lines(["log"] + range + ["--name-only", "--format="], in: dir).forEach { mark($0, .modified) }
        }
        lines(["log"] + (range ?? ["HEAD"]) + ["--since=24.hours", "--diff-filter=A", "--name-only", "--format="], in: dir)
            .forEach { mark($0, .added) }

        let entries = (run(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching"], in: dir) ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            i += 1
            guard entry.count > 3 else { continue }
            let x = entry.first!
            let code = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if x == "R" || x == "C" { i += 1 }
            if code == "??" || code == "!!" {
                if path.hasSuffix("/") { untrackedDirs.append(topPath + "/" + path.dropLast()) }
                else { mark(path, .untracked) }
            }
            else if x == "A" { mark(path, .added) }
            else { mark(path, .modified) }
        }
        return GitSnapshot(top: topPath, branch: branch(in: dir) ?? "", states: states, untrackedDirs: untrackedDirs)
    }

    static func report(for dir: URL) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        func add(_ text: String, header: Bool = false, color: NSColor = .labelColor) {
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: header ? bold : font, .foregroundColor: color]))
        }
        guard run(["rev-parse", "--show-toplevel"], in: dir) != nil else {
            add("このディレクトリはgitで追跡されていません。", color: .secondaryLabelColor)
            return out
        }

        let current = branch(in: dir) ?? "(不明)"
        var head = "ブランチ: \(current)"
        if let upstream = run(["rev-parse", "--abbrev-ref", "@{u}"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let counts = (run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: dir) ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            let behind = counts.first ?? "0", ahead = counts.count > 1 ? counts[1] : "0"
            head += "  →  \(upstream)  ↑\(ahead) ↓\(behind)"
        } else {
            head += "  (upstreamなし)"
        }
        add(head, header: true)
        add("")

        let local = lines(["branch", "--format=%(refname:short)"], in: dir)
        add("ローカルブランチ (\(local.count))", header: true)
        local.forEach { add(($0 == current ? "  * " : "    ") + $0, color: $0 == current ? .systemGreen : .labelColor) }
        add("")

        let remote = lines(["branch", "-r", "--format=%(refname:short)"], in: dir)
            .filter { $0.contains("/") && !$0.hasSuffix("/HEAD") }
        add("リモートブランチ (\(remote.count))", header: true)
        remote.forEach { add("    " + $0) }
        add("")

        let status = lines(["status", "--porcelain=v1", "--untracked-files=all"], in: dir)
        let untracked = status.filter { $0.hasPrefix("??") }.count
        let added = status.filter { $0.hasPrefix("A") }.count
        add("変更", header: true)
        add("    未追跡 \(untracked) / 追加 \(added) / 変更 \(status.count - untracked - added)")
        add("")

        let log = lines(["log", "--graph", "--date=short", "--format=%h %ad %an  %s%d", "-n", "200"], in: dir)
        add("コミット履歴 (\(lines(["rev-list", "--count", "HEAD"], in: dir).first ?? "0"))", header: true)
        log.forEach { add("    " + $0) }
        return out
    }
}
