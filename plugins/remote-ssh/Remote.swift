import Foundation
@testable import FlareStackIDE

struct RemoteTarget: Codable, Equatable {
    var host: String
    var path: String

    var label: String { "\(host):\(path)" }
}

enum RemoteSSH {
    static let pluginID = "remote-ssh"
    private static let mirrorsKey = "Plugin.remote-ssh.mirrors"
    private static let recentKey = "Plugin.remote-ssh.recent"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("Remote")
    }

    static var mirrors: [String: RemoteTarget] {
        get {
            guard let data = UserDefaults.standard.data(forKey: mirrorsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: RemoteTarget].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: mirrorsKey) }
    }

    static var recent: [RemoteTarget] {
        get {
            guard let data = UserDefaults.standard.data(forKey: recentKey) else { return [] }
            return (try? JSONDecoder().decode([RemoteTarget].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(10))), forKey: recentKey) }
    }

    static func target(for directory: URL) -> RemoteTarget? { mirrors[directory.standardizedFileURL.path] }

    static func mirror(for target: RemoteTarget) -> URL {
        let safe = { (text: String) in String(text.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }) }
        return folder.appendingPathComponent(safe(target.host)).appendingPathComponent(safe(target.path))
    }

    static var configuredHosts: [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            hosts += parts.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
        return Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
    }

    static var sshOptions: [String] {
        let control = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/flarestack-%C").path
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(control)", "-o", "ControlPersist=600"]
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static var excludes: [String] {
        let text = PluginStore.setting(pluginID, "exclude") ?? ""
        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? ["node_modules", ".venv", "venv", "__pycache__", ".DS_Store", "build", "DerivedData"] : list
    }

    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = LoginShell.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func check(_ target: RemoteTarget) -> String? {
        let result = run("/usr/bin/ssh", sshOptions + [target.host, "test -d \(quote(target.path)) && echo ok"])
        if result.status == 0, result.output.hasSuffix("ok") { return nil }
        if result.status == 0 || result.status == 1 { return "リモートにフォルダ \(target.path) がありません" }
        return result.output.isEmpty ? "\(target.host) に接続できませんでした" : result.output
    }

    private static var rsyncShell: String { (["ssh"] + sshOptions).map(quote).joined(separator: " ") }

    static func pull(_ target: RemoteTarget, into local: URL) -> String? {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let excludes = self.excludes.flatMap { ["--exclude", $0] }
        let source = "\(target.host):\(quote(target.path.hasSuffix("/") ? target.path : target.path + "/"))"
        let result = run("/usr/bin/rsync", ["-az", "-e", rsyncShell] + excludes + [source, local.path + "/"])
        return result.status == 0 ? nil : result.output
    }

    static func push(_ relative: [String], of target: RemoteTarget, from local: URL) -> String? {
        guard !relative.isEmpty else { return nil }
        let destination = "\(target.host):\(quote(target.path.hasSuffix("/") ? target.path : target.path + "/"))"
        let files = relative.map { "./" + $0 }
        let result = run("/usr/bin/rsync", ["-az", "--relative", "-e", rsyncShell] + files + [destination], directory: local)
        return result.status == 0 ? nil : result.output
    }

    static func terminalCommand(_ target: RemoteTarget) -> String {
        let remote = "cd \(quote(target.path)) && exec \"$SHELL\" -l"
        let options = sshOptions.dropFirst(2).map(quote).joined(separator: " ")
        return "ssh -t \(options) \(quote(target.host)) \(quote(remote))"
    }
}
