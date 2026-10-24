import AppKit

protocol CodeEditing: AnyObject {
    var textView: NSTextView { get }
    var scrollView: NSScrollView { get }
    var fileURL: URL? { get }
    var tabStrip: TabStrip? { get }
    var projectDirectory: URL? { get }
    var openTexts: [(url: URL, text: String)] { get }
    func closeAllTabs()
}

protocol TextAddon: AnyObject {
    var priority: Int { get }
    func shouldChange(_ range: NSRange, text: String) -> Bool
    func doCommand(_ selector: Selector) -> Bool
    func selectionChanged()
    func textChanged()
    func fileOpened()
    func treeChanged()
    func dismiss()
    func detach()
}

extension TextAddon {
    var priority: Int { 0 }
    func shouldChange(_ range: NSRange, text: String) -> Bool { true }
    func doCommand(_ selector: Selector) -> Bool { false }
    func selectionChanged() {}
    func textChanged() {}
    func fileOpened() {}
    func treeChanged() {}
    func dismiss() {}
    func detach() {}
}

protocol WindowAddon: AnyObject {
    func fileOpened()
    func textChanged()
    func bufferClosed(_ url: URL)
    func decorate(_ layout: NSLayoutManager)
    func detach()
}

extension WindowAddon {
    func fileOpened() {}
    func textChanged() {}
    func bufferClosed(_ url: URL) {}
    func decorate(_ layout: NSLayoutManager) {}
    func detach() {}
}

protocol FileWindow: NSWindowController {
    var documentURL: URL { get }
    var onClose: (() -> Void)? { get set }
    func save()
}

protocol NativePlugin: AnyObject {
    var id: String { get }
    var opensFiles: Bool { get }
    func textAddon(for code: CodeEditing) -> TextAddon?
    func windowAddon(for editor: EditorWindowController) -> WindowAddon?
    func fileWindow(for url: URL) -> FileWindow?
}

extension NativePlugin {
    var opensFiles: Bool { false }
    func textAddon(for code: CodeEditing) -> TextAddon? { nil }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { nil }
    func fileWindow(for url: URL) -> FileWindow? { nil }
}

enum NativePlugins {
    static let binary = "plugin.dylib"
    private typealias Entry = @convention(c) () -> Void
    private static var loaded: [String: (plugin: NativePlugin?, version: String)] = [:]
    private static var registering: NativePlugin?
    private static var restartNoted: Set<String> = []

    static func register(_ plugin: NativePlugin) { registering = plugin }

    static var active: [NativePlugin] {
        PluginStore.installedIDs.compactMap { id in
            guard let info = PluginStore.installed(id) else { return nil }
            if let entry = loaded[id] {
                if entry.version != info.version, entry.plugin != nil, !restartNoted.contains(id) {
                    restartNoted.insert(id)
                    Toasts.post("\(info.name) v\(info.version) は再起動後に反映されます", message: "\(appName) を再起動してください")
                }
                return entry.plugin
            }
            let file = PluginStore.folder(id).appendingPathComponent(binary)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let plugin = load(file, name: info.name)
            loaded[id] = (plugin, info.version)
            return plugin
        }
    }

    static func plugin(_ id: String) -> NativePlugin? { active.first { $0.id == id } }

    private static func load(_ file: URL, name: String) -> NativePlugin? {
        guard let handle = dlopen(file.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? ""
            Toasts.post("\(name) を読み込めませんでした", message: "\(appName) を最新版にアップデートしてください。\n\(reason)")
            return nil
        }
        guard let symbol = dlsym(handle, "flarestack_plugin_load") else { return nil }
        registering = nil
        unsafeBitCast(symbol, to: Entry.self)()
        defer { registering = nil }
        return registering
    }

    static func fileWindow(for url: URL) -> FileWindow? { active.lazy.compactMap { $0.fileWindow(for: url) }.first }

    static var opensFiles: Bool { active.contains { $0.opensFiles } }
}

final class TextAddons {
    private weak var code: CodeEditing?
    private let only: Set<String>?
    private var items: [(id: String, addon: TextAddon)] = []

    init(code: CodeEditing, only: Set<String>? = nil) {
        self.code = code
        self.only = only
    }

    func sync() {
        guard let code else { return }
        let plugins = NativePlugins.active.filter { only?.contains($0.id) ?? true }
        let ids = Set(plugins.map(\.id))
        items.filter { !ids.contains($0.id) }.forEach { $0.addon.detach() }
        items.removeAll { !ids.contains($0.id) }
        for plugin in plugins where !items.contains(where: { $0.id == plugin.id }) {
            if let addon = plugin.textAddon(for: code) { items.append((plugin.id, addon)) }
        }
        items.sort { $0.addon.priority > $1.addon.priority }
    }

    func shouldChange(_ range: NSRange, text: String) -> Bool {
        items.reduce(true) { $1.addon.shouldChange(range, text: text) && $0 }
    }

    func doCommand(_ selector: Selector) -> Bool { items.contains { $0.addon.doCommand(selector) } }

    func each(_ body: (TextAddon) -> Void) { items.forEach { body($0.addon) } }

    func detachAll() {
        items.forEach { $0.addon.detach() }
        items = []
    }
}

final class WindowAddons {
    private weak var editor: EditorWindowController?
    private var items: [(id: String, addon: WindowAddon)] = []

    init(editor: EditorWindowController) { self.editor = editor }

    func sync() {
        guard let editor else { return }
        let plugins = NativePlugins.active
        let ids = Set(plugins.map(\.id))
        items.filter { !ids.contains($0.id) }.forEach { $0.addon.detach() }
        items.removeAll { !ids.contains($0.id) }
        for plugin in plugins where !items.contains(where: { $0.id == plugin.id }) {
            if let addon = plugin.windowAddon(for: editor) { items.append((plugin.id, addon)) }
        }
    }

    func each(_ body: (WindowAddon) -> Void) { items.forEach { body($0.addon) } }

    func detachAll() {
        items.forEach { $0.addon.detach() }
        items = []
    }
}
