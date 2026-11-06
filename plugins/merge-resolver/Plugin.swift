import AppKit
@testable import FlareStackIDE

final class MergeResolverPlugin: NativePlugin {
    static let pluginID = "merge-resolver"
    let id = pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { MergeResolverAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { ConflictFeedAddon(editor: editor) }
}

final class ConflictChoice: NSButton {
    var conflict: Conflict?
    var choice = ConflictScan.Choice.ours
}

final class MergeResolverAddon: NSObject, TextAddon, CommandProviding {
    static let gitChanged = PluginEvent.gitChanged
    private weak var code: CodeEditing?
    private var conflicts: [Conflict] = []
    private var bars: [NSStackView] = []
    private var hadConflicts = false
    private var work: DispatchWorkItem?
    private var monitor: Any?

    init(code: CodeEditing) {
        self.code = code
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: code.textView)
        center.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0) ?? $0 }
        refresh()
    }

    private func color(_ key: String, _ fallback: NSColor) -> NSColor {
        (PluginStore.color(MergeResolverPlugin.pluginID, key) ?? fallback).withAlphaComponent(0.22)
    }

    @objc private func refresh() {
        guard let textView = code?.textView else { return }
        conflicts = ConflictScan.scan(textView.string as NSString)
        var marks: [(range: NSRange, color: NSColor)] = []
        for conflict in conflicts {
            marks += conflict.markers.map { ($0, NSColor.gray.withAlphaComponent(0.18)) }
            marks.append((conflict.ours, color("oursColor", .systemGreen)))
            if let base = conflict.base { marks.append((base, NSColor.gray.withAlphaComponent(0.1))) }
            marks.append((conflict.theirs, color("theirsColor", .systemBlue)))
        }
        CodeView.setBackgrounds(marks, owner: MergeResolverPlugin.pluginID, in: textView)
        place()
        if hadConflicts, conflicts.isEmpty { resolvedAll() }
        hadConflicts = !conflicts.isEmpty
    }

    private func button(_ title: String, _ choice: ConflictScan.Choice, _ conflict: Conflict) -> ConflictChoice {
        let button = ConflictChoice(title: title, target: self, action: #selector(chosen(_:)))
        button.choice = choice
        button.conflict = conflict
        button.controlSize = .mini
        button.font = .systemFont(ofSize: 10)
        button.bezelStyle = .inline
        return button
    }

    @objc private func place() {
        guard let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        bars.forEach { $0.removeFromSuperview() }
        bars = []
        let origin = textView.textContainerOrigin
        let length = (textView.string as NSString).length
        for conflict in conflicts where NSMaxRange(conflict.header) <= length {
            let glyphs = layout.glyphRange(forCharacterRange: conflict.header, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let bar = NSStackView(views: [button("自分の変更", .ours, conflict), button("相手の変更", .theirs, conflict), button("両方", .both, conflict)])
            bar.spacing = 4
            let size = bar.fittingSize
            bar.frame = NSRect(x: origin.x + used.maxX + 12, y: origin.y + rect.minY + (rect.height - size.height) / 2,
                               width: size.width, height: size.height)
            textView.addSubview(bar)
            bars.append(bar)
        }
    }

    @objc private func chosen(_ sender: ConflictChoice) {
        guard let conflict = sender.conflict else { return }
        resolve(conflict, sender.choice)
    }

    private func resolve(_ conflict: Conflict, _ choice: ConflictScan.Choice) {
        guard let textView = code?.textView, let storage = textView.textStorage,
              NSMaxRange(conflict.whole) <= storage.length else { return }
        let replacement = ConflictScan.resolution(conflict, choice, in: storage.string as NSString)
        guard textView.shouldChangeText(in: conflict.whole, replacementString: replacement) else { return }
        storage.replaceCharacters(in: conflict.whole, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName("競合の解決")
        textView.setSelectedRange(NSRange(location: conflict.whole.location, length: 0))
        refresh()
    }

    private func resolvedAll() {
        guard let url = code?.fileURL else { return }
        let window = code?.textView.window
        Toasts.post("\(url.lastPathComponent) の競合をすべて解決しました", message: "保存してステージすると解決済みになります",
                    actions: [("保存してステージ", { [weak self] in self?.stage(url) })], in: window)
    }

    private func stage(_ url: URL) {
        let editor = code?.textView.window?.windowController as? EditorWindowController
        if let error = editor?.saveAll() { return editor?.showError(error) ?? () }
        let dir = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Git.run(["--literal-pathspecs", "add", "--", url.lastPathComponent], in: dir) != nil
            DispatchQueue.main.async {
                if !ok { Toasts.post("ステージに失敗しました", message: url.lastPathComponent) }
                editor?.refreshGit()
                NotificationCenter.default.post(name: Self.gitChanged, object: nil)
            }
        }
    }

    private func current() -> Conflict? {
        guard let textView = code?.textView else { return nil }
        let caret = textView.selectedRange().location
        return conflicts.first { NSLocationInRange(caret, $0.whole) || caret == NSMaxRange($0.whole) }
    }

    private func jump(_ forward: Bool) {
        guard let textView = code?.textView, !conflicts.isEmpty else { return }
        let caret = textView.selectedRange().location
        let target = forward ? conflicts.first { $0.whole.location > caret } ?? conflicts[0]
            : conflicts.last { NSMaxRange($0.whole) < caret } ?? conflicts[conflicts.count - 1]
        textView.setSelectedRange(NSRange(location: target.header.location, length: 0))
        CodeView.center(textView, on: target.header)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let textView = code?.textView, event.window === textView.window, textView.window?.firstResponder === textView,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option] else { return event }
        switch event.charactersIgnoringModifiers {
        case "]": jump(true)
        case "[": jump(false)
        default: return event
        }
        return nil
    }

    var commands: [PaletteCommand] {
        guard !conflicts.isEmpty else { return [] }
        let apply: (ConflictScan.Choice) -> () -> Void = { [weak self] choice in
            { [weak self] in
                guard let self, let conflict = self.current() ?? self.conflicts.first else { return }
                self.resolve(conflict, choice)
            }
        }
        return [
            PaletteCommand(id: "merge-resolver.next", title: "競合: 次の競合へ", detail: "⌥⌘]") { [weak self] in self?.jump(true) },
            PaletteCommand(id: "merge-resolver.previous", title: "競合: 前の競合へ", detail: "⌥⌘[") { [weak self] in self?.jump(false) },
            PaletteCommand(id: "merge-resolver.ours", title: "競合: 自分の変更を採用", perform: apply(.ours)),
            PaletteCommand(id: "merge-resolver.theirs", title: "競合: 相手の変更を採用", perform: apply(.theirs)),
            PaletteCommand(id: "merge-resolver.both", title: "競合: 両方を残す", perform: apply(.both)),
        ]
    }

    func textChanged() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func fileOpened() {
        hadConflicts = false
        refresh()
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        bars.forEach { $0.removeFromSuperview() }
        bars = []
        if let textView = code?.textView { CodeView.setBackgrounds([], owner: MergeResolverPlugin.pluginID, in: textView) }
    }
}

