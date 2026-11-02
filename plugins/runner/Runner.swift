import AppKit
@testable import FlareStackIDE

struct RunConfig: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var directory: String
    var script: String
    var environment = ""
    var parameters = ""
    var envFile = ""

    init(name: String, directory: String, script: String, environment: String = "", parameters: String = "", envFile: String = "") {
        self.name = name
        self.directory = directory
        self.script = script
        self.environment = environment
        self.parameters = parameters
        self.envFile = envFile
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        directory = try values.decode(String.self, forKey: .directory)
        script = try values.decode(String.self, forKey: .script)
        environment = try values.decodeIfPresent(String.self, forKey: .environment) ?? ""
        parameters = try values.decodeIfPresent(String.self, forKey: .parameters) ?? ""
        envFile = try values.decodeIfPresent(String.self, forKey: .envFile) ?? ""
    }
}

struct RunTemplate {
    let title: String
    let extensions: [String]
    let config: RunConfig

    static let all: [RunTemplate] = [
        RunTemplate(title: "Python", extensions: ["py"], config: RunConfig(name: "Python", directory: "", script: "main.py")),
        RunTemplate(title: "Node.js", extensions: ["js", "mjs", "cjs"], config: RunConfig(name: "Node.js", directory: "", script: "index.js")),
        RunTemplate(title: "TypeScript 実行", extensions: ["ts", "tsx"], config: RunConfig(name: "TypeScript", directory: "", script: "index.ts")),
        RunTemplate(title: "TypeScript コンパイル", extensions: [], config: RunConfig(name: "ts compile", directory: "", script: "npx tsc", parameters: "-p tsconfig.json")),
        RunTemplate(title: "Rust 実行", extensions: [], config: RunConfig(name: "cargo run", directory: "", script: "cargo run")),
        RunTemplate(title: "Rust コンパイル", extensions: [], config: RunConfig(name: "rust compile", directory: "", script: "cargo build", parameters: "--release")),
        RunTemplate(title: "C", extensions: ["c"], config: RunConfig(name: "C", directory: "", script: "main.c")),
        RunTemplate(title: "C++", extensions: ["cpp", "cc", "cxx"], config: RunConfig(name: "C++", directory: "", script: "main.cpp")),
        RunTemplate(title: "Go", extensions: [], config: RunConfig(name: "Go", directory: "", script: "go run", parameters: ".")),
        RunTemplate(title: "Swift", extensions: ["swift"], config: RunConfig(name: "Swift", directory: "", script: "main.swift")),
        RunTemplate(title: "Java", extensions: ["java"], config: RunConfig(name: "Java", directory: "", script: "Main.java")),
        RunTemplate(title: "Ruby", extensions: ["rb"], config: RunConfig(name: "Ruby", directory: "", script: "main.rb")),
        RunTemplate(title: "シェルスクリプト", extensions: ["sh", "bash", "zsh"], config: RunConfig(name: "Shell", directory: "", script: "run.sh")),
    ]

    func make(current: String?) -> RunConfig {
        var made = config
        made.id = UUID().uuidString
        if let current, extensions.contains((current as NSString).pathExtension.lowercased()) {
            made.script = current
            made.name = (current as NSString).lastPathComponent
        }
        return made
    }
}

final class RunnerStore {
    static let pluginID = "runner"
    private struct Saved: Codable {
        var configs: [RunConfig]
        var selected: String?
    }

    private let key: String
    private let base: URL
    private(set) var configs: [RunConfig] = []
    var selectedID: String? { didSet { save() } }

