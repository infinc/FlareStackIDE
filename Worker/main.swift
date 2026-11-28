import Foundation

@objc(FlareStackPluginWorker) protocol PluginWorkerProtocol {
    func run(_ library: String, request: Data, reply: @escaping (Data?, String?) -> Void)
}

final class Worker: NSObject, PluginWorkerProtocol {
    private typealias Entry = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FlareStackIDE/Plugins").standardizedFileURL.path + "/"
    private var handles: [String: UnsafeMutableRawPointer] = [:]

    func run(_ library: String, request: Data, reply: @escaping (Data?, String?) -> Void) {
        let path = URL(fileURLWithPath: library).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(Self.root), path.hasSuffix("/plugin.dylib") else { return reply(nil, "読み込めない場所です") }
        guard let handle = handles[path] ?? dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return reply(nil, dlerror().map { String(cString: $0) } ?? "dlopen")
        }
        handles[path] = handle
        guard let symbol = dlsym(handle, "flarestack_worker") else { return reply(nil, "flarestack_worker がありません") }
        let text = String(decoding: request, as: UTF8.self)
        let result = text.withCString { unsafeBitCast(symbol, to: Entry.self)($0) }
        guard let result else { return reply(nil, "ワーカーが結果を返しませんでした") }
        defer { free(result) }
        reply(Data(String(cString: result).utf8), nil)
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    let worker = Worker()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PluginWorkerProtocol.self)
        connection.exportedObject = worker
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
