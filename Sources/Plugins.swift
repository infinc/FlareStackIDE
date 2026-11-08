import AppKit
import JavaScriptCore
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let pluginsChanged = Notification.Name("FlareStackIDE.pluginsChanged")
}

struct PluginInfo: Codable {
    let id: String
    let name: String
    let version: String
    let author: String
    let symbol: String
    let summary: String
    let fileExtensions: [String]
    var files: [String]?
    var settings: [PluginSetting]?
    var hashes: [String: String]?
    var apiVersion: Int?
    var requires: [String]?
    var permissions: [String]?
    var category: String?
    var loadOnOpen: Bool?

    var isNative: Bool { files?.contains(NativePlugins.binary) ?? (apiVersion != nil) }
}

enum PluginPermission {
    static let titles: [String: String] = [
        "network": "インターネットへの接続",
        "files": "ファイルの読み書き",
        "process": "外部コマンドの実行",
        "clipboard": "クリップボードの読み取り",
    ]

    static func title(_ key: String) -> String { titles[key] ?? key }

    static func list(_ info: PluginInfo) -> [String] { (info.permissions ?? []).map(title) }

    static func summary(_ info: PluginInfo) -> String {
        var parts = list(info)
        if info.isNative { parts.insert("Swift のコード（Mac 上で本体と同じ操作ができます）", at: 0) }
        return parts.isEmpty ? "特別な権限は使いません" : parts.joined(separator: "、")
    }

    private static func key(_ id: String) -> String { "Plugins.Granted.\(id)" }