    init(project: Project, base: URL) {
        key = "Runner.\(project.path)"
        self.base = base
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            configs = saved.configs
            selectedID = saved.selected
        }
    }

    var selected: RunConfig? { configs.first { $0.id == selectedID } ?? nil }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(Saved(configs: configs, selected: selectedID)), forKey: key)
    }

    func replace(_ configs: [RunConfig], selected: String?) {
        self.configs = configs
        selectedID = configs.contains { $0.id == selected } ? selected : configs.first?.id
    }

    func directory(of config: RunConfig) -> URL {
        let text = (config.directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if text.isEmpty { return base }
        return text.hasPrefix("/") ? URL(fileURLWithPath: text) : base.appendingPathComponent(text)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func envFileURL(of config: RunConfig) -> URL? {
        let text = config.envFile.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Self.resolve(text, base: directory(of: config))
    }

    static func exports(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return nil }
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return "export \(key)=\(quote(value))"
        }
    }

    func command(for config: RunConfig) -> String {
        let dir = directory(of: config)
        let script = config.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let parameters = config.parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = parameters.isEmpty ? "" : " " + parameters
        let path = (script as NSString).expandingTildeInPath
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        var isDir: ObjCBool = false
        let run: String
        if !script.isEmpty, FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
            let q = Self.quote(file.path)
            let out = Self.quote(NSTemporaryDirectory() + "\(appName)-run-\(config.id)")
            switch file.pathExtension.lowercased() {
            case "py", "pyw": run = "python3 \(q)\(arguments)"
            case "js", "mjs", "cjs": run = "node \(q)\(arguments)"
            case "ts", "mts", "cts", "tsx": run = "npx --yes tsx \(q)\(arguments)"
            case "rb": run = "ruby \(q)\(arguments)"
            case "sh", "bash": run = "bash \(q)\(arguments)"
            case "zsh": run = "zsh \(q)\(arguments)"
            case "swift": run = "swift \(q)\(arguments)"
            case "go": run = "go run \(q)\(arguments)"
            case "php": run = "php \(q)\(arguments)"
            case "pl": run = "perl \(q)\(arguments)"
            case "lua": run = "lua \(q)\(arguments)"
            case "java": run = "java \(q)\(arguments)"
            case "c": run = "clang \(q) -o \(out) && \(out)\(arguments)"
            case "cpp", "cc", "cxx": run = "clang++ -std=c++17 \(q) -o \(out) && \(out)\(arguments)"
            case "rs": run = "rustc \(q) -o \(out) && \(out)\(arguments)"
            default: run = FileManager.default.isExecutableFile(atPath: file.path) ? q + arguments : "open \(q)"
            }
        } else {
            run = script + arguments
        }
        let fileExports = envFileURL(of: config).flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Self.exports) ?? []
        let setup = (fileExports + Self.exports(config.environment)).map { $0 + "\n" }.joined()
        return "\(setup)cd \(Self.quote(dir.path)) && \(run)\ncode=$?; printf '\\n\\033[2m[プロセスは終了コード %d で終了しました]\\033[0m\\n' $code"
    }

    static func resolve(_ text: String, base: URL) -> URL {
        let path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if path.isEmpty { return base }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }
}

private final class PickButton: NSButton {
    private weak var field: NSTextField?
    private var base: URL = URL(fileURLWithPath: "/")
    private var directories = false
    private var relativeTo: (() -> URL)?
    var onPick: (() -> Void)?

    convenience init(field: NSTextField, base: URL, directories: Bool, relativeTo: (() -> URL)? = nil) {
        self.init(title: "選択…", target: nil, action: nil)
        self.field = field
        self.base = base
        self.directories = directories
        self.relativeTo = relativeTo
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pick)
    }

    @objc private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        let start = relativeTo?() ?? base
        panel.directoryURL = start
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = (relativeTo?() ?? base).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root {
            field?.stringValue = directories ? "" : path
        } else if path.hasPrefix(root + "/") {
            field?.stringValue = String(path.dropFirst(root.count + 1))
        } else {
            field?.stringValue = path
        }
        onPick?()
    }
}

final class RunButton: NSView {
    let play: ToolStripButton
    private let menuButton = NSButton()
    var onMenu: ((NSView) -> Void)?

