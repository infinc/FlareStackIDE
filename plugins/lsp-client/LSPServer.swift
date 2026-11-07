import Foundation
@testable import FlareStackIDE

struct LSPServerSpec {
    let id: String
    let name: String
    let setting: String
    let candidates: [[String]]
    let install: String
}

enum LSPLanguage {
    static let servers: [String: LSPServerSpec] = Dictionary(uniqueKeysWithValues: [
        LSPServerSpec(id: "python", name: "Python", setting: "command",
                      candidates: [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]],
                      install: "pip install pyright"),
        LSPServerSpec(id: "typescript", name: "TypeScript / JavaScript", setting: "commandTypeScript",
                      candidates: [["typescript-language-server", "--stdio"]],
                      install: "npm install -g typescript typescript-language-server"),
        LSPServerSpec(id: "swift", name: "Swift", setting: "commandSwift",
                      candidates: [["sourcekit-lsp"], ["xcrun", "sourcekit-lsp"]],
                      install: "xcode-select --install"),
        LSPServerSpec(id: "rust", name: "Rust", setting: "commandRust",
                      candidates: [["rust-analyzer"]], install: "rustup component add rust-analyzer"),
        LSPServerSpec(id: "go", name: "Go", setting: "commandGo",
                      candidates: [["gopls"]], install: "go install golang.org/x/tools/gopls@latest"),
        LSPServerSpec(id: "clang", name: "C / C++ / Objective-C", setting: "commandC",
                      candidates: [["clangd"], ["xcrun", "clangd"]], install: "xcode-select --install"),
        LSPServerSpec(id: "ruby", name: "Ruby", setting: "commandRuby",
                      candidates: [["ruby-lsp"], ["solargraph", "stdio"]], install: "gem install ruby-lsp"),
        LSPServerSpec(id: "php", name: "PHP", setting: "commandPHP",
                      candidates: [["intelephense", "--stdio"], ["phpactor", "language-server"]], install: "npm install -g intelephense"),
        LSPServerSpec(id: "shell", name: "シェルスクリプト", setting: "commandShell",
                      candidates: [["bash-language-server", "start"]], install: "npm install -g bash-language-server"),
        LSPServerSpec(id: "lua", name: "Lua", setting: "commandLua",
                      candidates: [["lua-language-server"]], install: "brew install lua-language-server"),
    ].map { ($0.id, $0) })

    static let table: [String: (id: String, server: String)] = [
        "py": ("python", "python"), "pyi": ("python", "python"), "pyw": ("python", "python"),
        "ts": ("typescript", "typescript"), "mts": ("typescript", "typescript"), "cts": ("typescript", "typescript"),
        "tsx": ("typescriptreact", "typescript"), "js": ("javascript", "typescript"), "mjs": ("javascript", "typescript"),
        "cjs": ("javascript", "typescript"), "jsx": ("javascriptreact", "typescript"),
        "swift": ("swift", "swift"),
        "rs": ("rust", "rust"),
        "go": ("go", "go"),
        "c": ("c", "clang"), "h": ("c", "clang"), "cpp": ("cpp", "clang"), "cc": ("cpp", "clang"), "cxx": ("cpp", "clang"),
        "hpp": ("cpp", "clang"), "hh": ("cpp", "clang"), "hxx": ("cpp", "clang"), "m": ("objective-c", "clang"),
        "mm": ("objective-cpp", "clang"),
        "rb": ("ruby", "ruby"), "rake": ("ruby", "ruby"),
        "php": ("php", "php"),
        "sh": ("shellscript", "shell"), "bash": ("shellscript", "shell"),
        "lua": ("lua", "lua"),
    ]

    static func language(for url: URL?) -> String? { url.flatMap { table[$0.pathExtension.lowercased()]?.id } }

    static func server(for url: URL?) -> LSPServerSpec? {
        url.flatMap { table[$0.pathExtension.lowercased()] }.flatMap { servers[$0.server] }
    }
}

enum LoginShell {
    private static let lock = NSLock()
    private static var cachedPath: String?

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }
        let found = run("/bin/zsh", ["-lc", "printf '%s\\n' \"$PATH\""]) ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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

