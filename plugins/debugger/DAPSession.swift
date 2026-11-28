import Foundation
@testable import FlareStackIDE

struct DAPFrame {
    let id: Int
    let name: String
    let path: String?
    let line: Int
    let column: Int
}

struct DAPVariable {
    let name: String
    let value: String
    let type: String?
    let reference: Int
}

struct DebugAdapter {
    let name: String
    let command: [String]
    let launch: [String: Any]

    static let pythonExtensions: Set<String> = ["py", "pyw"]
    static let nativeExtensions: Set<String> = ["swift", "c", "cc", "cpp", "cxx", "m", "mm", "rs", "go", "zig"]

    static func python(file: URL, root: URL) -> Result<DebugAdapter, Error> {
        let configured = PluginStore.setting(DebuggerPlugin.pluginID, "python")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let python = LoginShell.which(configured.isEmpty ? "python3" : configured) else {
            return .failure(DebugError.message("python3 が見つかりません"))
        }
        guard LoginShell.run(python, ["-c", "import debugpy; print(debugpy.__version__)"]) != nil else {
            return .failure(DebugError.message("debugpy がありません。ターミナルで \(python) -m pip install debugpy を実行してください"))
        }
        return .success(DebugAdapter(name: "debugpy", command: [python, "-m", "debugpy.adapter"], launch: [
            "type": "python", "request": "launch", "name": file.lastPathComponent, "program": file.path,
            "cwd": root.path, "console": "internalConsole", "justMyCode": true, "stopOnEntry": false,
        ]))
    }

    static func lldb(program: URL, root: URL) -> Result<DebugAdapter, Error> {
        let configured = PluginStore.setting(DebuggerPlugin.pluginID, "lldbDap")?.trimmingCharacters(in: .whitespaces) ?? ""
        let path = configured.isEmpty
            ? LoginShell.which("lldb-dap") ?? LoginShell.run("/usr/bin/xcrun", ["-f", "lldb-dap"]) ?? LoginShell.run("/usr/bin/xcrun", ["-f", "lldb-vscode"])
            : LoginShell.which(configured)
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(DebugError.message("lldb-dap が見つかりません。Xcode か Command Line Tools を入れてください"))
        }
        return .success(DebugAdapter(name: "lldb-dap", command: [path], launch: [
            "type": "lldb", "request": "launch", "name": program.lastPathComponent, "program": program.path,
            "cwd": root.path, "args": [String](), "stopOnEntry": false,
        ]))
    }
}

enum DebugError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text } else { return nil } }
}

final class DAPSession {
    enum State { case starting, running, stopped, ended }

    var onState: ((State) -> Void)?
    var onStopped: ((Int, String) -> Void)?
    var onOutput: ((String, String) -> Void)?
    private(set) var state = State.starting
    private(set) var threadID = 1
    let adapter: DebugAdapter
    private let pipe = ContentLengthPipe()
    private var seq = 1
    private var handlers: [Int: (Bool, [String: Any], String?) -> Void] = [:]
    private var capabilities: [String: Any] = [:]
    private let breakpoints: () -> [String: Set<Int>]

    init(adapter: DebugAdapter, breakpoints: @escaping () -> [String: Set<Int>]) {
        self.adapter = adapter
        self.breakpoints = breakpoints
    }

    func start(directory: URL) -> Bool {
        pipe.onMessage = { [weak self] in self?.handle($0) }
        pipe.onOutput = { [weak self] in self?.onOutput?("stderr", $0) }
        pipe.onExit = { [weak self] _ in self?.finish() }
        guard pipe.start(adapter.command, directory: directory) else { return false }
        request("initialize", [
            "clientID": "flarestack", "clientName": appName, "adapterID": adapter.name, "pathFormat": "path",
            "linesStartAt1": true, "columnsStartAt1": true, "supportsVariableType": true, "locale": "ja",
        ]) { [weak self] success, body, message in
            guard let self else { return }
            guard success else { return self.fail(message ?? "initialize") }
            self.capabilities = body
            self.request("launch", self.adapter.launch) { [weak self] success, _, message in
                if !success { self?.fail(message ?? "launch") }
            }
        }
        return true
    }

    private func fail(_ message: String) {
        onOutput?("stderr", message + "\n")
        stop()
    }

