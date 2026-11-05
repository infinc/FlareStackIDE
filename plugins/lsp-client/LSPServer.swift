import Foundation
@testable import FlareStackIDE

enum LSPLanguage {
    static let table: [String: (id: String, candidates: [[String]])] = [
        "py": ("python", [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]]),
        "pyi": ("python", [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]]),
        "pyw": ("python", [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]]),
    ]

    static func language(for url: URL?) -> String? { url.flatMap { table[$0.pathExtension.lowercased()]?.id } }
}

enum LoginShell {
    private static var cachedPath: String?

    private static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
    }

    static var path: String {
        if let cachedPath { return cachedPath }
        let found = run("printf '%s\\n' \"$PATH\"") ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        cachedPath = found
        return found
    }

    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in path.split(separator: ":") {
            let file = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file) { return file }
        }
        return nil
    }
}

final class LSPServer {
    let root: URL
    let language: String
    let command: [String]
    var onNotification: ((String, [String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private(set) var displayName: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var handlers: [Int: (Any?) -> Void] = [:]
    private var ready = false
    private var queued: [() -> Void] = []
    private var stopping = false
    private(set) var capabilities: [String: Any] = [:]

    init(root: URL, language: String, command: [String]) {
        self.root = root
        self.language = language
        self.command = command
        displayName = (command.first.map { ($0 as NSString).lastPathComponent } ?? "LSP")
            .replacingOccurrences(of: "-langserver", with: "").capitalized
    }

    func start() -> Bool {
        guard let executable = command.first else { return false }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShell.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.exited() } }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        do { try process.run() } catch { return false }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": appName],
            "rootUri": root.absoluteString,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": [
                "textDocument": [
                    "synchronization": ["didSave": true, "dynamicRegistration": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "definition": [:] as [String: Any],
                    "references": [:] as [String: Any],
                    "rename": ["prepareSupport": false],
                    "publishDiagnostics": ["versionSupport": true],
                ],
                "workspace": ["configuration": true, "applyEdit": false],
            ],
        ]
        send(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": params])
        handlers[0] = { [weak self] result in
            guard let self else { return }
            self.capabilities = (result as? [String: Any])?["capabilities"] as? [String: Any] ?? [:]
            self.send(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: Any]])
            self.ready = true
            let pending = self.queued
            self.queued = []
            pending.forEach { $0() }
        }
        return true
    }

    private func whenReady(_ body: @escaping () -> Void) {
        if ready { body() } else { queued.append(body) }
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any], _ completion: @escaping (Any?) -> Void) -> Int {
        let id = nextID
        nextID += 1
        handlers[id] = completion
        whenReady { [weak self] in self?.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
        return id
    }

    func cancel(_ id: Int) {
        guard handlers.removeValue(forKey: id) != nil else { return }
        notify("$/cancelRequest", ["id": id])
    }

    func notify(_ method: String, _ params: [String: Any]) {
        whenReady { [weak self] in self?.send(["jsonrpc": "2.0", "method": method, "params": params]) }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        guard process.isRunning else { return }
        let process = self.process
        request("shutdown", [:]) { [weak self] _ in
            self?.send(["jsonrpc": "2.0", "method": "exit"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
    }

    private func send(_ message: [String: Any]) {
        guard process.isRunning, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
                continue
            }
            let start = separator.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(start, offsetBy: length)
            let body = buffer[start..<end]
            buffer.removeSubrange(buffer.startIndex..<end)
            buffer = Data(buffer)
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            reply(id, to: method, params: message["params"])
        } else if let method {
            onNotification?(method, message["params"] as? [String: Any] ?? [:])
        } else if let id = (message["id"] as? NSNumber)?.intValue, let handler = handlers.removeValue(forKey: id) {
            handler(message["error"] == nil ? message["result"] : nil)
        }
    }

    private func reply(_ id: Any, to method: String, params: Any?) {
        let result: Any
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            result = items.map { _ in NSNull() }
        case "workspace/workspaceFolders":
            result = [["uri": root.absoluteString, "name": root.lastPathComponent]]
        default:
            result = NSNull()
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func exited() {
        output.fileHandleForReading.readabilityHandler = nil
        handlers.values.forEach { $0(nil) }
        handlers = [:]
        if !stopping { onExit?() }
    }
}