    static func granted(_ id: String) -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: key(id)) { return Set(saved) }
        return Set(PluginStore.installed(id)?.permissions ?? [])
    }

    static func grant(_ info: PluginInfo) { UserDefaults.standard.set(info.permissions ?? [], forKey: key(info.id)) }

    static func revoke(_ id: String) { UserDefaults.standard.removeObject(forKey: key(id)) }

    static func added(_ info: PluginInfo) -> [String] {
        let have = PluginStore.isInstalled(info.id) ? granted(info.id) : []
        return (info.permissions ?? []).filter { !have.contains($0) }
    }

    static func confirm(_ info: PluginInfo, _ keys: [String]) -> Bool {
        let alert = NSAlert()
        let updating = PluginStore.isInstalled(info.id)
        alert.messageText = updating ? "\(info.name) が新しい権限を求めています" : "\(info.name) に次の権限を許可しますか？"
        alert.informativeText = keys.map { "・" + title($0) }.joined(separator: "\n")
            + (info.isNative ? "\n\nSwift で動くプラグインのため、Mac 上で本体と同じ操作ができます。" : "")
        alert.addButton(withTitle: updating ? "許可して更新" : "許可してインストール")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct PluginSetting: Codable {
    let key: String
    let title: String
    let type: String
    let defaultValue: String?
    var options: [String]?
    var min: Double?
    var max: Double?

    enum CodingKeys: String, CodingKey { case key, title, type, options, min, max, defaultValue = "default" }
}

enum FloatCorner: String {
    case topRight = "右上", bottomRight = "右下", topLeft = "左上", bottomLeft = "左下"

    var top: Bool { self == .topRight || self == .topLeft }
    var right: Bool { self == .topRight || self == .bottomRight }
}

protocol EditorExtension: AnyObject {
    var bar: NSView { get }
    var body: NSView { get }
    var floating: Bool { get }
    var corner: FloatCorner { get }
    func update(text: String)
    func applySettings()
}

enum PluginStore {
    private static let scheme = "flarestack-plugin"
    private static let defaultSource = "https://raw.githubusercontent.com/infinc/FlareStackIDE/main/plugins/"
    private(set) static var remote: [PluginInfo] = loadCache()
    private(set) static var loading = false
    private(set) static var catalogError: Error?
    private static var busy: Set<String> = []
    private static var detailsCache: [String: String] = [:]
    private static var highlighters: [String: Highlighter] = [:]
    private static var notified: [String: String] = [:]
    private static var preapproved: Set<String> = []
    private static var installedCache: [String: PluginInfo?] = [:]
    private static var installedIDsCache: [String]?
    private static var changePending = false
    private static let fileQueue = DispatchQueue(label: "\(appName).plugins.files", qos: .userInitiated, attributes: .concurrent)
    static let otherCategory = "その他"

    static var source: URL {
        var text = UserDefaults.standard.string(forKey: "Plugins.Source") ?? defaultSource
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text)!
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("Plugins")
    }

    private static var cacheURL: URL { directory.appendingPathComponent("index.json") }

    static func folder(_ id: String) -> URL { directory.appendingPathComponent(id) }

    private static func manifest(_ id: String) -> URL { folder(id).appendingPathComponent("plugin.json") }

    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && path.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidID(_ id: String) -> Bool { id.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil }

    private static func loadCache() -> [PluginInfo] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([PluginInfo].self, from: data)) ?? []
    }

    private static func invalidate() {
        installedCache = [:]
        installedIDsCache = nil
    }

    private static func changed() {
        invalidate()
        highlighters = [:]
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            changePending = false
            NotificationCenter.default.post(name: .pluginsChanged, object: nil)
        }
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func fetch(_ path: String, _ completion: @escaping (Result<Data, Error>) -> Void) {
        let url = source.appendingPathComponent(path)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let result: Result<Data, Error>
            if let data, error == nil, status == 200 {
                result = .success(data)
            } else {
                result = .failure(error ?? failure("取得できませんでした (\(status))\n\(url.absoluteString)"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func installBundled() {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent("bundled.stamp")
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
              let stamp = try? String(contentsOf: bundled.appendingPathComponent(".build-stamp"), encoding: .utf8),
              stamp != (try? String(contentsOf: marker, encoding: .utf8)) else { return }
        let ids = (try? fm.contentsOfDirectory(atPath: bundled.path))?.filter(isValidID) ?? []
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var rejected: [String] = []
        for id in ids {
            let source = bundled.appendingPathComponent(id)
            guard let data = try? Data(contentsOf: source.appendingPathComponent("plugin.json")),
                  let info = try? JSONDecoder().decode(PluginInfo.self, from: data) else { continue }
            if let reason = PluginTrust.verifyInstalled(source, info: info, files: info.files ?? ["main.js"]) {
                rejected.append(reason)
                continue
            }
            try? fm.removeItem(at: folder(id))
            try? fm.copyItem(at: source, to: folder(id))
        }
        try? stamp.write(to: marker, atomically: true, encoding: .utf8)
        invalidate()
        guard !rejected.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Toasts.post("同梱のプラグイン \(rejected.count) 個をインストールしませんでした", message: rejected.joined(separator: "\n"))
        }
    }

    static func compatibility(_ info: PluginInfo) -> String? {
        let native = info.files?.contains(NativePlugins.binary) ?? (info.apiVersion != nil)
        guard native else { return nil }
        guard let api = info.apiVersion, api <= NativePlugins.apiVersion else {
            return info.apiVersion == nil ? "この版の \(appName) には対応していません（プラグインの更新待ち）" : "\(appName) を最新版にアップデートしてください"
        }
        return api < NativePlugins.apiVersion ? "この版の \(appName) には対応していません（プラグインの更新待ち）" : nil
    }

    static func dependents(of id: String) -> [PluginInfo] {
        installedIDs.compactMap(installed).filter { $0.requires?.contains(id) == true }
    }

    static func confirmUninstall(_ id: String) -> Bool {
        let users = dependents(of: id)
        guard !users.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "\(info(id)?.name ?? id) を削除しますか？"
        alert.informativeText = "\(users.map(\.name).joined(separator: "、")) が動かなくなります"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func requirementNames(_ info: PluginInfo) -> String? {
        guard let requires = info.requires, !requires.isEmpty else { return nil }
        return "必要: " + requires.map { PluginStore.info($0)?.name ?? $0 }.joined(separator: "、")
    }

    static func installed(_ id: String) -> PluginInfo? {
        if let cached = installedCache[id] { return cached }
        let found = readInstalled(id)
        installedCache[id] = .some(found)
        return found
    }

    private static func readInstalled(_ id: String) -> PluginInfo? {
        guard let data = try? Data(contentsOf: manifest(id)),
              let info = try? JSONDecoder().decode(PluginInfo.self, from: data),
              (info.files ?? ["main.js"]).allSatisfy({ FileManager.default.fileExists(atPath: folder(id).appendingPathComponent($0).path) })
        else { return nil }
        return info
    }

    static func isInstalled(_ id: String) -> Bool { installed(id) != nil }

    static func isBusy(_ id: String) -> Bool { busy.contains(id) }

    static var installedIDs: [String] {
        if let installedIDsCache { return installedIDsCache }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ids = names.filter { isValidID($0) && isInstalled($0) }.sorted()
        installedIDsCache = ids
        return ids
    }

    static var catalog: [PluginInfo] {
        let ids = Set(remote.map(\.id))
        return remote + installedIDs.filter { !ids.contains($0) }.compactMap(installed)
    }

    static func info(_ id: String) -> PluginInfo? { installed(id) ?? remote.first { $0.id == id } }

    static func hasUpdate(_ id: String) -> Bool {
        guard let local = installed(id), let latest = remote.first(where: { $0.id == id }) else { return false }
        return isNewer(latest.version, than: local.version) && compatibility(latest) == nil
    }

    static func refreshCatalog() {
        guard !loading else { return }
        loading = true
        changed()
        fetch("index.json") { result in
            guard case .success(let data) = result else {
                loading = false
                if case .failure(let error) = result { catalogError = error }
                return changed()
            }
            fetch("index.sig") { signature in
                loading = false
                guard PluginTrust.isSigned(data, signature: try? signature.get()) || PluginTrust.allowUnsigned else {
                    catalogError = failure("プラグイン一覧の署名を確認できませんでした")
                    return changed()
                }
                if let list = try? JSONDecoder().decode([PluginInfo].self, from: data) {
                    remote = list.filter { isValidID($0.id) }
                    catalogError = nil
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                    DispatchQueue.main.async(execute: notifyUpdates)
                } else {
                    catalogError = failure("プラグイン一覧の形式が正しくありません")
                }
                changed()
            }
        }
    }

    static func latestVersion(_ id: String) -> String? { remote.first { $0.id == id }?.version }

    static func update(_ id: String) {
        let name = info(id)?.name ?? id
        install(id) { error in
            if let error {
                Toasts.post("\(name) の更新に失敗しました", message: error.localizedDescription)
            } else {
                Toasts.post("\(name) を v\(installed(id)?.version ?? "") に更新しました")
            }
        }
    }

    static var updatableIDs: [String] { installedIDs.filter { hasUpdate($0) && !isBusy($0) } }

    static func updateAll(_ ids: [String]? = nil) {
        let targets = (ids ?? updatableIDs).filter { hasUpdate($0) && !isBusy($0) }
        guard !targets.isEmpty else { return }
        if targets.count == 1 { return update(targets[0]) }
        let group = DispatchGroup()
        var done: [String] = []
        var failed: [(String, Error)] = []
        for id in targets {
            group.enter()
            install(id) { error in
                let name = info(id)?.name ?? id
                if let error { failed.append((name, error)) } else { done.append("\(name) v\(installed(id)?.version ?? "")") }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !done.isEmpty { Toasts.post("\(done.count) 個のプラグインを更新しました", message: done.sorted().joined(separator: "\n")) }
            if !failed.isEmpty {
                Toasts.post("\(failed.count) 個のプラグインの更新に失敗しました",
                            message: failed.map { "\($0.0): \($0.1.localizedDescription)" }.joined(separator: "\n"))
            }
        }
    }

    private static var updateTimer: Timer?
    private static let updateInterval: TimeInterval = 6 * 60 * 60

    static func startPeriodicCheck() {
        guard updateTimer == nil else { return }
        let timer = Timer(timeInterval: updateInterval, repeats: true) { _ in refreshCatalog() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private static func notifyUpdates() {
        var automatic: [String] = []
        var manual: [String] = []
        for id in updatableIDs {
            let grows = remote.first { $0.id == id }.map { !PluginPermission.added($0).isEmpty } ?? false
            if Settings.pluginAutoUpdate && !grows {
                automatic.append(id)
            } else if let latest = latestVersion(id), notified[id] != latest {
                notified[id] = latest
                manual.append(id)
            }
        }
        updateAll(automatic)
        guard !manual.isEmpty else { return }
        let lines = manual.compactMap { id in installed(id).map { "\($0.name)　v\($0.version) → v\(latestVersion(id) ?? "")" } }
        if manual.count == 1, let local = installed(manual[0]) {
            Toasts.post("\(local.name) のアップデートがあります", message: "v\(local.version) → v\(latestVersion(manual[0]) ?? "")",
                        actions: [("アップデート", { update(manual[0]) })])
        } else {
            Toasts.post("\(manual.count) 個のプラグインにアップデートがあります", message: lines.joined(separator: "\n"),
                        actions: [("すべてアップデート", { updateAll(manual) })])
        }
    }

    static func perform(_ id: String, completion: @escaping (Error?) -> Void) {
        if isInstalled(id) && !hasUpdate(id) {
            guard confirmUninstall(id) else { return completion(nil) }
            do { try uninstall(id); completion(nil) } catch { completion(error) }
        } else {
            install(id, completion: completion)
        }
    }

    private static func installChain(_ ids: [String], visiting: Set<String>, completion: @escaping (Error?) -> Void) {
        guard let first = ids.first else { return completion(nil) }
        install(first, visiting: visiting) { error in
            if let error { return completion(error) }
            installChain(Array(ids.dropFirst()), visiting: visiting, completion: completion)
        }
    }

    static func install(_ id: String, completion: @escaping (Error?) -> Void) { install(id, visiting: [], completion: completion) }

    private static func install(_ id: String, visiting: Set<String>, completion: @escaping (Error?) -> Void) {
        guard !visiting.contains(id) else { return completion(failure("プラグインの依存関係が循環しています（\(id)）")) }
        guard isValidID(id), !busy.contains(id) else { return visiting.isEmpty ? () : completion(nil) }
        busy.insert(id)
        changed()
        let finish: (Error?) -> Void = { error in
            busy.remove(id)
            detailsCache[id] = nil
            changed()
            completion(error)
        }
        fetch("\(id)/plugin.json") { result in
            let data: Data
            switch result {
            case .failure(let error): return finish(error)
            case .success(let d): data = d
            }
            guard let info = try? JSONDecoder().decode(PluginInfo.self, from: data), info.id == id else {
                return finish(failure("plugin.json の形式が正しくありません"))
            }
            let files = info.files ?? ["main.js"]
            guard files.allSatisfy(isSafe), !files.contains("plugin.json"), !files.contains(PluginTrust.signatureFile) else {
                return finish(failure("plugin.json の files に不正なパスがあります"))
            }
            if let reason = compatibility(info) { return finish(failure("\(info.name): \(reason)")) }
            fetch("\(id)/\(PluginTrust.signatureFile)") { signatureResult in
                let signature = try? signatureResult.get()
                do { try PluginTrust.checkManifest(data, signature: signature, name: info.name) } catch { return finish(error) }
                let asked = PluginPermission.added(info)
                if !asked.isEmpty, preapproved.remove(id) == nil, !PluginPermission.confirm(info, asked) {
                    return finish(failure("\(info.name) の権限が許可されなかったため、インストールしませんでした"))
                }
                let missing = (info.requires ?? []).filter { !isInstalled($0) }
                installChain(missing, visiting: visiting.union([id])) { error in
                    if let error {
                        return finish(failure("\(info.name) に必要なプラグインをインストールできませんでした\n\(error.localizedDescription)"))
                    }
                    download(info, files: files, manifest: data, signature: signature, finish: finish)
                }
            }
        }
    }

    private static func download(_ info: PluginInfo, files: [String], manifest data: Data, signature: Data?, finish: @escaping (Error?) -> Void) {
        let id = info.id
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("\(appName)-plugin-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try data.write(to: staging.appendingPathComponent("plugin.json"))
            try signature?.write(to: staging.appendingPathComponent(PluginTrust.signatureFile))
        } catch {
            return finish(error)
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "\(appName).plugins.install.\(id)", qos: .userInitiated)
        var firstError: Error?
        for file in files {
            group.enter()
            fetch("\(id)/\(file)") { result in
                queue.async {
                    defer { group.leave() }
                    do {
                        let target = staging.appendingPathComponent(file)
                        let content = try result.get()
                        try PluginTrust.checkFile(file, data: content, hashes: info.hashes, name: info.name)
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try content.write(to: target)
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
            }
        }
        group.notify(queue: queue) {
            defer { try? fm.removeItem(at: staging) }
            var outcome = firstError
            if outcome == nil {
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: folder(id).path) { try fm.removeItem(at: folder(id)) }
                    try fm.moveItem(at: staging, to: folder(id))
                } catch {
                    outcome = error
                }
            }
            DispatchQueue.main.async {
                invalidate()
                if outcome == nil { PluginPermission.grant(info) }
                finish(outcome)
            }
        }
    }

    static func uninstall(_ id: String) throws {
        guard isValidID(id) else { return }
        try FileManager.default.removeItem(at: folder(id))
        detailsCache[id] = nil
        PluginPermission.revoke(id)
        changed()
    }

    static func uninstall(_ ids: [String], completion: @escaping (_ failed: [String]) -> Void) {
        let targets = ids.filter { isValidID($0) && !busy.contains($0) }
        guard !targets.isEmpty else { return completion([]) }
        busy.formUnion(targets)
        changed()
        let folders = targets.map(folder)
        let lock = NSLock()
        var failed: Set<String> = []
        fileQueue.async {
            DispatchQueue.concurrentPerform(iterations: folders.count) { index in
                do { try FileManager.default.removeItem(at: folders[index]) } catch {
                    lock.lock()
                    failed.insert(targets[index])
                    lock.unlock()
                }
            }
            DispatchQueue.main.async {
                busy.subtract(targets)
                for id in targets where !failed.contains(id) {
                    detailsCache[id] = nil
                    PluginPermission.revoke(id)
                }
                changed()
                completion(targets.filter(failed.contains))
            }
        }
    }

    static func preapprove(_ ids: [String]) { preapproved.formUnion(ids) }

    static func category(_ id: String) -> String {
        installed(id)?.category ?? remote.first { $0.id == id }?.category ?? otherCategory
    }

    static var categories: [String] {
        var seen: [String] = []
        for info in catalog where !seen.contains(category(info.id)) { seen.append(category(info.id)) }
        return seen.filter { $0 != otherCategory } + (seen.contains(otherCategory) ? [otherCategory] : [])
    }

    static func details(_ id: String, completion: @escaping (String) -> Void) {
        if let cached = detailsCache[id] { return completion(cached) }
        if isInstalled(id), let text = try? String(contentsOf: folder(id).appendingPathComponent("README.md"), encoding: .utf8) {
            detailsCache[id] = text
            return completion(text)
        }
        fetch("\(id)/README.md") { result in
            guard case .success(let data) = result, let text = String(data: data, encoding: .utf8) else {
                return completion(info(id)?.summary ?? "")
            }
            detailsCache[id] = text
            completion(text)
        }
    }

    static func search(_ query: String, category: String? = nil) -> [PluginInfo] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return catalog.filter { info in
            guard category == nil || self.category(info.id) == category else { return false }
            let text = [info.id, info.name, info.summary, info.author, self.category(info.id), info.fileExtensions.joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    static func makeHighlighter(for url: URL) -> Highlighter? {
        let keys = [url.pathExtension.lowercased(), url.lastPathComponent.lowercased()].filter { !$0.isEmpty }
        for id in installedIDs {
            guard let info = installed(id), info.fileExtensions.contains(where: keys.contains) else { continue }
            if let cached = highlighters[id] { return cached }
            if let made = Highlighter(folder: folder(id), name: info.name) {
                highlighters[id] = made
                return made
            }
        }
        return nil
    }

    static func makeExtension(for url: URL, code: NSView) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        return installedIDs.lazy
            .compactMap(installed)
            .filter { $0.fileExtensions.contains(ext) }
            .compactMap { ScriptExtension(info: $0, folder: folder($0.id), file: url, code: code) }
            .first
    }

    static func setting(_ id: String, _ key: String) -> String? {
        if let saved = Settings.pluginValue(id, key), !saved.isEmpty { return saved }
        return installed(id)?.settings?.first { $0.key == key }?.defaultValue
    }

    static func color(_ id: String, _ key: String) -> NSColor? { setting(id, key).flatMap { NSColor(hex: $0) } }

    static func pageURL(_ id: String) -> URL { URL(string: "\(scheme)://\(id)")! }

    static func id(from url: URL) -> String? { url.scheme == scheme ? url.host : nil }

    static func symbol(_ name: String, size: CGFloat) -> NSImage {
        (NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "puzzlepiece", accessibilityDescription: nil)!)
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))!
    }

    static func iconView(_ name: String, box: CGFloat = 28, size: CGFloat = 15) -> NSImageView {
        let view = NSImageView(image: symbol(name, size: size))
        view.contentTintColor = .controlAccentColor
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: box), view.heightAnchor.constraint(equalToConstant: box)])
        return view
    }

    static func actionTitle(_ id: String, long: Bool = false) -> String {
        if isBusy(id) { return "取得中…" }
        if hasUpdate(id) { return "更新" }
        if isInstalled(id) { return long ? "アンインストール" : "削除" }
        if let info = remote.first(where: { $0.id == id }), compatibility(info) != nil { return "非対応" }
        return "インストール"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class PluginRow: NSView {
    var onOpen: (() -> Void)?
    var onAction: (() -> Void)?

    init(info: PluginInfo) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = PluginStore.iconView(info.symbol)
        let name = NSTextField(labelWithString: info.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let version = NSTextField(labelWithString: "v\(PluginStore.installed(info.id)?.version ?? info.version)")
        version.font = .systemFont(ofSize: 10)
        version.textColor = .tertiaryLabelColor
        var titleViews: [NSView] = [name, version]
        let current = PluginStore.installed(info.id) ?? info
        if let note = PluginStore.compatibility(current) ?? PluginStore.requirementNames(current) {
            let label = NSTextField(labelWithString: note)
            label.font = .systemFont(ofSize: 10)
            label.textColor = PluginStore.compatibility(current) == nil ? .tertiaryLabelColor : .systemOrange
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            titleViews.append(label)
        }
        let title = NSStackView(views: titleViews)
        title.spacing = 4
        let summary = NSTextField(labelWithString: info.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 1
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [title, summary])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let action = PluginStore.actionTitle(info.id)
        let button = NSButton(title: action, target: self, action: #selector(actionClicked))
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = !PluginStore.isBusy(info.id) && action != "非対応"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, texts, spacer, button])
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    @objc private func actionClicked() { onAction?() }
}

final class PluginList: NSView {
    var onOpen: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    private let search = NSSearchField()
    private let categoryPopup = NSPopUpButton()
    private let list = NSStackView()
    private static let categoryKey = "Plugins.Category"

    init() {
        super.init(frame: .zero)
        search.placeholderString = "プラグインを検索"
        categoryPopup.controlSize = .small
        categoryPopup.font = .systemFont(ofSize: 11)
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged)
        categoryPopup.translatesAutoresizingMaskIntoConstraints = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(reload)
        search.translatesAutoresizingMaskIntoConstraints = false
        let refresh = NSButton(image: PluginStore.symbol("arrow.clockwise", size: 12), target: self, action: #selector(refreshClicked))
        refresh.isBordered = false
        refresh.toolTip = "プラグイン一覧を再取得"
        refresh.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)
        addSubview(refresh)
        addSubview(categoryPopup)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            refresh.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            categoryPopup.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            categoryPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            categoryPopup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: categoryPopup.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        reload()
        PluginStore.refreshCatalog()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let wrap = NSStackView(views: [label])
        wrap.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 2, right: 12)
        return wrap
    }

    @objc private func refreshClicked() { PluginStore.refreshCatalog() }

    @objc private func categoryChanged() {
        let index = categoryPopup.indexOfSelectedItem
        UserDefaults.standard.set(index > 0 ? PluginStore.categories[safe: index - 1] : nil, forKey: Self.categoryKey)
        reload()
    }

    private var selectedCategory: String? {
        guard let saved = UserDefaults.standard.string(forKey: Self.categoryKey), PluginStore.categories.contains(saved) else { return nil }
        return saved
    }

    private func fillCategories() {
        let categories = PluginStore.categories
        categoryPopup.removeAllItems()
        categoryPopup.addItem(withTitle: "すべてのカテゴリ")
        categoryPopup.addItems(withTitles: categories)
        categoryPopup.selectItem(at: selectedCategory.flatMap { categories.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    private static func confirm(_ title: String, _ message: String, _ button: String, in window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func installAll() {
        let targets = PluginStore.catalog.filter { !PluginStore.isInstalled($0.id) && !PluginStore.isBusy($0.id) && PluginStore.compatibility($0) == nil }
        guard !targets.isEmpty else {
            Toasts.post("インストールできるプラグインはありません", in: window)
            return
        }
        let asked = Set(targets.flatMap { $0.permissions ?? [] })
        let note = asked.isEmpty ? "" : "\n\n次の権限を許可します:\n" + asked.sorted().map { "・" + PluginPermission.title($0) }.joined(separator: "\n")
        guard Self.confirm("全てのプラグインをインストールしますか？", "\(targets.count) 個のプラグインをインストールします" + note, "全てインストール", in: window) else { return }
        PluginStore.preapprove(targets.map(\.id))
        let group = DispatchGroup()
        var failed: [String] = []
        for info in targets {
            group.enter()
            PluginStore.install(info.id) { error in
                if error != nil { failed.append(info.name) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if failed.isEmpty {
                Toasts.post("\(targets.count) 個のプラグインをインストールしました", in: self?.window)
            } else {
                Toasts.post("\(failed.count) 個のプラグインのインストールに失敗しました", message: failed.joined(separator: "、"), in: self?.window)
            }
        }
    }

    @objc func uninstallAll() {
        let targets = PluginStore.installedIDs.filter { !PluginStore.isBusy($0) }
        guard !targets.isEmpty else {
            Toasts.post("インストール済みのプラグインはありません", in: window)
            return
        }
        guard Self.confirm("全てのプラグインをアンインストールしますか？", "\(targets.count) 個のプラグインをアンインストールします", "全てアンインストール", in: window) else { return }
        let names = Dictionary(uniqueKeysWithValues: targets.map { ($0, PluginStore.info($0)?.name ?? $0) })
        PluginStore.uninstall(targets) { [weak self] failed in
            if failed.isEmpty {
                Toasts.post("\(targets.count) 個のプラグインをアンインストールしました", in: self?.window)
            } else {
                Toasts.post("\(failed.count) 個のプラグインのアンインストールに失敗しました",
                            message: failed.map { names[$0] ?? $0 }.joined(separator: "、"), in: self?.window)
            }
        }
    }

    @objc func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if PluginStore.loading { list.addArrangedSubview(header("プラグイン一覧を取得中…")) }
        if let error = PluginStore.catalogError {
            list.addArrangedSubview(header("プラグイン一覧を取得できませんでした: \(error.localizedDescription)"))
        }
        fillCategories()
        let found = PluginStore.search(search.stringValue, category: selectedCategory)
        if found.isEmpty {
            if !PluginStore.loading { list.addArrangedSubview(header("一致するプラグインはありません")) }
            return
        }
        let installed = found.filter { PluginStore.isInstalled($0.id) }
        let available = found.filter { !PluginStore.isInstalled($0.id) }
        var sections = [("インストール済み", installed)]
        for category in PluginStore.categories {
            let plugins = available.filter { PluginStore.category($0.id) == category }
            sections.append((selectedCategory == nil ? "利用可能 — \(category)" : "利用可能", plugins))
        }
        for (title, plugins) in sections where !plugins.isEmpty {
            list.addArrangedSubview(header(title))
            for info in plugins {
                let row = PluginRow(info: info)
                row.onOpen = { [weak self] in self?.onOpen?(info.id) }
                row.onAction = { [weak self] in
                    let installing = !PluginStore.isInstalled(info.id) || PluginStore.hasUpdate(info.id)
                    let updating = PluginStore.hasUpdate(info.id)
                    PluginStore.perform(info.id) { error in
                        if let error {
                            self?.onError?(error)
                            return
                        }
                        guard installing else { return }
                        let version = PluginStore.installed(info.id)?.version ?? info.version
                        Toasts.post(updating ? "\(info.name) を v\(version) に更新しました" : "\(info.name) をインストールしました", in: self?.window)
                    }
                }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
    }
}

final class PluginPage: NSView {
    var onError: ((Error) -> Void)?
    private(set) var pluginID: String?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let access = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let remove = NSButton(title: "アンインストール", target: nil, action: nil)
    private let text = NSTextView()

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        name.font = .systemFont(ofSize: 22, weight: .bold)
        meta.textColor = .secondaryLabelColor
        for b in [button, remove] {
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.target = self
        }
        button.action = #selector(actionClicked)
        remove.action = #selector(removeClicked)
        let buttons = NSStackView(views: [button, remove])
        buttons.spacing = 8
        access.font = .systemFont(ofSize: 11)
        access.textColor = .secondaryLabelColor
        access.preferredMaxLayoutWidth = 460
        let titles = NSStackView(views: [name, meta, access, buttons])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 6
        let header = NSStackView(views: [icon, titles])
        header.alignment = .top
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [header, line, scroll].forEach(addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ id: String) {
        pluginID = id
        refresh()
    }

    func refresh() {
        guard let id = pluginID, let info = PluginStore.info(id) else { return }
        let installed = PluginStore.isInstalled(id)
        let state = PluginStore.hasUpdate(id) ? "更新あり" : installed ? "インストール済み" : "未インストール"
        icon.image = PluginStore.symbol(info.symbol, size: 40)
        name.stringValue = info.name
        let notes = [PluginStore.requirementNames(info), PluginStore.compatibility(info)].compactMap { $0 }
        meta.stringValue = (["v\(info.version)", info.author, PluginStore.category(id), state] + notes).joined(separator: "　·　")
        access.stringValue = "権限: " + PluginPermission.summary(info)
        let action = PluginStore.actionTitle(id, long: true)
        button.title = action
        button.isEnabled = !PluginStore.isBusy(id) && action != "非対応"
        remove.isHidden = !PluginStore.hasUpdate(id)
        remove.isEnabled = button.isEnabled
        PluginStore.details(id) { [weak self] markdown in
            guard let self, self.pluginID == id else { return }
            self.text.textStorage?.setAttributedString(renderMarkdown(markdown))
        }
    }

    @objc private func actionClicked() {
        guard let id = pluginID else { return }
        PluginStore.perform(id) { [weak self] error in if let error { self?.onError?(error) } }
    }

    @objc private func removeClicked() {
        guard let id = pluginID, PluginStore.confirmUninstall(id) else { return }
        do { try PluginStore.uninstall(id) } catch { onError?(error) }
    }
}

final class Highlighter {
    private let context = JSContext()!
    private let function: JSValue
    private let paletteFunction: JSValue?
    private let name: String
    private var palette: [NSColor] = []
    private var paletteDark: Bool?
    private var failures = 0
    private var reported = false
    static let limit = 400_000
    static let windowThreshold = 150_000
    private static let windowMargin = 20_000
    private static let maxFailures = 3

    init?(folder: URL, name: String) {
        let file = folder.appendingPathComponent("main.js")
        guard let script = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        self.name = name
        context.evaluateScript(script, withSourceURL: file)
        guard context.exception == nil, let highlight = context.objectForKeyedSubscript("highlight"), highlight.isObject else {
            PluginFault.report(name, context.exception?.toString() ?? "highlight が見つかりません")
            return nil
        }
        function = highlight
        paletteFunction = context.objectForKeyedSubscript("palette").flatMap { $0.isObject ? $0 : nil }
    }

    private func colors(dark: Bool) -> [NSColor] {
        if paletteDark != dark {
            paletteDark = dark
            let hexes = paletteFunction?.call(withArguments: [dark])?.toArray() as? [String] ?? []
            palette = hexes.map { NSColor(hex: $0) ?? .textColor }
        }
        return palette
    }

    static func needsWindow(_ length: Int) -> Bool { length > windowThreshold }

    func spans(_ text: String, file: URL, visible: NSRange? = nil) -> [(range: NSRange, color: NSColor)] {
        guard failures < Self.maxFailures else { return [] }
        let whole = text as NSString
        let length = whole.length
        var source = text
        var offset = 0
        if Self.needsWindow(length) {
            guard let visible else { return [] }
            let start = max(visible.location - Self.windowMargin, 0)
            let end = min(NSMaxRange(visible) + Self.windowMargin, length)
            let range = whole.lineRange(for: NSRange(location: start, length: max(end - start, 0)))
            source = whole.substring(with: range)
            offset = range.location
        }
        var palette = colors(dark: Settings.editorIsDark)
        if let custom = Settings.tokenPalette {
            for (i, color) in custom.enumerated() where palette.indices.contains(i) { if let color { palette[i] = color } }
        }
        context.exception = nil
        let result = function.call(withArguments: [source, file.pathExtension.lowercased(), file.lastPathComponent.lowercased()])
        if let exception = context.exception {
            failures += 1
            if !reported {
                reported = true
                PluginFault.report(name, exception.toString(), stopped: failures >= Self.maxFailures)
            } else if failures >= Self.maxFailures {
                PluginFault.report(name, exception.toString(), stopped: true)
            }
            return []
        }
        failures = 0
        guard let numbers = result?.toArray() as? [NSNumber] else { return [] }
        var spans: [(range: NSRange, color: NSColor)] = []
        spans.reserveCapacity(numbers.count / 3)
        var i = 0
        while i + 2 < numbers.count {
            let start = numbers[i].intValue + offset, count = numbers[i + 1].intValue, kind = numbers[i + 2].intValue
            i += 3
            guard start >= offset, count > 0, start + count <= length, palette.indices.contains(kind) else { continue }
            spans.append((NSRange(location: start, length: count), palette[kind]))
        }
        return spans
    }
}

enum PluginFault {
    private static var shown: Set<String> = []

    static func report(_ name: String, _ message: String, stopped: Bool = false) {
        let key = name + (stopped ? ".stopped" : "")
        guard !shown.contains(key) else { return }
        shown.insert(key)
        DispatchQueue.main.async {
            Toasts.post(stopped ? "\(name) を一時的に止めました" : "\(name) でエラーが起きました",
                        message: (stopped ? "エラーが続いたため、再起動するまで使いません。\n" : "") + message)
        }
    }
}

final class PluginManagerView: NSView {
    private let auto = NSButton(checkboxWithTitle: "プラグインを自動でアップデートする", target: nil, action: nil)
    private let unsigned = NSButton(checkboxWithTitle: "署名のないプラグインを許可（開発用。改ざんを検出できません）", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let updateAll = NSButton(title: "すべてアップデート", target: nil, action: nil)
    private let list = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        auto.target = self
        auto.action = #selector(autoChanged)
        unsigned.target = self
        unsigned.action = #selector(unsignedChanged)
        unsigned.font = .systemFont(ofSize: 11)
        unsigned.translatesAutoresizingMaskIntoConstraints = false
        let check = NSButton(title: "更新を確認", target: self, action: #selector(checkClicked))
        check.bezelStyle = .rounded
        updateAll.bezelStyle = .rounded
        updateAll.target = self
        updateAll.action = #selector(updateAllClicked)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let top = NSStackView(views: [auto, NSView(), status, updateAll, check])
        top.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        addSubview(unsigned)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 520),
            heightAnchor.constraint(equalToConstant: 380),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            unsigned.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            unsigned.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: unsigned.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .pluginsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .settingsChanged, object: nil)
        reload()
        PluginStore.refreshCatalog()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func row(_ info: PluginInfo) -> NSView {
        let icon = PluginStore.iconView(info.symbol, box: 32, size: 18)
        let name = NSTextField(labelWithString: info.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        var detail = "v\(info.version)　·　\(info.author)"
        if PluginStore.hasUpdate(info.id), let latest = PluginStore.latestVersion(info.id) { detail += "　·　v\(latest) があります" }
        let stopped = PluginGuard.isDisabled(info.id)
        if stopped { detail += "　·　続けて終了したため停止中" }
        let meta = NSTextField(labelWithString: detail)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = PluginStore.hasUpdate(info.id) || stopped ? .systemOrange : .secondaryLabelColor
        meta.toolTip = "権限: " + PluginPermission.summary(info)
        let texts = NSStackView(views: [name, meta])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, texts, NSView()]
        let busy = PluginStore.isBusy(info.id)
        if PluginStore.hasUpdate(info.id) || busy {
            let update = PluginActionButton(title: busy ? "取得中…" : "アップデート") { PluginStore.update(info.id) }
            update.isEnabled = !busy
            update.keyEquivalent = ""
            views.append(update)
        }
        if stopped { views.append(PluginActionButton(title: "有効にする") { PluginGuard.enable(info.id) }) }
        let settings = PluginActionButton(title: "設定") { [weak self] in
            Popups.show("plugin-settings-\(info.id)", title: "\(info.name) の設定", over: self?.window) { PluginSettingsView(id: info.id) }
        }
        views.append(settings)
        let remove = PluginActionButton(title: "削除") { [weak self] in
            guard PluginStore.confirmUninstall(info.id) else { return }
            do { try PluginStore.uninstall(info.id) } catch { if let window = self?.window { NSAlert(error: error).beginSheetModal(for: window) } }
        }
        remove.isEnabled = !busy
        views.append(remove)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return stack
    }

    @objc private func reload() {
        auto.state = Settings.pluginAutoUpdate ? .on : .off
        unsigned.state = PluginTrust.allowUnsigned ? .on : .off
        status.stringValue = PluginStore.loading ? "確認中…" : PluginStore.catalogError != nil ? "確認できませんでした" : ""
        updateAll.isHidden = PluginStore.updatableIDs.isEmpty
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let installed = PluginStore.installedIDs.compactMap(PluginStore.installed)
        if installed.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "インストール済みのプラグインはありません。左のプラグインフィードから追加できます。")
            empty.textColor = .secondaryLabelColor
            let wrap = NSStackView(views: [empty])
            wrap.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            list.addArrangedSubview(wrap)
            return
        }
        for info in installed {
            let view = row(info)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            let line = NSBox()
            line.boxType = .separator
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func autoChanged() { Settings.pluginAutoUpdate = auto.state == .on }

    @objc private func unsignedChanged() {
        PluginTrust.allowUnsigned = unsigned.state == .on
        PluginStore.refreshCatalog()
    }

    @objc private func checkClicked() { PluginStore.refreshCatalog() }

    @objc private func updateAllClicked() { PluginStore.updateAll() }
}

private final class PluginActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func clicked() { handler?() }
}

final class ScriptExtension: NSObject, EditorExtension, WKNavigationDelegate {
    private enum Mode: Int { case code, split, preview }

    let bar = NSView()
    private(set) var floating = false
    private(set) var corner = FloatCorner.bottomRight
    private var minimize = false
    private var hovering = false
    private let images: [NSImage]
    private let single: NSSegmentedControl
    private var barWidth: NSLayoutConstraint!
    private let id: String
    private let barLine = NSBox()
    private let barTitle: NSTextField
    private let modeKey: String
    private let base: URL
    private let context = JSContext()!
    private let renderer: JSValue
    private let split = NSSplitView()
    private let code: NSView
    private let preview: WKWebView
    private let modes: NSSegmentedControl
    private var pending: DispatchWorkItem?
    private var latest = ""
    private var mode: Mode
    private var ready = false
    private var queued: String?

    var body: NSView { split }

    init?(info: PluginInfo, folder: URL, file: URL, code: NSView) {
        guard let script = try? String(contentsOf: folder.appendingPathComponent("main.js"), encoding: .utf8) else { return nil }
        context.evaluateScript(script, withSourceURL: folder.appendingPathComponent("main.js"))
        guard context.exception == nil, let render = context.objectForKeyedSubscript("render"), render.isObject else { return nil }
        renderer = render
        base = LocalFileScheme.url(for: file.deletingLastPathComponent())
        self.code = code
        id = info.id
        barTitle = NSTextField(labelWithString: info.name)
        modeKey = "Plugin.\(info.id).Mode"
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: modeKey)) ?? .code

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(LocalFileScheme(), forURLScheme: LocalFileScheme.scheme)
        preview = WKWebView(frame: .zero, configuration: config)

        images = ["doc.plaintext", "rectangle.split.2x1", "eye"].map { PluginStore.symbol($0, size: 12) }
        modes = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        single = NSSegmentedControl(images: [images[0]], trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        single.controlSize = .small
        single.setWidth(28, forSegment: 0)
        single.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        single.selectedSegment = 0
        single.isHidden = true
        single.translatesAutoresizingMaskIntoConstraints = false
        modes.controlSize = .small
        for (i, label) in ["コード", "コード＋プレビュー", "プレビュー"].enumerated() {
            modes.setToolTip(label, forSegment: i)
            modes.setWidth(28, forSegment: i)
            modes.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.translatesAutoresizingMaskIntoConstraints = false

        let title = barTitle
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        let line = barLine
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        [modes, single, title, line].forEach(bar.addSubview)
        barWidth = bar.widthAnchor.constraint(equalToConstant: 100)
        bar.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NSLayoutConstraint.activate([
            single.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            single.centerYAnchor.constraint(equalTo: modes.centerYAnchor),
            modes.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            modes.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: modes.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        preview.navigationDelegate = self
        code.removeFromSuperview()
        code.translatesAutoresizingMaskIntoConstraints = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(code)
        split.addArrangedSubview(preview)
        applySettings()
        apply(mode)
    }

    func update(text: String) {
        latest = text
        pending?.cancel()
        guard mode != .code else { return }
        let work = DispatchWorkItem { [weak self] in self?.render() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func applySettings() {
        preview.underPageBackgroundColor = Settings.background
        floating = PluginStore.setting(id, "barTransparent") == "true"
        minimize = PluginStore.setting(id, "barMinimize") == "true"
        corner = PluginStore.setting(id, "barPosition").flatMap(FloatCorner.init) ?? .bottomRight
        barWidth.isActive = floating
        updateCollapsed()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = floating ? 7 : 0
        bar.layer?.backgroundColor = floating ? nil : PluginStore.color(id, "barColor")?.cgColor
        bar.appearance = floating ? nil : PluginStore.color(id, "barColor").map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua)! }
        barLine.isHidden = floating
        barTitle.isHidden = floating
        render()
    }

    @objc func mouseEntered(with event: NSEvent) {
        hovering = true
        updateCollapsed()
    }

    @objc func mouseExited(with event: NSEvent) {
        hovering = false
        updateCollapsed()
    }

    private func updateCollapsed() {
        let collapsed = floating && minimize && !hovering
        modes.isHidden = collapsed
        single.isHidden = !collapsed
        single.setImage(images[mode.rawValue], forSegment: 0)
        barWidth.constant = collapsed ? 40 : 100
    }

    private static func css(_ color: NSColor) -> String {
        var rgb = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB) ?? color }
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255), rgb.alphaComponent)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func render() {
        guard mode != .code else { return }
        let settings: [String: Any] = [
            "background": Self.css(Settings.background),
            "foreground": Self.css(Settings.foreground),
            "fontSize": Double(max(Settings.fontSize, 12)),
            "fontName": Settings.font.familyName ?? "",
            "dark": Settings.editorIsDark,
        ]
        context.exception = nil
        let result = renderer.call(withArguments: [latest, settings])
        let html: String
        if let exception = context.exception {
            PluginFault.report(barTitle.stringValue, exception.toString())
            html = "<pre style=\"color:#d33;white-space:pre-wrap\">\(Self.escape(exception.toString()))</pre>"
        } else {
            html = result?.toString() ?? ""
        }
        show(html)
    }

    private func show(_ html: String) {
        guard ready else {
            if queued == nil { preview.loadHTMLString(html, baseURL: base) }
            queued = html
            return
        }
        preview.callAsyncJavaScript("document.documentElement.innerHTML = html", arguments: ["html": html],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let html = queued {
            queued = nil
            show(html)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.scheme == LocalFileScheme.scheme, url.fragment != nil { return decisionHandler(.allow) }
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    @objc private func modeChanged() {
        guard let next = Mode(rawValue: modes.selectedSegment) else { return }
        UserDefaults.standard.set(next.rawValue, forKey: modeKey)
        apply(next)
    }

    private func apply(_ next: Mode) {
        mode = next
        modes.selectedSegment = next.rawValue
        updateCollapsed()
        code.isHidden = next == .preview
        preview.isHidden = next == .code
        split.adjustSubviews()
        render()
        if next == .split {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.split.layoutSubtreeIfNeeded()
                self.split.setPosition(self.split.bounds.width / 2, ofDividerAt: 0)
            }
        }
        if next != .preview { code.window?.makeFirstResponder((code as? NSScrollView)?.documentView) }
    }
}

final class LocalFileScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "flarestack-file"

    static func url(for directory: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = ""
        parts.path = directory.standardizedFileURL.path + "/"
        return parts.url ?? directory
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
              let data = FileManager.default.contents(atPath: path) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class PluginSettingsView: NSView {
    private let id: String
    private var wells: [(PluginSetting, NSColorWell, NSTextField)] = []
    private var fields: [(PluginSetting, NSTextField)] = []
    private var checks: [(PluginSetting, NSButton)] = []
    private var popups: [(PluginSetting, NSPopUpButton)] = []
    private var sliders: [(PluginSetting, NSSlider, NSTextField)] = []

    init(id: String) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        let items = PluginStore.installed(id)?.settings ?? []
        var rows: [[NSView]] = []
        for setting in items {
            let label = NSTextField(labelWithString: setting.title)
            label.alignment = .right
            switch setting.type {
            case "color":
                let well = NSColorWell()
                well.isContinuous = true
                well.target = self
                well.action = #selector(wellChanged(_:))
                well.widthAnchor.constraint(equalToConstant: 44).isActive = true
                let hex = NSTextField()
                hex.placeholderString = "#RRGGBB"
                hex.target = self
                hex.action = #selector(hexChanged(_:))
                hex.widthAnchor.constraint(equalToConstant: 80).isActive = true
                let reset = PluginActionButton(title: "初期値") { [weak self] in
                    Settings.setPluginValue(id, setting.key, nil)
                    self?.load()
                }
                wells.append((setting, well, hex))
                rows.append([label, NSStackView(views: [well, hex, reset])])
            case "choice":
                let popup = NSPopUpButton()
                popup.addItems(withTitles: setting.options ?? [])
                popup.target = self
                popup.action = #selector(changed)
                popups.append((setting, popup))
                rows.append([label, popup])
            case "number":
                let slider = NSSlider(value: setting.min ?? 0, minValue: setting.min ?? 0, maxValue: setting.max ?? 100,
                                      target: self, action: #selector(sliderChanged(_:)))
                slider.isContinuous = true
                slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
                let value = NSTextField(labelWithString: "")
                value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                value.widthAnchor.constraint(equalToConstant: 40).isActive = true
                let reset = PluginActionButton(title: "初期値") { [weak self] in
                    Settings.setPluginValue(id, setting.key, nil)
                    self?.load()
                }
                sliders.append((setting, slider, value))
                rows.append([label, NSStackView(views: [slider, value, reset])])
            case "bool":
                let check = NSButton(checkboxWithTitle: setting.title, target: self, action: #selector(changed))
                checks.append((setting, check))
                rows.append([NSGridCell.emptyContentView, check])
            default:
                let field = NSTextField()
                field.target = self
                field.action = #selector(changed)
                field.widthAnchor.constraint(equalToConstant: 200).isActive = true
                fields.append((setting, field))
                rows.append([label, field])
            }
        }
        let extra = (NativePlugins.plugin(id) as? PluginSettingsProviding)?.settingsView()
        var content: NSView
        if rows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "このプラグインには設定項目がありません。")
            empty.textColor = .secondaryLabelColor
            content = empty
        } else {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 12
            grid.columnSpacing = 10
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            content = grid
        }
        if let extra {
            let stack = NSStackView(views: rows.isEmpty ? [extra] : [content, extra])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            content = stack
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        for (setting, well, hex) in wells {
            let saved = PluginStore.color(id, setting.key)
            well.color = saved ?? .textColor
            hex.stringValue = saved?.hexString ?? ""
        }
        for (setting, field) in fields { field.stringValue = PluginStore.setting(id, setting.key) ?? "" }
        for (setting, slider, value) in sliders {
            let saved = PluginStore.setting(id, setting.key).flatMap(Double.init)
            slider.doubleValue = saved ?? slider.minValue
            value.stringValue = saved.map { "\(Int($0))" } ?? "自動"
        }
        for (setting, check) in checks { check.state = PluginStore.setting(id, setting.key) == "true" ? .on : .off }
        for (setting, popup) in popups {
            if let value = PluginStore.setting(id, setting.key), let index = setting.options?.firstIndex(of: value) { popup.selectItem(at: index) }
        }
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard let (setting, _, hex) = wells.first(where: { $0.1 === sender }) else { return }
        hex.stringValue = sender.color.hexString
        Settings.setPluginValue(id, setting.key, sender.color.hexString)
    }

    @objc private func hexChanged(_ sender: NSTextField) {
        guard let (setting, well, _) = wells.first(where: { $0.2 === sender }) else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let color = NSColor(hex: text) else { return load() }
        well.color = color
        Settings.setPluginValue(id, setting.key, color.hexString)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let (setting, _, value) = sliders.first(where: { $0.1 === sender }) else { return }
        let number = Int(sender.doubleValue.rounded())
        value.stringValue = "\(number)"
        Settings.setPluginValue(id, setting.key, "\(number)")
    }

    @objc private func changed() {
        for (setting, field) in fields { Settings.setPluginValue(id, setting.key, field.stringValue) }
        for (setting, check) in checks { Settings.setPluginValue(id, setting.key, check.state == .on ? "true" : "false") }
        for (setting, popup) in popups { Settings.setPluginValue(id, setting.key, setting.options?[safe: popup.indexOfSelectedItem]) }
    }
}
