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

    static func overview(for dir: URL) -> GitOverview? {
        guard run(["rev-parse", "--show-toplevel"], in: dir) != nil else { return nil }
        var info = GitOverview()
        info.branch = branch(in: dir) ?? "(不明)"
        if let upstream = run(["rev-parse", "--abbrev-ref", "@{u}"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            info.upstream = upstream
            let counts = (run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: dir) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            info.behind = counts.first ?? 0
            info.ahead = counts.count > 1 ? counts[1] : 0
        }
        info.local = lines(["branch", "--format=%(refname:short)"], in: dir)
        info.remote = lines(["branch", "-r", "--format=%(refname:short)"], in: dir)
            .filter { $0.contains("/") && !$0.hasSuffix("/HEAD") }
        info.changes = lines(["status", "--porcelain=v1", "--untracked-files=all"], in: dir).compactMap { line in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let kind: GitChange.Kind
            if code == "??" { kind = .untracked }
            else if code.contains("D") { kind = .deleted }
            else if code.first == "R" { kind = .renamed }
            else if code.first == "A" { kind = .added }
            else { kind = .modified }
            return GitChange(kind: kind, path: path, staged: code.first != " " && code != "??")
        }
        info.total = Int(lines(["rev-list", "--count", "--all"], in: dir).first ?? "0") ?? 0
        info.commits = lines(["log", "--all", "--date-order", "--date=format:%Y-%m-%d %H:%M", "--format=%H%x1f%P%x1f%h%x1f%ad%x1f%an%x1f%s%x1f%D", "-n", "300"], in: dir)
            .compactMap { line in
                let f = line.components(separatedBy: "\u{1F}")
                guard f.count >= 7 else { return nil }
                let raw = f[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let refs = raw.map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst(8)) : $0 }.filter { !$0.isEmpty && $0 != "HEAD" }
                return GitCommit(id: f[0], parents: f[1].split(separator: " ").map(String.init), hash: f[2], date: f[3], author: f[4],
                                 subject: f[5], refs: refs, head: raw.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") })
            }
        return info
    }
}

struct GitChange {
    enum Kind { case untracked, added, modified, deleted, renamed }
    let kind: Kind
    let path: String
    let staged: Bool

    var letter: String {
        switch kind {
        case .untracked: return "U"
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }

    var color: NSColor {
        switch kind {
        case .untracked: return .systemOrange
        case .added: return .systemGreen
        case .modified: return .systemCyan
        case .deleted: return .systemRed
        case .renamed: return .systemPurple
        }
    }
}

struct GitCommit {
    let id: String
    let parents: [String]
    let hash: String
    let date: String
    let author: String
    let subject: String
    let refs: [String]
    let head: Bool
}

struct GraphRow {
    var lane = 0
    var upper: [(Int, Int)] = []
    var lower: [(Int, Int)] = []
    var width: Int { ([lane] + upper.flatMap { [$0.0, $0.1] } + lower.flatMap { [$0.0, $0.1] }).max()! + 1 }

    static func layout(_ commits: [GitCommit]) -> [GraphRow] {
        var lanes: [String?] = []
        func slot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }
        return commits.map { commit in
            var row = GraphRow()
            row.lane = lanes.firstIndex(of: commit.id) ?? slot()
            for (i, l) in lanes.enumerated() where l != nil {
                row.upper.append((i, l == commit.id ? row.lane : i))
                if l == commit.id { lanes[i] = nil }
            }
            for (i, l) in lanes.enumerated() where l != nil { row.lower.append((i, i)) }
            if let first = commit.parents.first {
                lanes[row.lane] = first
                row.lower.append((row.lane, row.lane))
            }
            for parent in commit.parents.dropFirst() {
                if let j = lanes.firstIndex(of: parent) {
                    row.lower.append((row.lane, j))
                } else {
                    let j = slot()
                    lanes[j] = parent
                    row.lower.append((row.lane, j))
                }
            }
            while lanes.last == .some(nil) { lanes.removeLast() }
            return row
        }
    }
}

struct GitOverview {
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var local: [String] = []
    var remote: [String] = []
    var changes: [GitChange] = []
    var commits: [GitCommit] = []
    var total = 0
}
