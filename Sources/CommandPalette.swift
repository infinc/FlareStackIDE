import AppKit

struct PaletteCommand {
    let id: String
    let title: String
    var detail = ""
    let perform: () -> Void
}

protocol CommandProviding: AnyObject {
    var commands: [PaletteCommand] { get }
}

final class CommandPalette: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let defaultKey = "p"
    static let defaultModifiers: NSEvent.ModifierFlags = [.command, .shift]
    static weak var menuItem: NSMenuItem?
    private static let recentKey = "Palette.Recent"
    private static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 30

    private let panel: SearchPanelWindow
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var height: NSLayoutConstraint!
    private var all: [PaletteCommand] = []
    private var shown: [PaletteCommand] = []

    static func overrideKey(_ equivalent: String?, modifiers: NSEvent.ModifierFlags = []) {
        guard let item = menuItem else { return }
        item.keyEquivalent = equivalent ?? defaultKey
        item.keyEquivalentModifierMask = equivalent == nil ? defaultModifiers : modifiers
    }

    static func shortcutLabel(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        let parts: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let key: String
        switch item.keyEquivalent {
        case " ": key = "Space"
        case "\r": key = "↩"
        case "\t": key = "⇥"
        default:
            let scalar = item.keyEquivalent.unicodeScalars.first.map { Int($0.value) } ?? 0
            key = (NSF1FunctionKey...NSF35FunctionKey).contains(scalar) ? "F\(scalar - NSF1FunctionKey + 1)" : item.keyEquivalent.uppercased()
        }
        return parts.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    static func menuCommands(_ menu: NSMenu? = NSApp.mainMenu, path: [String] = []) -> [PaletteCommand] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [PaletteCommand] in
            if item.isSeparatorItem || item.isHidden { return [] }
            if let submenu = item.submenu { return menuCommands(submenu, path: path + [item.title]) }
            guard let action = item.action, item !== menuItem else { return [] }
            let title = (path.dropFirst() + [item.title]).joined(separator: " › ")
            return [PaletteCommand(id: "menu." + title, title: title, detail: shortcutLabel(item)) { [weak item] in
                guard let item else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }]
        }
    }

    override init() {
        panel = SearchPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 52),
                                  styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        field.placeholderString = "コマンドを入力"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [field, scroll].forEach(effect.addSubview)
        height = effect.heightAnchor.constraint(equalToConstant: 52)
        NSLayoutConstraint.activate([
            effect.widthAnchor.constraint(equalToConstant: Self.width),
            height,
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func show(over parent: NSWindow, commands: [PaletteCommand]) {
        var seen = Set<String>()
        all = commands.filter { seen.insert($0.id).inserted }
        field.stringValue = ""
        filter()
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        let frame = parent.frame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() { panel.close() }

    func windowDidResignKey(_ notification: Notification) { panel.close() }

    func windowWillClose(_ notification: Notification) { panel.parent?.removeChildWindow(panel) }

    static func score(_ title: String, _ query: String) -> Int? {
        let text = title.lowercased()
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        var total = 0
        for word in words {
            if text.hasPrefix(word) { total += 1000; continue }
            if let range = text.range(of: word) {
                total += 600 - text.distance(from: text.startIndex, to: range.lowerBound)
                continue
            }
            let chars = Array(text)
            var index = 0
            var points = 0
            for c in word {
                guard let found = chars[index...].firstIndex(of: c) else { return nil }
                let start = found == 0 || " ›_-./".contains(chars[found - 1])
                points += start ? 20 : found == index ? 8 : 1
                index = found + 1
            }
            total += points
        }
        return total
    }

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        let rank: (PaletteCommand) -> Int = { recent.firstIndex(of: $0.id).map { 100 - $0 } ?? 0 }
        shown = all.compactMap { command in Self.score(command.title, query).map { (command, $0 + rank(command)) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
            .map(\.0)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        let rows = CGFloat(min(shown.count, 10)) * Self.rowHeight
        let value = 52 + (shown.isEmpty ? 0 : rows + 16)
        scroll.isHidden = shown.isEmpty
        guard abs(height.constant - value) > 0.5 else { return }
        let top = panel.frame.maxY
        height.constant = value
        panel.setContentSize(NSSize(width: Self.width, height: value))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): panel.close()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        runSelected()
    }

    private func runSelected() {
        guard shown.indices.contains(table.selectedRow) else { return }
        let command = shown[table.selectedRow]
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == command.id }
        UserDefaults.standard.set(Array(([command.id] + recent).prefix(20)), forKey: Self.recentKey)
        let parent = panel.parent
        panel.close()
        parent?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async(execute: command.perform)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = shown[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: command.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        [title, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
