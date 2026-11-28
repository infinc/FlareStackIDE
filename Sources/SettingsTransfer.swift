import AppKit
import UniformTypeIdentifiers

final class SettingsTransfer: NSObject {
    static let shared = SettingsTransfer()
    private static let format = "\(appName).Settings"
    private static let formatVersion = 1
    private static let prefixes = [
        "Base.", "BigTab.", "Editor.Background", "Editor.Font", "Editor.Foreground", "Editor.LineSpacing", "Editor.Wrap",
        "Surface.", "Terminal.", "Toast.", "Theme.", "Themes.", "Plugins.AutoUpdate", "Plugins.Category",
        "App.Language", "RefactorOnRename", "CrashReport.Auto", "Plugin.",
    ]
    private static let excluded = ["Plugin.copy-manager.History", "Plugin.session-restore."]

    static func isTransferable(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) } && !excluded.contains { key.hasPrefix($0) }
    }

    private static var stored: [String: Any] {
        guard let domain = Bundle.main.bundleIdentifier else { return [:] }
        return (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { isTransferable($0.key) }
    }

    static func exportData() throws -> Data {
        let root: [String: Any] = [
            "Format": format,
            "FormatVersion": formatVersion,
            "AppVersion": AppUpdate.shared.currentVersion,
            "Exported": Date(),
            "Defaults": stored,
            "Plugins": PluginStore.installedIDs,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    struct Imported {
        let defaults: [String: Any]
        let plugins: [String]
        let appVersion: String?
    }

    static func read(_ data: Data) throws -> Imported {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["Format"] as? String == format else { throw failure("\(appName) の設定ファイルではありません") }
        guard (root["FormatVersion"] as? Int ?? 0) <= formatVersion else {
            throw failure("新しい版の \(appName) で書き出した設定です。\(appName) をアップデートしてください")
        }
        let defaults = (root["Defaults"] as? [String: Any] ?? [:]).filter { isTransferable($0.key) }
        let plugins = (root["Plugins"] as? [String] ?? []).filter { $0.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil }
        return Imported(defaults: defaults, plugins: plugins, appVersion: root["AppVersion"] as? String)
    }

    static func apply(_ imported: Imported) {
        let defaults = UserDefaults.standard
        for key in stored.keys where imported.defaults[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in imported.defaults { defaults.set(value, forKey: key) }
        NativePlugins.invalidate()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        NotificationCenter.default.post(name: .pluginsChanged, object: nil)
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @objc func exportClicked(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "設定を書き出す"
        panel.allowedContentTypes = [.propertyList]
        let date = DateFormatter()
        date.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "\(appName)-settings-\(date.string(from: Date())).plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.exportData().write(to: url, options: .atomic)
            Toasts.post("設定を書き出しました", message: url.lastPathComponent,
                        actions: [("Finder で表示", { NSWorkspace.shared.activateFileViewerSelecting([url]) })])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func importClicked(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "設定を読み込む"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let imported: Imported
        do {
            imported = try Self.read(try Data(contentsOf: url))
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let missing = imported.plugins.filter { !PluginStore.isInstalled($0) && PluginStore.info($0) != nil }
        let alert = NSAlert()
        alert.messageText = "設定を読み込みますか？"
        alert.informativeText = "今の外観・エディタ・プラグインの設定（\(imported.defaults.count) 項目）を、ファイルの内容に置き換えます。"
            + (imported.appVersion.map { "\n書き出した版: v\($0)" } ?? "")
        let install = NSButton(checkboxWithTitle: "書き出したときのプラグインもインストールする（\(missing.count) 個）", target: nil, action: nil)
        install.state = missing.isEmpty ? .off : .on
        install.isEnabled = !missing.isEmpty
        alert.accessoryView = install
        alert.addButton(withTitle: "読み込む")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.apply(imported)
        Toasts.post("設定を読み込みました", message: "一部の設定は再起動後に反映されます",
                    actions: [("今すぐ再起動", { Updater.relaunch() })])
        guard install.state == .on else { return }
        installPlugins(missing)
    }

    private func installPlugins(_ ids: [String]) {
        guard let id = ids.first else { return }
        PluginStore.install(id) { [weak self] error in
            if let error { Toasts.post("\(PluginStore.info(id)?.name ?? id) をインストールできませんでした", message: error.localizedDescription) }
            self?.installPlugins(Array(ids.dropFirst()))
        }
    }
}

extension SettingsTransfer {
    private static var watcher: DispatchSourceFileSystemObject?
    private static var lastApplied: Data?

    static var jsonURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("settings.json")
    }

    private static func isJSONValue(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber: return true
        case let list as [Any]: return list.allSatisfy(isJSONValue)
        case let map as [String: Any]: return map.values.allSatisfy(isJSONValue)
        default: return false
        }
    }

    private static var editable: [String: Any] { stored.filter { isJSONValue($0.value) } }

    static func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: editable, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func sameKind(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is String, is String), (is NSNumber, is NSNumber), (is [Any], is [Any]), (is [String: Any], is [String: Any]): return true
        default: return false
        }
    }

    static func applyJSON(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("settings.json の一番外側は { } にしてください")
        }
        let current = editable
        let unknown = object.keys.filter { !isTransferable($0) }.sorted()
        guard unknown.isEmpty else { throw failure("変更できないキーがあります: " + unknown.joined(separator: ", ")) }
        let mismatched = object.filter { key, value in current[key].map { !sameKind($0, value) } ?? !isJSONValue(value) }.keys.sorted()
        guard mismatched.isEmpty else { throw failure("値の種類が違います: " + mismatched.joined(separator: ", ")) }
        let defaults = UserDefaults.standard
        for key in current.keys where object[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in object { defaults.set(value, forKey: key) }
        NativePlugins.invalidate()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        NotificationCenter.default.post(name: .pluginsChanged, object: nil)
    }

    @objc func editJSONClicked(_ sender: Any?) {
        let url = Self.jsonURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.jsonData()
            try data.write(to: url, options: .atomic)
            Self.lastApplied = data
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        Self.watch()
        let editors = NSApp.windows.compactMap { $0.windowController as? EditorWindowController }
        if let editor = (NSApp.keyWindow?.windowController as? EditorWindowController) ?? editors.first {
            editor.open(url)
            editor.window?.makeKeyAndOrderFront(nil)
        } else {
            NSApp.delegate?.application?(NSApp, open: [url])
        }
        Toasts.post("settings.json を開きました", message: "保存すると設定に反映します。キーを消すと既定値に戻ります")
    }

    private static func watch() {
        guard watcher == nil else { return }
        let folder = jsonURL.deletingLastPathComponent()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: reloadJSON) }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private static func reloadJSON() {
        guard let data = try? Data(contentsOf: jsonURL), data != lastApplied else { return }
        lastApplied = data
        do {
            try applyJSON(data)
            Toasts.post("settings.json を反映しました")
        } catch {
            let detail = (error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription
            Toasts.post("settings.json を反映できませんでした", message: detail)
        }
    }
}
