import AppKit
import SQLite3
@testable import FlareStackIDE

final class SQLiteViewerPlugin: NativePlugin, FileViewing {
    static let pluginID = "sqlite-viewer"
    let id = SQLiteViewerPlugin.pluginID

    func viewer(for url: URL) -> EditorExtension? {
        guard PluginStore.installed(id)?.fileExtensions.contains(url.pathExtension.lowercased()) == true, SQLiteDatabase.isDatabase(url),
              let database = try? SQLiteDatabase(url: url, writable: PluginStore.setting(id, "allowWrite") == "true") else { return nil }
        return SQLiteViewer(database: database)
    }
}

enum SQLiteValue {
    case null, integer(Int64), real(Double), text(String), blob(Int)

    var display: String {
        switch self {
        case .null: return "NULL"
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .text(let value): return value.count > 500 ? String(value.prefix(500)) + "…" : value
        case .blob(let size): return "<BLOB \(size) バイト>"
        }
    }

    var plain: String {
        switch self {
        case .null: return ""
        case .text(let value): return value
        default: return display
        }
    }

    var dim: Bool {
        switch self {
        case .null, .blob: return true
        default: return false
        }
    }

    var numeric: Bool {
        switch self {
        case .integer, .real: return true
        default: return false
        }
    }
}

struct SQLiteResult {
    var columns: [String] = []
    var rows: [[SQLiteValue]] = []
    var truncated = false
    var changes: Int?
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let url: URL
    let writable: Bool
    private let queue = DispatchQueue(label: "FlareStackIDE.sqlite-viewer")

    static func isDatabase(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    init(url: URL, writable: Bool) throws {
        self.url = url
        self.writable = writable
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "開けませんでした"
            sqlite3_close(handle)
            throw Self.failure(message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private var message: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "" }

    func async<T>(_ work: @escaping (SQLiteDatabase) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result { try work(self) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    func tables() throws -> [(name: String, type: String)] {
        try query("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name", limit: 10_000)
            .rows.map { ($0[0].plain, $0[1].plain) }
    }

    func count(_ table: String) throws -> Int {
        guard case .integer(let value)? = try query("SELECT count(*) FROM \(Self.quote(table))", limit: 1).rows.first?.first else { return 0 }
        return Int(value)
    }

    func query(_ sql: String, limit: Int) throws -> SQLiteResult {
        var result = SQLiteResult()
        var rest = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while !rest.isEmpty {
            var statement: OpaquePointer?
            var tailText = ""
            let code = rest.withCString { pointer -> Int32 in
                var tail: UnsafePointer<CChar>?
                let code = sqlite3_prepare_v2(handle, pointer, -1, &statement, &tail)
                if let tail { tailText = String(cString: tail) }
                return code
            }
            guard code == SQLITE_OK else { throw Self.failure(message) }
            rest = tailText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let statement else { continue }
            defer { sqlite3_finalize(statement) }
            if sqlite3_stmt_readonly(statement) == 0 && !writable {
                throw Self.failure("書き込む SQL は実行できません（プラグインの設定「書き込みを許可」で変えられます）")
            }
            let columns = Int(sqlite3_column_count(statement))
            var current = SQLiteResult()
            current.columns = (0..<columns).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw Self.failure(message) }
                if current.rows.count >= limit {
                    current.truncated = true
                    break
                }
                current.rows.append((0..<Int32(columns)).map { value(statement, $0) })
            }
            if columns > 0 {
                result = current
            } else {
                result = SQLiteResult(changes: Int(sqlite3_changes(handle)))
            }
        }
        return result
    }

    private func value(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(statement, index)))
        default: return .null
        }
    }
}

private final class ResultTable: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

