import AppKit
@testable import FlareStackIDE

final class BookmarksPlugin: NativePlugin {
    let id = "bookmarks"
    func textAddon(for code: CodeEditing) -> TextAddon? { BookmarksAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { BookmarksFeedAddon(editor: editor) }
}

final class BookmarkStore {
    static let changed = Notification.Name("Bookmarks.changed")
    private static var stores: [String: BookmarkStore] = [:]
    private let base: URL
    private let key: String
    private var items: [String: Set<Int>]

    static func shared(base: URL) -> BookmarkStore {
        if let store = stores[base.path] { return store }
        let store = BookmarkStore(base: base)
        stores[base.path] = store
        return store
    }

    private init(base: URL) {
        self.base = base
        key = "Bookmarks.\(base.path)"
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        items = saved.mapValues(Set.init)
    }

    private func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, root = base.standardizedFileURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    func lines(_ url: URL) -> Set<Int> { items[relative(url)] ?? [] }

    func set(_ lines: Set<Int>, for url: URL) {
        let name = relative(url)
        guard (items[name] ?? []) != lines else { return }
        items[name] = lines.isEmpty ? nil : lines
        UserDefaults.standard.set(items.mapValues { $0.sorted() }, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func clear() {
        items = [:]
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    var all: [(url: URL, line: Int)] {
        items.keys.sorted().flatMap { name -> [(url: URL, line: Int)] in
            let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : base.appendingPathComponent(name)
            return items[name]!.sorted().map { (url, $0) }
        }
    }
}

final class BookmarksAddon: NSObject, TextAddon {
    static let marks = Notification.Name("FlareStackIDE.bookmarks")
    static let marksRequest = Notification.Name("FlareStackIDE.bookmarksRequest")
    static let rulerClicked = Notification.Name("FlareStackIDE.rulerClicked")
    static let live = NSHashTable<BookmarksAddon>.weakObjects()

    private weak var code: CodeEditing?
    private var starts = [0]
    private var monitor: Any?

    init(code: CodeEditing) {
        self.code = code
        super.init()
        Self.live.add(self)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(edited(_:)), name: NSTextStorage.didProcessEditingNotification, object: code.textView.textStorage)
        center.addObserver(self, selector: #selector(publish), name: Self.marksRequest, object: code.textView)
        center.addObserver(self, selector: #selector(rulerClicked(_:)), name: Self.rulerClicked, object: code.textView)
        center.addObserver(self, selector: #selector(publish), name: BookmarkStore.changed, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0) ?? $0 }
        reloadStarts()
        publish()
    }

    private var store: BookmarkStore? {
        guard let code else { return nil }
        return (code.projectDirectory ?? code.fileURL?.deletingLastPathComponent()).map(BookmarkStore.shared)
    }

    var fileURL: URL? { code?.fileURL }

    var window: NSWindow? { code?.textView.window }

    private static func lineStarts(_ text: NSString) -> [Int] {
        var result = [0]
        var i = 0
        while i < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: text.length - i))
            if found.location == NSNotFound { break }
            result.append(found.location + 1)
            i = found.location + 1
        }
        return result
    }

    private func reloadStarts() { starts = Self.lineStarts((code?.textView.string ?? "") as NSString) }

    private func lineIndex(_ location: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    @objc private func edited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        defer { reloadStarts() }
        guard let url = code?.fileURL, let store else { return }
        let range = storage.editedRange
        let oldLength = storage.length - storage.changeInLength
        let oldCount = range.length - storage.changeInLength
        guard !(range.location == 0 && oldCount >= oldLength) else { return }
        let oldEnd = range.location + oldCount
        let first = lineIndex(range.location), last = lineIndex(oldEnd)
        let added = (storage.string as NSString).substring(with: range).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let removed = last - first
        guard added != 0 || removed != 0 else { return }
        let startsLine = starts[first] == range.location
        let endsAtLine = starts[last] == oldEnd
        let moved = store.lines(url).compactMap { mark -> Int? in
            let index = mark - 1
            if index < first { return mark }
            if index == first {
                if removed == 0 { return startsLine ? mark + added : mark }
                return startsLine && endsAtLine && added == 0 ? nil : mark
            }
            if index < last { return nil }
            if index == last { return endsAtLine ? mark + added - removed : nil }
            return mark + added - removed
        }
        store.set(Set(moved), for: url)
    }

    @objc private func publish() {
        guard let textView = code?.textView else { return }
        let lines: Set<Int> = code?.fileURL.flatMap { url in store?.lines(url).filter { $0 <= starts.count } } ?? []
        NotificationCenter.default.post(name: Self.marks, object: textView, userInfo: ["lines": lines])
    }

    private func toggle(_ line: Int) {
        guard let url = code?.fileURL, let store else { return }
        var lines = store.lines(url)
        if lines.remove(line) == nil { lines.insert(line) }
        store.set(lines, for: url)
    }

    @objc private func rulerClicked(_ note: Notification) {
        guard note.userInfo?["zone"] as? String == "line", let line = note.userInfo?["line"] as? Int else { return }
        toggle(line)
    }

    func jump(to line: Int) {
        guard let textView = code?.textView else { return }
        let index = min(max(line - 1, 0), starts.count - 1)
        textView.window?.makeFirstResponder(textView)
        let target = NSRange(location: starts[index], length: 0)
        textView.setSelectedRange(target)
        CodeView.center(textView, on: target)
    }

    private func step(_ forward: Bool) {
        guard let textView = code?.textView, let url = code?.fileURL, let store else { return }
        let lines = store.lines(url).filter { $0 <= starts.count }.sorted()
        guard let firstLine = lines.first, let lastLine = lines.last else { return }
        let here = lineIndex(textView.selectedRange().location) + 1
        jump(to: forward ? lines.first { $0 > here } ?? firstLine : lines.last { $0 < here } ?? lastLine)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let textView = code?.textView, event.window === textView.window, event.window?.firstResponder === textView,
              event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option] else { return event }
        switch event.keyCode {
        case 11: toggle(lineIndex(textView.selectedRange().location) + 1)
        case 125: step(true)
        case 126: step(false)
        default: return event
        }
        return nil
    }

    func fileOpened() {
        reloadStarts()
        publish()
    }

    func detach() {
        Self.live.remove(self)
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let textView = code?.textView {
            NotificationCenter.default.post(name: Self.marks, object: textView, userInfo: ["lines": Set<Int>()])
        }
    }
}

final class BookmarksList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let url: URL
        let line: Int
        let code: String
    }

