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
