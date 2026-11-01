import AppKit
@testable import FlareStackIDE

struct RunConfig: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var directory: String
    var script: String
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

    func upsert(_ config: RunConfig) {
        if let i = configs.firstIndex(where: { $0.id == config.id }) { configs[i] = config } else { configs.append(config) }
        selectedID = config.id
    }

    func remove(_ id: String) {
        configs.removeAll { $0.id == id }
        selectedID = configs.first?.id
    }

    func directory(of config: RunConfig) -> URL {
        let text = (config.directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if text.isEmpty { return base }
        return text.hasPrefix("/") ? URL(fileURLWithPath: text) : base.appendingPathComponent(text)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func command(for config: RunConfig) -> String {
        let dir = directory(of: config)
        let script = config.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (script as NSString).expandingTildeInPath
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        var isDir: ObjCBool = false
        let run: String
        if !script.isEmpty, FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
            let q = Self.quote(file.path)
            let out = Self.quote(NSTemporaryDirectory() + "\(appName)-run-\(config.id)")
            switch file.pathExtension.lowercased() {
            case "py", "pyw": run = "python3 \(q)"
            case "js", "mjs", "cjs": run = "node \(q)"
            case "ts", "mts", "cts", "tsx": run = "npx --yes tsx \(q)"
            case "rb": run = "ruby \(q)"
            case "sh", "bash": run = "bash \(q)"
            case "zsh": run = "zsh \(q)"
            case "swift": run = "swift \(q)"
            case "go": run = "go run \(q)"
            case "php": run = "php \(q)"
            case "pl": run = "perl \(q)"
            case "lua": run = "lua \(q)"
            case "java": run = "java \(q)"
            case "c": run = "clang \(q) -o \(out) && \(out)"
            case "cpp", "cc", "cxx": run = "clang++ -std=c++17 \(q) -o \(out) && \(out)"
            case "rs": run = "rustc \(q) -o \(out) && \(out)"
            default: run = FileManager.default.isExecutableFile(atPath: file.path) ? q : "open \(q)"
            }
        } else {
            run = script
        }
        return "cd \(Self.quote(dir.path)) && \(run)\ncode=$?; printf '\\n\\033[2m[プロセスは終了コード %d で終了しました]\\033[0m\\n' $code"
    }

    static func edit(_ config: RunConfig?, base: URL, title: String) -> RunConfig? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "スクリプトはファイル（main.py など）か、そのまま実行するコマンドを指定します。作業ディレクトリが空ならプロジェクトのフォルダで実行します。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        let name = NSTextField(string: config?.name ?? "")
        name.placeholderString = "起動構成の名前"
        let dir = NSTextField(string: config?.directory ?? "")
        dir.placeholderString = "（プロジェクトのフォルダ）"
        let script = NSTextField(string: config?.script ?? "")
        script.placeholderString = "main.py"
        [name, dir, script].forEach { $0.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        let dirPick = PickButton(field: dir, base: base, directories: true)
        let scriptPick = PickButton(field: script, base: base, directories: false, relativeTo: { RunnerStore.resolve(dir.stringValue, base: base) })
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "名前"), name, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "作業ディレクトリ"), dir, dirPick],
            [NSTextField(labelWithString: "スクリプト"), script, scriptPick],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespaces)
        let scriptText = script.stringValue.trimmingCharacters(in: .whitespaces)
        var result = config ?? RunConfig(name: "", directory: "", script: "")
        result.name = trimmed.isEmpty ? (scriptText.isEmpty ? "起動構成" : (scriptText as NSString).lastPathComponent) : trimmed
        result.directory = dir.stringValue.trimmingCharacters(in: .whitespaces)
        result.script = scriptText
        return result
    }

    fileprivate static func resolve(_ text: String, base: URL) -> URL {
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
