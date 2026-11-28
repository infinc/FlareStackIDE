import Foundation

enum Host {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias WorkerReply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias Lookup = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

    private static let lookup: Lookup? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "flarestack_host_symbol")
        .map { unsafeBitCast($0, to: Lookup.self) }

    static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let lookup, let pointer = name.withCString({ lookup($0) }) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static var version: Int32 {
        function("api_version", as: (@convention(c) () -> Int32).self)?() ?? 0
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { function("free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)?(pointer) }
        return String(cString: pointer)
    }

    static func toast(_ title: String, _ message: String? = nil) {
        guard let call = function("toast", as: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void).self) else { return }
        title.withCString { title in
            if let message { message.withCString { call(title, $0) } } else { call(title, nil) }
        }
    }

    @discardableResult
    static func registerCommand(_ id: String, _ title: String, context: UnsafeMutableRawPointer? = nil, _ callback: Callback) -> Bool {
        typealias Register = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Callback?, UnsafeMutableRawPointer?) -> Int32
        guard let call = function("register_command", as: Register.self) else { return false }
        return id.withCString { id in title.withCString { call(id, $0, callback, context) } } == 0
    }

    static var currentFile: String? { function("current_file", as: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self).flatMap { take($0()) } }

    static var currentText: String? { function("current_text", as: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self).flatMap { take($0()) } }

    static var selectedText: String? { function("selected_text", as: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self).flatMap { take($0()) } }

    static func setting(_ plugin: String, _ key: String) -> String? {
        typealias Get = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
        guard let call = function("setting", as: Get.self) else { return nil }
        return plugin.withCString { plugin in key.withCString { take(call(plugin, $0)) } }
    }

    static func workerCall(_ plugin: String, _ json: String, context: UnsafeMutableRawPointer?, _ reply: WorkerReply) {
        typealias Call = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, WorkerReply?, UnsafeMutableRawPointer?) -> Void
        guard let call = function("worker_call", as: Call.self) else { return }
        plugin.withCString { plugin in json.withCString { call(plugin, $0, reply, context) } }
    }
}

enum WorkerJSON {
    static func decode(_ pointer: UnsafePointer<CChar>) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any] ?? [:]
    }

    static func encode(_ value: [String: Any]) -> UnsafeMutablePointer<CChar>? {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return strdup(String(decoding: data, as: UTF8.self))
    }
}
