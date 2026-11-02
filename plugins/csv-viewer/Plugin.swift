import AppKit
@testable import FlareStackIDE

final class CSVViewerPlugin: NativePlugin, FileViewing {
    let id = "csv-viewer"

    func viewer(for url: URL) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        guard PluginStore.installed(id)?.fileExtensions.contains(ext) == true, let text = CodeView.diskText(url) else { return nil }
        return CSVViewer(file: url, text: text, delimiter: ext == "tsv" ? "\t" : ",")
    }
}

final class CSVViewer: NSObject, EditorExtension, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let file: URL
    private let delimiter: Character
    private var document: CSVDocument
    private var written: String
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let info = NSTextField(labelWithString: "")
    private var activeColumn = -1
    var body: NSView { scroll }

    init(file: URL, text: String, delimiter: Character) {
        self.file = file
        self.delimiter = delimiter
        document = CSVDocument(text: text, delimiter: delimiter)
        written = text
        super.init()
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.target = self
        table.action = #selector(cellClicked)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        buildBar()
        rebuildColumns()
        applySettings()
    }

    private func buildBar() {
        let buttons = [("行を追加", #selector(addRow)), ("列を追加", #selector(addColumn)), ("行を削除", #selector(removeRow)), ("列を削除", #selector(removeColumn))].map { title, action -> NSButton in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            return button
        }
        info.font = .systemFont(ofSize: 11, weight: .medium)
        info.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [info] + buttons)
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

    private static func columnName(_ index: Int) -> String {
        var name = "", value = index
        repeat {
            name = String(UnicodeScalar(UInt8(65 + value % 26))) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    private func rebuildColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        let number = NSTableColumn(identifier: .init("#"))
        number.title = ""
        number.width = 44
        table.addTableColumn(number)
        for index in 0..<document.columnCount {
            let column = NSTableColumn(identifier: .init(String(index)))
            column.title = Self.columnName(index)
            column.width = 130
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.reloadData()
        info.stringValue = "\(document.rows.count) 行 × \(document.columnCount) 列"
    }

    @objc private func cellClicked() { if table.clickedColumn > 0 { activeColumn = table.clickedColumn } }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        activeColumn = tableView.tableColumns.firstIndex(of: tableColumn) ?? -1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = id
            made.lineBreakMode = .byTruncatingTail
            made.font = .systemFont(ofSize: 12)
            return made
        }()
        if let index = Int(id.rawValue) {
            let cells = document.rows[row]
            field.stringValue = index < cells.count ? cells[index] : ""
            field.isEditable = true
            field.delegate = self
        } else {
            field.stringValue = "\(row + 1)"
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
        }
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = table.row(for: field), column = table.column(for: field) - 1
        guard document.rows.indices.contains(row), column >= 0 else { return }
        while document.rows[row].count <= column { document.rows[row].append("") }
        guard document.rows[row][column] != field.stringValue else { return }
        document.rows[row][column] = field.stringValue
        save()
    }

    private func save() {
        let text = document.text
        do {
            try text.write(to: file, atomically: false, encoding: .utf8)
            written = text
        } catch {
            Toasts.post("保存できませんでした", message: error.localizedDescription)
        }
    }

    @objc private func addRow() {
        let at = table.selectedRow >= 0 ? table.selectedRow + 1 : document.rows.count
        document.rows.insert(Array(repeating: "", count: max(document.columnCount, 1)), at: at)
        rebuildColumns()
        table.selectRowIndexes(IndexSet(integer: at), byExtendingSelection: false)
        table.scrollRowToVisible(at)
        save()
    }

    @objc private func addColumn() {
        if document.rows.isEmpty { document.rows.append([]) }
        let count = document.columnCount
        for row in document.rows.indices {
            while document.rows[row].count <= count { document.rows[row].append("") }
        }
        rebuildColumns()
        save()
    }

    @objc private func removeRow() {
        guard document.rows.indices.contains(table.selectedRow) else { return }
        document.rows.remove(at: table.selectedRow)
        rebuildColumns()
        save()
    }

    @objc private func removeColumn() {
        let index = (activeColumn > 0 ? activeColumn : table.tableColumns.count - 1) - 1
        guard index >= 0, index < document.columnCount else { return }
        for row in document.rows.indices where index < document.rows[row].count { document.rows[row].remove(at: index) }
        activeColumn = -1
        rebuildColumns()
        save()
    }

    func update(text: String) {
        guard text != written else { return }
        written = text
        document = CSVDocument(text: text, delimiter: delimiter)
        rebuildColumns()
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
public func flarestackPluginLoad() { NativePlugins.register(CSVViewerPlugin()) }