final class SQLiteViewer: NSObject, EditorExtension, NSTableViewDataSource, NSTableViewDelegate {
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let database: SQLiteDatabase
    private let container = NSView()
    private let scroll = NSScrollView()
    private let table = ResultTable()
    private let tablePopup = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: ["データ", "構造"], trackingMode: .selectOne, target: nil, action: nil)
    private let sqlField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var result = SQLiteResult()
    private var tables: [(name: String, type: String)] = []
    private var generation = 0
    var body: NSView { container }

    private var limit: Int { PluginStore.setting(SQLiteViewerPlugin.pluginID, "limit").flatMap { Double($0) }.map { Int($0) } ?? 1000 }

    init(database: SQLiteDatabase) {
        self.database = database
        super.init()
        buildBar()
        buildBody()
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        loadTables()
    }

    private func buildBar() {
        tablePopup.controlSize = .small
        tablePopup.font = .systemFont(ofSize: 11)
        tablePopup.target = self
        tablePopup.action = #selector(tableChanged)
        mode.controlSize = .small
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(tableChanged)
        sqlField.placeholderString = "SQL を入力して Enter（例: SELECT * FROM users WHERE id > 10）"
        sqlField.controlSize = .small
        sqlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sqlField.target = self
        sqlField.action = #selector(runSQL)
        sqlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let run = NSButton(title: "実行", target: self, action: #selector(runSQL))
        run.bezelStyle = .rounded
        run.controlSize = .small
        run.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [tablePopup, mode, sqlField, run])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tablePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func buildBody() {
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.onCopy = { [weak self] in self?.copyRows() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
    }

    @objc private func settingsChanged() { applySettings() }

    func update(text: String) {}

    func applySettings() {
        table.backgroundColor = Settings.background
        scroll.backgroundColor = Settings.background
        container.wantsLayer = true
        container.layer?.backgroundColor = Settings.background.cgColor
        table.reloadData()
    }

    private func loadTables() {
        database.async({ try $0.tables() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list):
                self.tables = list
                self.tablePopup.removeAllItems()
                for item in list {
                    self.tablePopup.addItem(withTitle: item.name)
                    self.tablePopup.lastItem?.image = NSImage(systemSymbolName: item.type == "view" ? "eye" : "tablecells", accessibilityDescription: nil)
                }
                self.tablePopup.isEnabled = !list.isEmpty
                self.mode.isEnabled = !list.isEmpty
                if list.isEmpty {
                    self.show(SQLiteResult(), note: "テーブルがありません")
                } else {
                    self.tableChanged()
                }
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func tableChanged() {
        guard let name = tables[safe: tablePopup.indexOfSelectedItem]?.name else { return }
        let quoted = SQLiteDatabase.quote(name)
        if mode.selectedSegment == 1 {
            execute("PRAGMA table_info(\(quoted))", label: "\(name) の構造")
        } else {
            sqlField.stringValue = "SELECT * FROM \(quoted)"
            execute(sqlField.stringValue, label: name, count: name)
        }
    }

    @objc private func runSQL() {
        let sql = sqlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        execute(sql, label: nil)
    }

    private func execute(_ sql: String, label: String?, count table: String? = nil) {
        generation += 1
        let current = generation
        let limit = limit
        status.stringValue = "実行中…"
        let started = Date()
        database.async({ database -> (SQLiteResult, Int?) in
            let result = try database.query(sql, limit: limit)
            return (result, try table.map(database.count))
        }) { [weak self] outcome in
            guard let self, current == self.generation else { return }
            switch outcome {
            case .success(let (result, total)):
                let time = String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000)
                var parts: [String] = []
                if let label { parts.append(label) }
                if let changes = result.changes {
                    parts.append("\(changes) 行を変更しました")
                    self.loadTables()
                } else if let total, result.truncated {
                    parts.append("全 \(total) 行のうち先頭 \(result.rows.count) 行")
                } else {
                    parts.append(result.truncated ? "先頭 \(result.rows.count) 行（続きは LIMIT / OFFSET で）" : "\(result.rows.count) 行")
                }
                parts.append(time)
                self.show(result, note: parts.joined(separator: "　·　"))
            case .failure(let error):
                self.status.stringValue = "エラー: " + error.localizedDescription
                self.status.textColor = .systemRed
            }
        }
    }

    private func show(_ result: SQLiteResult, note: String) {
        self.result = result
        status.stringValue = (database.writable ? "" : "読み取り専用　·　") + note
        status.textColor = .secondaryLabelColor
        table.tableColumns.forEach(table.removeTableColumn)
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for (index, name) in result.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = name
            let sample = result.rows.prefix(200).map { ($0[index].display as NSString).size(withAttributes: [.font: Settings.font]).width }.max() ?? 0
            column.width = min(max((name as NSString).size(withAttributes: [.font: font]).width + 24, sample + 16, 60), 360)
            table.addTableColumn(column)
        }
        table.reloadData()
        table.scrollRowToVisible(0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let index = Int(id.rawValue), let value = result.rows[safe: row]?[safe: index] else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        cell.font = Settings.font.withSize(max(Settings.fontSize - 1, 10))
        cell.stringValue = value.display.replacingOccurrences(of: "\n", with: "⏎")
        cell.textColor = value.dim ? Settings.foreground.withAlphaComponent(0.4) : Settings.foreground
        cell.alignment = value.numeric ? .right : .left
        cell.toolTip = value.plain.count > 40 ? String(value.plain.prefix(2000)) : nil
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { ceil(Settings.fontSize * 1.6) }

    private func copyRows() {
        let rows = table.selectedRowIndexes.compactMap { result.rows[safe: $0] }
        guard !rows.isEmpty else { return }
        let text = ([result.columns] + rows.map { $0.map(\.plain) }).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(SQLiteViewerPlugin()) }
