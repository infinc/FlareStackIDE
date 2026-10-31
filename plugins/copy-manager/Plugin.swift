import AppKit
@testable import FlareStackIDE

final class CopyManagerPlugin: NativePlugin {
    let id = ClipboardHistory.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { CopyManagerAddon(editor: editor) }
}

final class ClipboardHistory {
    static let pluginID = "copy-manager"
    static let shared = ClipboardHistory()
    enum Order: String { case recent = "", ascending, descending }

    private let historyKey = "Plugin.\(pluginID).History"
    private let orderKey = "Plugin.\(pluginID).Order"
    private let limit = 50
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var users = 0

    var items: [String] {
        get { UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(limit)), forKey: historyKey) }
    }

    var order: Order {
        get { Order(rawValue: UserDefaults.standard.string(forKey: orderKey) ?? "") ?? .recent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: orderKey) }
    }

    var sorted: [String] {
        switch order {
        case .recent: return items
        case .ascending: return items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .descending: return items.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        }
    }

    func start() {
        users += 1
        guard timer == nil else { return }
        changeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        users -= 1
        guard users <= 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items = [text] + items.filter { $0 != text }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clear() { items = [] }
}

final class ClipButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
}

final class CopyManagerAddon: NSObject, WindowAddon {
    private let button = ClipButton()
    private let history = ClipboardHistory.shared

    init(editor: EditorWindowController) {
        super.init()
        button.image = EditorWindowController.cloudImage("paperclip")
        button.isBordered = false
        button.toolTip = "コピーの履歴（右クリックで並べ替え・削除）"
        button.target = self
        button.action = #selector(showHistory)
        button.onRightClick = { [weak self] in self?.showOptions() }
        editor.addTopButton(button)
        history.start()
    }

    private func item(_ title: String, _ action: Selector?, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let short = line.count > 60 ? String(line.prefix(60)) + "…" : line
        return text.contains(where: \.isNewline) && !short.hasSuffix("…") ? short + " …" : short
    }

    @objc private func showHistory() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries = history.sorted
        if entries.isEmpty {
            let none = item("履歴はありません", nil)
            none.isEnabled = false
            menu.addItem(none)
        }
        for text in entries {
            let entry = item(Self.title(text), #selector(copyItem(_:)), text)
            entry.toolTip = text.count > 500 ? String(text.prefix(500)) + "…" : text
            menu.addItem(entry)
        }
        popUp(menu)
    }

    private func showOptions() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let clear = item("履歴を全て削除", #selector(clearAll))
        clear.isEnabled = !history.items.isEmpty
        menu.addItem(clear)
        menu.addItem(.separator())
        let ascending = item("昇順（A-Z）", #selector(sortItems(_:)), ClipboardHistory.Order.ascending.rawValue)
        ascending.state = history.order == .ascending ? .on : .off
        let descending = item("降順（Z-A）", #selector(sortItems(_:)), ClipboardHistory.Order.descending.rawValue)
        descending.state = history.order == .descending ? .on : .off
        menu.addItem(ascending)
        menu.addItem(descending)
        popUp(menu)
    }

    @objc private func copyItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        history.copy(text)
    }

    @objc private func clearAll() { history.clear() }

    @objc private func sortItems(_ sender: NSMenuItem) {
        guard let next = (sender.representedObject as? String).flatMap(ClipboardHistory.Order.init) else { return }
        history.order = history.order == next ? .recent : next
    }

    func detach() {
        button.removeFromSuperview()
        history.stop()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CopyManagerPlugin()) }
