import AppKit
@testable import FlareStackIDE

struct Shortcut: Codable, Equatable {
    var id = UUID().uuidString
    var keyCode: UInt16?
    var modifiers: UInt = 0
    var key = ""
    var action = ShortcutAction.run.rawValue

    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var label: String {
        guard keyCode != nil else { return "未設定" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let parts: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return parts.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.mask).rawValue == modifiers
    }
}

enum ShortcutAction: String, CaseIterable {
    case run, theme, close

    var title: String {
        switch self {
        case .run: return "実行（Runner が必要）"
        case .theme: return "テーマ切り替え"
        case .close: return "プロジェクトを保存して終了"
        }
    }
}

enum ShortcutStore {
    static let pluginID = "shortcut"
    private static let key = "Plugin.\(pluginID).Items"

    static var items: [Shortcut] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    private static let names: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    static func isFunctionKey(_ code: UInt16) -> Bool { names[code]?.hasPrefix("F") == true }

    static func keyName(_ event: NSEvent) -> String {
        names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

final class ShortcutSettingsView: NSStackView {
    private var recording: (id: String, button: NSButton)?
    private var monitor: Any?
    private let rows = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString: "キーの欄を押してから、割り当てたいキーの組み合わせを押してください（⌘・⌃・⌥ のどれかを含めるか、F1〜F15）。esc で取り消し。")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let title = NSTextField(labelWithString: "ショートカット")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 380
        let add = NSButton(title: "ショートカットを追加", target: self, action: #selector(addClicked))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.controlSize = .small
        [title, rows, add, hint].forEach(addArrangedSubview)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    private func reload() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = ShortcutStore.items
        if items.isEmpty {
            let none = NSTextField(labelWithString: "ショートカットはまだありません。")
            none.textColor = .secondaryLabelColor
            rows.addArrangedSubview(none)
        }
        for item in items {
            let key = NSButton(title: item.label, target: self, action: #selector(recordClicked(_:)))
            key.identifier = NSUserInterfaceItemIdentifier(item.id)
            key.bezelStyle = .rounded
            key.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let action = NSPopUpButton()
            ShortcutAction.allCases.forEach { action.addItem(withTitle: $0.title) }
            action.selectItem(at: ShortcutAction.allCases.firstIndex { $0.rawValue == item.action } ?? 0)
            action.identifier = NSUserInterfaceItemIdentifier(item.id)
            action.target = self
            action.action = #selector(actionChanged(_:))
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "削除")!,
                                  target: self, action: #selector(removeClicked(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(item.id)
            remove.isBordered = false
            remove.toolTip = "削除"
            let row = NSStackView(views: [key, action, remove])
            row.spacing = 8
            rows.addArrangedSubview(row)
        }
    }

    private func update(_ id: String, _ change: (inout Shortcut) -> Void) {
        var items = ShortcutStore.items
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        ShortcutStore.items = items
    }

    @objc private func addClicked() {
        stopRecording()
        ShortcutStore.items.append(Shortcut())
        reload()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        stopRecording()
        ShortcutStore.items.removeAll { $0.id == sender.identifier?.rawValue }
        reload()
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue else { return }
        update(id) { $0.action = ShortcutAction.allCases[max(sender.indexOfSelectedItem, 0)].rawValue }
    }

    @objc private func recordClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        stopRecording()
        recording = (id, sender)
        sender.title = "キーを入力…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording != nil, event.window === self.window else { return event }
            self.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let recording else { return }
        let flags = event.modifierFlags.intersection(Shortcut.mask)
        if event.keyCode == 53, flags.isEmpty { return stopRecording() }
        guard !flags.intersection([.command, .option, .control]).isEmpty || ShortcutStore.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        let used = ShortcutStore.items.contains { $0.id != recording.id && $0.keyCode == event.keyCode && $0.modifiers == flags.rawValue }
        guard !used else {
            NSSound.beep()
            return
        }
        update(recording.id) {
            $0.keyCode = event.keyCode
            $0.modifiers = flags.rawValue
            $0.key = ShortcutStore.keyName(event)
        }
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        reload()
    }
}