final class ConflictFeedAddon: NSObject, WindowAddon, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var feed: FeedView?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "競合しているファイルはありません")
    private var files: [String] = []
    private var top: URL?
    private var work: DispatchWorkItem?
    private var generation = 0

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "arrow.triangle.merge", tip: "マージ競合", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: MergeResolverPlugin.pluginID)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: MergeResolverAddon.gitChanged, object: nil)
        center.addObserver(self, selector: #selector(reload), name: NSWindow.didBecomeKeyNotification, object: editor.window)
        center.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        applySettings()
        reload()
    }

    @objc private func applySettings() {
        button.isHidden = !Settings.gitEnabled
        if !Settings.gitEnabled, let feed, !feed.isHidden { editor?.hideBottom(feed) }
    }

    @objc private func toggle() {
        guard let editor else { return }
        let feed = self.feed ?? makeFeed(editor)
        editor.toggleBottom(feed)
        reload()
    }

    private func makeFeed(_ editor: EditorWindowController) -> FeedView {
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.headerView = nil
        table.rowSizeStyle = .small
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let made = FeedView(title: "マージ競合", content: content)
        made.onRemove = { [weak self] in self?.toggle() }
        editor.addFeed(made, button: button)
        feed = made
        return made
    }

    @objc private func reload() {
        guard let editor, Settings.gitEnabled else { return }
        generation += 1
        let current = generation
        let dir = editor.baseDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let root = Git.run(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let list = root.flatMap { Git.run(["diff", "--name-only", "--diff-filter=U"], in: URL(fileURLWithPath: $0)) }?
                .split(separator: "\n").map(String.init) ?? []
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.top = root.map { URL(fileURLWithPath: $0) }
                self.files = list
                self.button.toolTip = list.isEmpty ? "マージ競合" : "マージ競合（\(list.count) 件）"
                self.button.contentTintColor = list.isEmpty ? nil : .systemOrange
                self.feed?.title = list.isEmpty ? "マージ競合" : "マージ競合（残り \(list.count) 件）"
                self.empty.isHidden = !list.isEmpty
                self.table.reloadData()
            }
        }
    }

    func textChanged() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    @objc private func rowClicked() {
        guard files.indices.contains(table.clickedRow), let top, let editor else { return }
        let url = top.appendingPathComponent(files[table.clickedRow])
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        editor.open(url)
        if let first = ConflictScan.scan(editor.textView.string as NSString).first { editor.reveal(url, range: first.header) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: files[row])
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        return stack
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(MergeResolverPlugin()) }