    init(target: AnyObject, action: Selector) {
        play = ToolStripButton(symbol: "play.fill", tip: "実行", target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        menuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "起動構成")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .bold))
        menuButton.isBordered = false
        menuButton.toolTip = "起動構成を選択"
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(play)
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            play.topAnchor.constraint(equalTo: topAnchor),
            play.bottomAnchor.constraint(equalTo: bottomAnchor),
            play.leadingAnchor.constraint(equalTo: leadingAnchor),
            play.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 5),
            menuButton.widthAnchor.constraint(equalToConstant: 12),
            menuButton.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func menuClicked() { onMenu?(menuButton) }
}

final class RunConfigEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: RunnerStore
    private let base: URL
    private let currentFile: String?
    private var drafts: [RunConfig]
    private var row = -1
    private let panel: NSPanel
    private let table = NSTableView()
    private let name = NSTextField()
    private let directory = NSTextField()
    private let script = NSTextField()
    private let environmentScroll = NSTextView.scrollableTextView()
    private var environment: NSTextView { environmentScroll.documentView as! NSTextView }
    private let parameters = NSTextField()
    private let envFile = NSTextField()
    private let form = NSStackView()
    private let empty = NSTextField(labelWithString: "左の「新規作成」から起動構成を作成してください")
    private let deleteButton = NSButton()
    private let newButton = NSButton()

    init(store: RunnerStore, base: URL, currentFile: String?) {
        self.store = store
        self.base = base
        self.currentFile = currentFile
        drafts = store.configs
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "起動構成を編集"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        build()
    }

    @discardableResult
    func run(over parent: NSWindow?) -> Bool {
        panel.paint(.feed)
        table.reloadData()
        select(store.selected.flatMap { selected in drafts.firstIndex { $0.id == selected.id } } ?? (drafts.isEmpty ? -1 : 0))
        if let parent {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2))
        }
        return NSApp.runModal(for: panel) == .OK
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.style = .plain
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.drawsBackground = false
        list.borderType = .lineBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        newButton.title = "新規作成"
        newButton.bezelStyle = .rounded
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.translatesAutoresizingMaskIntoConstraints = false

        name.placeholderString = "起動構成の名前"
        directory.placeholderString = "（プロジェクトのフォルダ）"
        script.placeholderString = "main.py またはコマンド"
        parameters.placeholderString = "--port 8080"
        envFile.placeholderString = ".env"
        [name, directory, script, parameters, envFile].forEach { $0.delegate = self }
        environment.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        environment.isRichText = false
        environment.isAutomaticQuoteSubstitutionEnabled = false
        environment.isAutomaticDashSubstitutionEnabled = false
        environment.isAutomaticTextReplacementEnabled = false
        environment.isAutomaticSpellingCorrectionEnabled = false
        environment.drawsBackground = false
        environment.delegate = self
        environmentScroll.borderType = .bezelBorder
        environmentScroll.translatesAutoresizingMaskIntoConstraints = false
        environmentScroll.drawsBackground = false
        environmentScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        environmentScroll.widthAnchor.constraint(equalToConstant: 310).isActive = true

        let dirPick = PickButton(field: directory, base: base, directories: true)
        let scriptPick = PickButton(field: script, base: base, directories: false, relativeTo: { [weak self] in self?.workingDirectory ?? URL(fileURLWithPath: "/") })
        let envPick = PickButton(field: envFile, base: base, directories: false, relativeTo: { [weak self] in self?.workingDirectory ?? URL(fileURLWithPath: "/") })
        for pick in [dirPick, scriptPick, envPick] { pick.onPick = { [weak self] in self?.sync() } }
        let hint = NSTextField(wrappingLabelWithString: "環境変数は 1 行に KEY=VALUE で書きます。.env ファイルの値より優先します。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [label("名前"), name, NSGridCell.emptyContentView],
            [label("作業ディレクトリ"), directory, dirPick],
            [label("スクリプト"), script, scriptPick],
            [label("スクリプトパラメーター"), parameters, NSGridCell.emptyContentView],
            [label("環境変数"), environmentScroll, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, hint, NSGridCell.emptyContentView],
            [label(".env ファイルのパス"), envFile, envPick],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 310
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(grid)
        form.orientation = .vertical
        form.alignment = .leading
        form.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = "選択された起動構成を削除"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        let save = button("保存して終了", #selector(saveClicked))
        save.keyEquivalent = "\r"
        let discard = button("保存せずに終了", #selector(discardClicked))
        discard.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [deleteButton, spacer, discard, save])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        [list, newButton, form, empty, line, buttons].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            list.widthAnchor.constraint(equalToConstant: 190),
            list.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8),
            newButton.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            newButton.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            newButton.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -12),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            form.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 14),
            form.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            empty.centerXAnchor.constraint(equalTo: form.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    private var workingDirectory: URL { RunnerStore.resolve(directory.stringValue, base: base) }

    private func select(_ index: Int) {
        row = drafts.indices.contains(index) ? index : -1
        let draft = row >= 0 ? drafts[row] : nil
        form.isHidden = draft == nil
        empty.isHidden = draft != nil
        deleteButton.isEnabled = draft != nil
        name.stringValue = draft?.name ?? ""
        directory.stringValue = draft?.directory ?? ""
        script.stringValue = draft?.script ?? ""
        parameters.stringValue = draft?.parameters ?? ""
        environment.string = draft?.environment ?? ""
        envFile.stringValue = draft?.envFile ?? ""
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private func sync() {
        guard drafts.indices.contains(row) else { return }
        drafts[row].name = name.stringValue
        drafts[row].directory = directory.stringValue
        drafts[row].script = script.stringValue
        drafts[row].parameters = parameters.stringValue
        drafts[row].environment = environment.string
        drafts[row].envFile = envFile.stringValue
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    func controlTextDidChange(_ obj: Notification) { sync() }

    func textDidChange(_ notification: Notification) { sync() }

    func numberOfRows(in tableView: NSTableView) -> Int { drafts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = drafts[row].name.trimmingCharacters(in: .whitespaces)
        let label = NSTextField(labelWithString: text.isEmpty ? "（名前なし）" : text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow != row, table.selectedRow >= 0 { select(table.selectedRow) }
    }

    @objc private func newClicked() {
        let menu = NSMenu()
        let plain = NSMenuItem(title: "テンプレートなし", action: #selector(templateClicked(_:)), keyEquivalent: "")
        plain.target = self
        menu.addItem(plain)
        menu.addItem(.separator())
        for (index, template) in RunTemplate.all.enumerated() {
            let item = NSMenuItem(title: template.title, action: #selector(templateClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index + 1
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newButton.bounds.height + 4), in: newButton)
    }

    @objc private func templateClicked(_ sender: NSMenuItem) {
        let made = RunTemplate.all.indices.contains(sender.tag - 1) ? RunTemplate.all[sender.tag - 1].make(current: currentFile)
            : RunConfig(name: "新しい起動構成", directory: "", script: "")
        drafts.append(made)
        table.reloadData()
        select(drafts.count - 1)
        panel.makeFirstResponder(name)
    }

    @objc private func deleteClicked() {
        guard drafts.indices.contains(row) else { return }
        drafts.remove(at: row)
        table.reloadData()
        select(min(row, drafts.count - 1))
    }

    @objc private func saveClicked() {
        sync()
        let selected = drafts.indices.contains(row) ? drafts[row].id : nil
        let saved = drafts.map { draft -> RunConfig in
            var config = draft
            let script = config.script.trimmingCharacters(in: .whitespaces)
            let title = config.name.trimmingCharacters(in: .whitespaces)
            config.name = title.isEmpty ? (script.isEmpty ? "起動構成" : (script as NSString).lastPathComponent) : title
            config.script = script
            config.directory = config.directory.trimmingCharacters(in: .whitespaces)
            config.envFile = config.envFile.trimmingCharacters(in: .whitespaces)
            return config
        }
        store.replace(saved, selected: selected)
        finish(.OK)
    }

    @objc private func discardClicked() { finish(.cancel) }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { NSApp.stopModal(withCode: .cancel) }
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        panel.orderOut(nil)
    }
}