enum SwiftWorkspace {
    private static let markers = ["Package.swift", "compile_commands.json", "compile_flags.txt", "buildServer.json", ".bsp",
                                  "build/compile_commands.json", "build/compile_flags.txt"]
    private static let skipped: Set<String> = ["build", "DerivedData", "node_modules", "Pods", "Carthage", "venv"]
    private static let limit = 5000
    private static let sdk: String = LoginShell.run("/usr/bin/xcrun", ["--show-sdk-path"]) ?? ""

    static func arguments(root: URL) -> [String] {
        let fm = FileManager.default
        guard !markers.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }),
              let database = generate(root: root) else { return [] }
        return ["--compilation-db-search-path", relative(database.deletingLastPathComponent(), from: root)]
    }

    private static func generate(root: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        var groups: [URL: [String]] = [:]
        var count = 0
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            groups[url.deletingLastPathComponent().standardizedFileURL, default: []].append(url.standardizedFileURL.path)
            count += 1
            if count >= limit { break }
        }
        guard !groups.isEmpty else { return nil }
        let sdkArgs = sdk.isEmpty ? [] : ["-sdk", sdk]
        var entries: [[String: Any]] = []
        for (directory, files) in groups {
            let sorted = files.sorted()
            let arguments = ["swiftc", "-module-name", moduleName(directory, root: root)] + sdkArgs + sorted
            entries += sorted.map { ["directory": root.path, "file": $0, "arguments": arguments] }
        }
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("LSP")
            .appendingPathComponent(String(format: "%08x", stableHash(root.standardizedFileURL.path)))
        let file = folder.appendingPathComponent("compile_commands.json")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: entries).write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file
    }

    private static func moduleName(_ directory: URL, root: URL) -> String {
        let generic: Set<String> = ["Sources", "Source", "src"]
        let base = directory.path == root.standardizedFileURL.path || generic.contains(directory.lastPathComponent)
            ? root.lastPathComponent : directory.lastPathComponent
        let name = String(base.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return name.first?.isNumber == false ? name : "_" + name
    }

    private static func stableHash(_ text: String) -> UInt32 {
        text.utf8.reduce(2166136261 as UInt32) { ($0 ^ UInt32($1)) &* 16777619 }
    }

    private static func relative(_ target: URL, from base: URL) -> String {
        let to = target.standardizedFileURL.pathComponents
        let from = base.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(to.count, from.count), to[shared] == from[shared] { shared += 1 }
        return (Array(repeating: "..", count: from.count - shared) + to[shared...]).joined(separator: "/")
    }
}

final class LSPServer {
    let root: URL
    let language: String
    private(set) var command: [String] = []
    var onNotification: ((String, [String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var onFailure: (() -> Void)?
    private(set) var displayName = "LSP"
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let readQueue = DispatchQueue(label: "\(appName).lsp.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "\(appName).lsp.write", qos: .userInitiated)
    private var buffer = Data()
    private var nextID = 1
    private var handlers: [Int: (Any?) -> Void] = [:]
    private var ready = false
    private var queued: [() -> Void] = []
    private var stopping = false
    private(set) var capabilities: [String: Any] = [:]

    init(root: URL, language: String) {
        self.root = root
        self.language = language
    }

    func start(resolve: @escaping () -> [String]?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let command = resolve()
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                guard let command, self.launch(command) else { return self.onFailure?() ?? () }
            }
        }
    }

    private func launch(_ command: [String]) -> Bool {
        guard let executable = command.first else { return false }
        self.command = command
        displayName = (executable as NSString).lastPathComponent.replacingOccurrences(of: "-langserver", with: "").capitalized
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
            self?.readQueue.async { self?.received(data) }
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
        guard process.isRunning else { return }
        let process = process
        let handle = input.fileHandleForWriting
        writeQueue.async {
            guard process.isRunning, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            data.append(body)
            try? handle.write(contentsOf: data)
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        var messages: [[String: Any]] = []
        defer {
            if !messages.isEmpty {
                DispatchQueue.main.async { [weak self] in messages.forEach { self?.handle($0) } }
            }
        }
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
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { messages.append(message) }
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