    func request(_ command: String, _ arguments: [String: Any] = [:], _ completion: ((Bool, [String: Any], String?) -> Void)? = nil) {
        let id = seq
        seq += 1
        if let completion { handlers[id] = completion }
        pipe.send(["seq": id, "type": "request", "command": command, "arguments": arguments])
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response":
            guard let id = (message["request_seq"] as? NSNumber)?.intValue, let handler = handlers.removeValue(forKey: id) else { return }
            handler(message["success"] as? Bool ?? false, message["body"] as? [String: Any] ?? [:], message["message"] as? String)
        case "event":
            event(message["event"] as? String ?? "", message["body"] as? [String: Any] ?? [:])
        case "request":
            let id = message["seq"] ?? 0
            pipe.send(["seq": seq, "type": "response", "request_seq": id, "command": message["command"] ?? "", "success": false,
                       "message": "not supported"])
            seq += 1
        default:
            break
        }
    }

    private func event(_ name: String, _ body: [String: Any]) {
        switch name {
        case "initialized":
            for (path, lines) in breakpoints() { setBreakpoints(path, lines) }
            if capabilities["supportsConfigurationDoneRequest"] as? Bool ?? true { request("configurationDone") }
            change(.running)
        case "stopped":
            threadID = (body["threadId"] as? NSNumber)?.intValue ?? threadID
            change(.stopped)
            onStopped?(threadID, body["reason"] as? String ?? "")
        case "continued":
            change(.running)
        case "output":
            onOutput?(body["category"] as? String ?? "console", body["output"] as? String ?? "")
        case "terminated", "exited":
            if name == "exited", let code = body["exitCode"] {
                onOutput?("console", L("終了コード \(code)") + "\n")
            }
            if name == "terminated" { stop() }
        default:
            break
        }
    }

    private func change(_ next: State) {
        guard state != .ended else { return }
        state = next
        onState?(next)
    }

    func setBreakpoints(_ path: String, _ lines: Set<Int>) {
        guard state != .ended else { return }
        request("setBreakpoints", ["source": ["path": path, "name": (path as NSString).lastPathComponent],
                                   "breakpoints": lines.sorted().map { ["line": $0] }, "sourceModified": false])
    }

    func stackTrace(_ completion: @escaping ([DAPFrame]) -> Void) {
        request("stackTrace", ["threadId": threadID, "startFrame": 0, "levels": 64]) { _, body, _ in
            let frames = (body["stackFrames"] as? [[String: Any]] ?? []).map { frame in
                DAPFrame(id: (frame["id"] as? NSNumber)?.intValue ?? 0, name: frame["name"] as? String ?? "?",
                         path: (frame["source"] as? [String: Any])?["path"] as? String,
                         line: (frame["line"] as? NSNumber)?.intValue ?? 0, column: (frame["column"] as? NSNumber)?.intValue ?? 0)
            }
            completion(frames)
        }
    }

    func scopes(_ frame: Int, _ completion: @escaping ([DAPVariable]) -> Void) {
        request("scopes", ["frameId": frame]) { _, body, _ in
            completion((body["scopes"] as? [[String: Any]] ?? []).map { scope in
                DAPVariable(name: scope["name"] as? String ?? "", value: "", type: nil,
                            reference: (scope["variablesReference"] as? NSNumber)?.intValue ?? 0)
            })
        }
    }

    func variables(_ reference: Int, _ completion: @escaping ([DAPVariable]) -> Void) {
        request("variables", ["variablesReference": reference]) { _, body, _ in
            completion((body["variables"] as? [[String: Any]] ?? []).map { item in
                DAPVariable(name: item["name"] as? String ?? "", value: item["value"] as? String ?? "", type: item["type"] as? String,
                            reference: (item["variablesReference"] as? NSNumber)?.intValue ?? 0)
            })
        }
    }

    func evaluate(_ expression: String, frame: Int?, _ completion: @escaping (String) -> Void) {
        var arguments: [String: Any] = ["expression": expression, "context": "repl"]
        if let frame { arguments["frameId"] = frame }
        request("evaluate", arguments) { success, body, message in
            completion(success ? body["result"] as? String ?? "" : message ?? "")
        }
    }

    func step(_ command: String) {
        guard state == .stopped else { return }
        request(command, ["threadId": threadID])
        change(.running)
    }

    func stop() {
        guard state != .ended else { return }
        if pipe.isRunning {
            request("disconnect", ["terminateDebuggee": true, "restart": false])
            let pipe = self.pipe
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pipe.terminate() }
        }
        finish()
    }

    private func finish() {
        guard state != .ended else { return }
        handlers.values.forEach { $0(false, [:], nil) }
        handlers = [:]
        state = .ended
        onState?(.ended)
    }
}
