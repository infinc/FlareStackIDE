import Foundation

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

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        return environment
    }
}

final class ContentLengthPipe {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onOutput: ((String) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let readQueue = DispatchQueue(label: "FlareStackIDE.content-length.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "FlareStackIDE.content-length.write", qos: .userInitiated)
    private var buffer = Data()

    var isRunning: Bool { process.isRunning }

    static func frame(_ message: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    static func parse(_ buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
                continue
            }
            let start = separator.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
            let end = buffer.index(start, offsetBy: length)
            let body = buffer[start..<end]
            buffer.removeSubrange(buffer.startIndex..<end)
            buffer = Data(buffer)
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { messages.append(message) }
        }
        return messages
    }

    func start(_ command: [String], directory: URL?) -> Bool {
        guard let executable = command.first else { return false }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory
        process.environment = LoginShell.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                self?.output.fileHandleForReading.readabilityHandler = nil
                self?.errors.fileHandleForReading.readabilityHandler = nil
                self?.onExit?(status)
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.readQueue.async { self?.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { self?.onOutput?(text) }
        }
        do { try process.run() } catch { return false }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return true
    }

    func send(_ message: [String: Any]) {
        guard process.isRunning, let data = Self.frame(message) else { return }
        let process = process
        let handle = input.fileHandleForWriting
        writeQueue.async {
            guard process.isRunning else { return }
            try? handle.write(contentsOf: data)
        }
    }

    func terminate() { if process.isRunning { process.terminate() } }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        let messages = Self.parse(&buffer)
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in messages.forEach { self?.onMessage?($0) } }
    }
}
