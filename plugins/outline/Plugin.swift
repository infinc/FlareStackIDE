import AppKit
@testable import FlareStackIDE

final class OutlinePlugin: NativePlugin {
    let id = OutlineAddon.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { OutlineAddon(editor: editor) }
}

final class OutlineAddon: NSObject, WindowAddon, CommandProviding {
    static let pluginID = "outline"
    private static let scanQueue = DispatchQueue(label: "\(appName).outline.scan", qos: .userInitiated)
    private weak var editor: EditorWindowController?
    private let list = OutlineView()
    private var button: ToolStripButton!
    private var feed: FeedView?
    private var refreshWork: DispatchWorkItem?
    private var fallbackWork: DispatchWorkItem?
    private var selectionWork: DispatchWorkItem?
    private var token = 0
    private var shownURL: URL?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "list.bullet.indent", tip: "アウトライン", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: Self.pluginID)
        list.onSelect = { [weak self] in self?.jump(to: $0) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(symbolsArrived(_:)), name: PluginEvent.symbols, object: nil)
        center.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    private var visible: Bool { feed.map { !$0.isHidden && $0.window != nil } ?? false }

    @objc private func toggle() {
        guard let editor else { return }
        let feed = self.feed ?? {
            let made = FeedView(title: "アウトライン", content: list)
            made.onRemove = { [weak self] in self?.toggle() }
            editor.addFeed(made, button: button)
            self.feed = made
            return made
        }()
        editor.toggleBottom(feed)
        if visible { refresh() }
    }

    var commands: [PaletteCommand] {
        [PaletteCommand(id: "outline.open", title: "アウトライン: 開く / 閉じる", detail: "アイコン列") { [weak self] in self?.toggle() }]
    }

    func fileOpened() {
        guard visible else { return }
        refresh()
    }

    func textChanged() {
        guard visible else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func refresh() {
        refreshWork?.cancel()
        fallbackWork?.cancel()
        token += 1
        guard let editor, let url = editor.fileURL?.standardizedFileURL, url.isFileURL else {
            shownURL = nil
            return list.show([])
        }
        let current = token
        let fallback = DispatchWorkItem { [weak self] in self?.scan(url, token: current) }
        fallbackWork = fallback
        NotificationCenter.default.post(name: PluginEvent.symbolsRequest, object: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fallback)
    }

    @objc private func symbolsArrived(_ note: Notification) {
        guard visible, let url = note.object as? URL, url == editor?.fileURL?.standardizedFileURL,
              let items = note.userInfo?["items"] as? [[String: Any]], !items.isEmpty else { return }
        fallbackWork?.cancel()
        var symbols = items.compactMap { OutlineSymbol(lsp: $0) }
        if symbols.allSatisfy({ $0.children.isEmpty }) { symbols = OutlineSymbol.nest(symbols) }
        show(symbols, for: url)
    }

    private func scan(_ url: URL, token: Int) {
        guard let text = editor?.textView.string else { return }
        let ext = url.pathExtension.lowercased()
        Self.scanQueue.async { [weak self] in
            let symbols = OutlineScan.scan(text, ext: ext)
            DispatchQueue.main.async {
                guard let self, self.token == token else { return }
                self.show(symbols, for: url)
            }
        }
    }

    private func show(_ symbols: [OutlineSymbol], for url: URL) {
        shownURL = url
        list.show(symbols)
        if let caret = editor?.textView.selectedRange().location { list.reveal(caret) }
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard visible, let textView = editor?.textView, note.object as? NSTextView === textView,
              shownURL == editor?.fileURL?.standardizedFileURL else { return }
        selectionWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let textView else { return }
            self?.list.reveal(textView.selectedRange().location)
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func jump(to symbol: OutlineSymbol) {
        guard let editor, let url = shownURL else { return }
        let text = editor.textView.string as NSString
        let location = min(symbol.selection, text.length)
        let length = text.length >= location + (symbol.name as NSString).length
            && text.substring(with: NSRange(location: location, length: (symbol.name as NSString).length)) == symbol.name
            ? (symbol.name as NSString).length : 0
        editor.reveal(url, range: NSRange(location: location, length: length))
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        refreshWork?.cancel()
        fallbackWork?.cancel()
        selectionWork?.cancel()
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(OutlinePlugin()) }
