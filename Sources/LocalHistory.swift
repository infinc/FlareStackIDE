import AppKit
import CryptoKit

enum LocalHistory {
    struct Entry {
        let file: URL
        let date: Date
        let size: Int
    }

    static let maxEntries = 50
    static let maxBytes = 2_000_000
    static let mergeInterval: TimeInterval = 30
    private static let enabledKey = "LocalHistory.Projects"
    private static let queue = DispatchQueue(label: "FlareStackIDE.LocalHistory", qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("History")
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    private static var enabledProjects: [String] { UserDefaults.standard.stringArray(forKey: enabledKey) ?? [] }

    static func isEnabled(_ project: String) -> Bool { enabledProjects.contains(standard(project)) }

    static func setEnabled(_ project: String, _ on: Bool) {
        var list = enabledProjects.filter { $0 != standard(project) }
        if on { list.append(standard(project)) }
        UserDefaults.standard.set(list, forKey: enabledKey)
    }

    private static func owner(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return enabledProjects.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    static func isTracked(_ url: URL) -> Bool { owner(of: url) != nil }

    private static func projectFolder(_ project: String) -> URL { directory.appendingPathComponent(hash(standard(project))) }

    private static func folder(for url: URL, project: String) -> URL {
        let path = url.standardizedFileURL.path
        let relative = path == project ? url.lastPathComponent : String(path.dropFirst(project.count + 1))
        return projectFolder(project).appendingPathComponent(hash(relative))
    }

    static func record(_ url: URL, data: Data, merge: Bool = true) {
        guard data.count <= maxBytes, let project = owner(of: url) else { return }
        let target = folder(for: url, project: project)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            try? Data(project.utf8).write(to: projectFolder(project).appendingPathComponent("project.txt"))
            try? Data(url.standardizedFileURL.path.utf8).write(to: target.appendingPathComponent("path.txt"))
            let existing = snapshots(in: target)
            if let last = existing.first {
                if (try? Data(contentsOf: last.file)) == data { return }
                if merge, Date().timeIntervalSince(last.date) < mergeInterval { try? fm.removeItem(at: last.file) }
            }
            try? data.write(to: target.appendingPathComponent(stamp.string(from: Date()) + ".snap"))
            for old in snapshots(in: target).dropFirst(maxEntries) { try? fm.removeItem(at: old.file) }
        }
    }

    private static func snapshots(in folder: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "snap" }.compactMap { file in
            guard let date = stamp.date(from: file.deletingPathExtension().lastPathComponent) else { return nil }
            return Entry(file: file, date: date, size: (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }.sorted { $0.date > $1.date }
    }

    static func entries(for url: URL) -> [Entry] {
        guard let project = owner(of: url) else { return [] }
        return queue.sync { snapshots(in: folder(for: url, project: project)) }
    }

    static func usage(of project: String) -> Int64 {
        let folder = projectFolder(project)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func show(_ url: URL, editor: EditorWindowController) {
        LocalHistoryWindow.show(url, over: editor.window) { [weak editor] data in editor?.restoreHistory(data, to: url) }
    }

    static func clear(_ project: String) {
        queue.sync { _ = try? FileManager.default.removeItem(at: projectFolder(project)) }
    }
}

final class LocalHistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [LocalHistoryWindow] = []
    private let url: URL
    private let onRestore: (Data) -> Void
    private let panel: NSPanel
    private let table = NSTableView()
    private let preview = NSTextView()
    private let restore = NSButton(title: "この版に戻す", target: nil, action: nil)
    private var entries: [LocalHistory.Entry] = []
    private let relative: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func show(_ url: URL, over parent: NSWindow?, onRestore: @escaping (Data) -> Void) {
        let window = LocalHistoryWindow(url: url, onRestore: onRestore)
        open.append(window)
        window.present(over: parent)
    }

    private init(url: URL, onRestore: @escaping (Data) -> Void) {
        self.url = url
        self.onRestore = onRestore
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "ローカル履歴 — \(url.lastPathComponent)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 520, height: 320)
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: panel)
        build()
        reload()
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("date"))
        column.title = "保存した日時"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 34
        table.style = .inset
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.translatesAutoresizingMaskIntoConstraints = false
        preview.isEditable = false
        preview.isRichText = false
        preview.font = Settings.font
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.isHorizontallyResizable = true
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.textContainer?.widthTracksTextView = false
        preview.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let text = NSScrollView()
        text.documentView = preview
        text.hasVerticalScroller = true
        text.hasHorizontalScroller = true
        text.borderType = .bezelBorder
        text.translatesAutoresizingMaskIntoConstraints = false
        restore.bezelStyle = .rounded
        restore.target = self
        restore.action = #selector(restoreClicked)
        restore.isEnabled = false
        restore.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(labelWithString: "戻す前の内容も履歴に残ります")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        [list, text, restore, note].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            list.widthAnchor.constraint(equalToConstant: 230),
            list.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            text.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            restore.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            note.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
        ])
        panel.contentView = content
    }

    private func present(over parent: NSWindow?) {
        panel.paint(.feed)
        if let parent {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        entries = LocalHistory.entries(for: url)
        table.reloadData()
        if entries.isEmpty {
            preview.string = "まだ履歴はありません。ファイルを保存すると、ここに版が並びます。"
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func closed() {
        NotificationCenter.default.removeObserver(self)
        Self.open.removeAll { $0 === self }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let title = NSTextField(labelWithString: relative.string(from: entry.date))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        restore.isEnabled = entries.indices.contains(row)
        guard entries.indices.contains(row), let data = try? Data(contentsOf: entries[row].file) else { return }
        preview.string = TextFile.read(data)?.text ?? "（テキストとして表示できません）"
        preview.font = Settings.font
    }

    @objc private func restoreClicked() {
        let row = table.selectedRow
        guard entries.indices.contains(row), let data = try? Data(contentsOf: entries[row].file) else { return }
        onRestore(data)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload() }
    }
}

final class ProjectSettingsView: NSView {
    private let project: Project
    private let history = NSButton(checkboxWithTitle: "ローカル履歴を保存する", target: nil, action: nil)
    private let usage = NSTextField(labelWithString: "")
    private let clear = NSButton(title: "履歴を削除…", target: nil, action: nil)

    init(project: Project) {
        self.project = project
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        let title = NSTextField(labelWithString: project.name)
        title.font = .systemFont(ofSize: 15, weight: .bold)
        let path = NSTextField(labelWithString: project.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let section = NSTextField(labelWithString: "ローカル履歴")
        section.font = .systemFont(ofSize: 12, weight: .semibold)
        history.target = self
        history.action = #selector(historyChanged)
        let note = NSTextField(wrappingLabelWithString: "保存のたびにファイルの版を残し、タブやディレクトリの右クリック「ローカル履歴…」から戻せます。Git を使っていないプロジェクトでも使えます（\(Int(LocalHistory.mergeInterval)) 秒以内の保存は1つにまとめ、1ファイルあたり最新 \(LocalHistory.maxEntries) 件まで）。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        usage.font = .systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        clear.target = self
        clear.action = #selector(clearClicked)
        let usageRow = NSStackView(views: [usage, clear])
        usageRow.spacing = 10
        let stack = NSStackView(views: [title, path, section, history, note, usageRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: path)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(load), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func load() {
        history.state = LocalHistory.isEnabled(project.path) ? .on : .off
        let bytes = LocalHistory.usage(of: project.path)
        usage.stringValue = "使用量: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        clear.isEnabled = bytes > 0
    }

    @objc private func historyChanged() {
        LocalHistory.setEnabled(project.path, history.state == .on)
        load()
    }

    @objc private func clearClicked() {
        let alert = NSAlert()
        alert.messageText = "「\(project.name)」のローカル履歴を削除しますか？"
        alert.informativeText = "保存してある版がすべて消え、元に戻せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        LocalHistory.clear(project.path)
        load()
    }
}
