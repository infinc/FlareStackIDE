import AppKit
@testable import FlareStackIDE

final class EnvEditorPlugin: NativePlugin, FileViewing {
    static let pluginID = "env-editor"
    let id = pluginID

    static func handles(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == ".env" || name.hasPrefix(".env.") || (name.hasSuffix(".env") && name.count > 4)
    }

    func viewer(for url: URL) -> EditorExtension? {
        guard Self.handles(url), let text = CodeView.diskText(url) else { return nil }
        return EnvEditor(file: url, text: text)
    }
}

final class EnvTable: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? selectedRow >= 0 : super.validateUserInterfaceItem(item)
    }
}

final class EnvEditor: NSObject, EditorExtension, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let mask = "••••••••"
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let file: URL
    private var document: EnvDocument
    private var written: String
    private var rows: [Int] = []
    private var revealed = Set<Int>()
    private var revealAll = false
    private let scroll = NSScrollView()
    private let table = EnvTable()
    private let info = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "全て表示", target: nil, action: nil)
    var body: NSView { scroll }

    init(file: URL, text: String) {
        self.file = file
        document = EnvDocument(text: text)
        written = text
        super.init()
        revealAll = PluginStore.setting(EnvEditorPlugin.pluginID, "maskByDefault") == "false"
        for (id, title, width) in [("key", "キー", 200.0), ("value", "値", 320.0), ("eye", "", 28.0), ("comment", "コメント", 220.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "eye" ? 28 : 60
            if id == "eye" { column.maxWidth = 28 }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.rowSizeStyle = .medium
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.onCopy = { [weak self] in self?.copySelected() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        buildBar()
        reload()
        applySettings()
    }

    private func buildBar() {
        let add = NSButton(title: "行を追加", target: self, action: #selector(addRow))
        let remove = NSButton(title: "行を削除", target: self, action: #selector(removeRow))
        revealButton.target = self
        revealButton.action = #selector(toggleRevealAll)
        for button in [add, remove, revealButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        info.font = .systemFont(ofSize: 11, weight: .medium)
        info.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [info, add, remove, revealButton])
        stack.spacing = 6
        stack.setCustomSpacing(14, after: info)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        [stack, line].forEach(bar.addSubview)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func reload() {
        rows = document.entries.indices.filter { document.entries[$0].isVariable }
        revealButton.title = revealAll ? "全て隠す" : "全て表示"
        let duplicates = document.duplicateKeys.count
        info.stringValue = "\(rows.count) 個の変数" + (duplicates > 0 ? "（重複 \(duplicates)）" : "")
        table.reloadData()
    }

    private func isShown(_ index: Int) -> Bool { revealAll || revealed.contains(index) }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let index = rows[row]
        let entry = document.entries[index]
        if id == "eye" {
            let symbol = isShown(index) ? "eye.slash" : "eye"
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                                  target: self, action: #selector(toggleReveal(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = isShown(index) ? "値を隠す" : "値を表示"
            button.isHidden = revealAll
            return button
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.tag = index
        field.delegate = self
        switch id {
        case "key":
            field.stringValue = entry.key
            field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            field.textColor = document.duplicateKeys.contains(entry.key) ? .systemRed : .labelColor
            field.toolTip = document.duplicateKeys.contains(entry.key) ? "同じキーが複数あります" : nil
            field.isEditable = true
        case "value":
            let shown = isShown(index)
            field.stringValue = shown ? entry.value : (entry.value.isEmpty ? "" : Self.mask)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = shown ? .labelColor : .tertiaryLabelColor
            field.isEditable = shown
        default:
            field.stringValue = entry.comment
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.isEditable = true
        }
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, document.entries.indices.contains(field.tag) else { return }
        var entry = document.entries[field.tag]
        let text = field.stringValue
        switch field.identifier?.rawValue {
        case "key":
            let key = text.trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_.\-]*$"#, options: .regularExpression) != nil else {
                NSSound.beep()
                return reload()
            }
            entry.key = key
        case "value": entry.value = text
        default: entry.comment = text.trimmingCharacters(in: .whitespaces)
        }
        guard entry != document.entries[field.tag] else { return }
        entry.source = nil
        document.entries[field.tag] = entry
        save()
        reload()
    }

    @objc private func toggleReveal(_ sender: NSButton) {
        if !revealed.insert(sender.tag).inserted { revealed.remove(sender.tag) }
        let row = rows.firstIndex(of: sender.tag) ?? -1
        if row >= 0 { table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
    }

    @objc private func toggleRevealAll() {
        revealAll.toggle()
        revealed = []
        reload()
    }

    @objc private func addRow() {
        var name = "NEW_KEY"
        var n = 1
        let keys = Set(document.entries.filter(\.isVariable).map(\.key))
        while keys.contains(name) { n += 1; name = "NEW_KEY_\(n)" }
        let at = table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] + 1 : document.entries.count
        document.entries.insert(EnvEntry(key: name, value: "", comment: ""), at: at)
        revealed = Set(revealed.map { $0 >= at ? $0 + 1 : $0 })
        revealed.insert(at)
        save()
        reload()
        guard let row = rows.firstIndex(of: at) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeRow() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let index = rows[table.selectedRow]
        document.entries.remove(at: index)
        revealed = Set(revealed.compactMap { $0 == index ? nil : $0 > index ? $0 - 1 : $0 })
        save()
        reload()
    }

    private func copySelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.entries[rows[table.selectedRow]].value, forType: .string)
        Toasts.post("値をコピーしました", in: table.window)
    }

    private func save() {
        let text = document.text
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            written = text
        } catch {
            Toasts.post("保存できませんでした", message: error.localizedDescription)
        }
    }

    func update(text: String) {
        guard text != written else { return }
        written = text
        document = EnvDocument(text: text)
        revealed = []
        reload()
    }

    func applySettings() {
        bar.paint(.midTab)
        scroll.paint(.editor)
        scroll.backgroundColor = Settings.background
        table.backgroundColor = Settings.background
        table.reloadData()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(EnvEditorPlugin()) }