    var onSelect: ((Item) -> Void)?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "ブックマークはありません")
    private var items: [Item] = []

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("file", "ファイル", 200.0), ("line", "行", 60.0), ("code", "コード", 480.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.backgroundColor = .clear
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [Item]) {
        self.items = items
        empty.isHidden = !items.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let text = id == "file" ? item.url.lastPathComponent : id == "line" ? "\(item.line)" : item.code
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = id == "code" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.textColor = id == "file" ? .labelColor : .secondaryLabelColor
        label.toolTip = id == "file" ? item.url.path : text
        return label
    }

    @objc private func rowClicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        onSelect?(items[table.clickedRow])
    }
}

final class BookmarksFeedAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private let store: BookmarkStore
    private let list = BookmarksList()
    private var button: ToolStripButton!
    private var feed: FeedView?

    init(editor: EditorWindowController) {
        self.editor = editor
        store = BookmarkStore.shared(base: editor.baseDirectory)
        super.init()
        button = ToolStripButton(symbol: "bookmark", tip: "ブックマーク", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: "bookmarks")
        list.onSelect = { [weak self] in self?.open($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: BookmarkStore.changed, object: store)
    }

    @objc private func toggle() {
        guard let editor else { return }
        let feed = self.feed ?? {
            let clear = FeedView.barButton(symbol: "trash", tip: "すべて削除", target: self, action: #selector(clearAll))
            let made = FeedView(title: "ブックマーク", content: list, extras: [clear])
            made.onRemove = { [weak self] in self?.toggle() }
            editor.addFeed(made, button: button)
            self.feed = made
            return made
        }()
        reload()
        editor.toggleBottom(feed)
    }

    @objc private func reload() {
        guard let editor, feed != nil else { return }
        var texts: [URL: [Substring]] = [:]
        let open = Dictionary(editor.openTexts.map { ($0.url, $0.text) }, uniquingKeysWith: { first, _ in first })
        list.show(store.all.map { url, line in
            if texts[url] == nil {
                let text = open[url] ?? CodeView.diskText(url) ?? ""
                texts[url] = text.split(separator: "\n", omittingEmptySubsequences: false)
            }
            let lines = texts[url] ?? []
            let code = line <= lines.count ? lines[line - 1].trimmingCharacters(in: .whitespaces) : ""
            return BookmarksList.Item(url: url, line: line, code: code)
        })
    }

    private func addon(for url: URL) -> BookmarksAddon? {
        BookmarksAddon.live.allObjects.first { $0.fileURL == url && $0.window === editor?.window }
    }

    private func open(_ item: BookmarksList.Item) {
        guard let editor, FileManager.default.fileExists(atPath: item.url.path) else { return }
        if let addon = addon(for: item.url) { return addon.jump(to: item.line) }
        editor.open(item.url)
        addon(for: item.url)?.jump(to: item.line)
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "ブックマークをすべて削除しますか？"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn { store.clear() }
    }

    func textChanged() {
        if feed?.isHidden == false { reload() }
    }

    func fileOpened() {
        if feed?.isHidden == false { reload() }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(BookmarksPlugin()) }
