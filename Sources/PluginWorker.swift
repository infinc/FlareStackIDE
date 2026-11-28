import Foundation

@objc(FlareStackPluginWorker) protocol PluginWorkerProtocol {
    func run(_ library: String, request: Data, reply: @escaping (Data?, String?) -> Void)
}

enum PluginWorker {
    static let serviceName = "com.flarestackide.app.PluginHost"
    private static var connection: NSXPCConnection?

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func connect() -> NSXPCConnection {
        if let connection { return connection }
        let made = NSXPCConnection(serviceName: serviceName)
        made.remoteObjectInterface = NSXPCInterface(with: PluginWorkerProtocol.self)
        made.invalidationHandler = { DispatchQueue.main.async { connection = nil } }
        made.resume()
        connection = made
        return made
    }

    static func call(_ id: String, _ request: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let finish = { (result: Result<[String: Any], Error>) in DispatchQueue.main.async { completion(result) } }
        guard !PluginGuard.isDisabled(id), let info = PluginStore.installed(id), info.isNative else {
            return finish(.failure(failure("\(id) は使えません")))
        }
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return finish(.failure(failure("要求を JSON にできません"))) }
        let library = PluginStore.folder(id).appendingPathComponent(NativePlugins.binary).path
        var done = false
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                if (error as NSError).code == NSXPCConnectionInterrupted { PluginGuard.workerCrashed(info) }
                completion(.failure(failure("\(info.name) の処理が異常終了しました（\(appName) 本体は動き続けます）")))
            }
        } as? PluginWorkerProtocol
        guard let proxy else { return finish(.failure(failure("ワーカーに接続できません"))) }
        proxy.run(library, request: body) { data, message in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                if let message { return completion(.failure(failure(message))) }
                let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                completion(.success(value))
            }
        }
    }
}
