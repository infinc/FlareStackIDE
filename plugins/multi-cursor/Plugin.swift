import AppKit
@testable import FlareStackIDE

final class MultiCursorPlugin: NativePlugin {
    let id = MultiCursorAddon.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { MultiCursorAddon(editor: editor) }
}

struct RefactorHit {
    let url: URL
    let range: NSRange
}

enum RefactorSearch {
    static let maxFileSize = 1_000_000

    static func ranges(of query: String, in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var position = 0
        while position < text.length {
            let found = text.range(of: query, options: .literal, range: NSRange(location: position, length: text.length - position))
            guard found.location != NSNotFound else { break }
            result.append(found)
            position = NSMaxRange(found)
        }
        return result
    }

    static func text(of url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize, let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class RefactorView: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let scope = NSPopUpButton()
    let countLabel = NSTextField(labelWithString: "0 件")
    let replaceField = NSTextField()
    private(set) var previous: NSButton!
    private(set) var next: NSButton!
    let replaceButton = NSButton(title: "リファクタリング", target: nil, action: nil)
    var onSearch: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onReplace: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        searchField.placeholderString = "検索する文字列"
        searchField.delegate = self
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        searchField.sendsSearchStringImmediately = true
        scope.addItems(withTitles: ["現在開いているファイル", "全てのファイル"])
        scope.target = self
        scope.action = #selector(searchChanged)
        scope.controlSize = .small
        previous = FeedView.barButton(symbol: "chevron.left", tip: "前へ", target: self, action: #selector(previousClicked))
        next = FeedView.barButton(symbol: "chevron.right", tip: "次へ", target: self, action: #selector(nextClicked))
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        replaceField.placeholderString = "変換後の文字列"
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        replaceButton.bezelStyle = .rounded
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!)
        arrow.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [searchField, scope, countLabel, previous, next, arrow, replaceField, replaceButton])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onClose?() } else { onSearch?() }
    }

    var allFiles: Bool { scope.indexOfSelectedItem == 1 }

    func controlTextDidChange(_ obj: Notification) { onSearch?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onMove?(1)
        return true
    }

    @objc private func searchChanged() { onSearch?() }
    @objc private func previousClicked() { onMove?(-1) }
    @objc private func nextClicked() { onMove?(1) }
    @objc private func replaceClicked() { onReplace?() }
}

final class MultiCursorAddon: NSObject, WindowAddon {
    static let pluginID = "multi-cursor"
    private static let height: CGFloat = 76
    private weak var editor: EditorWindowController?
    private let button = NSButton()
    private let view = RefactorView()
    private var hits: [RefactorHit] = []
    private var index = -1
    private var generation = 0
    private var work: DispatchWorkItem?
    private lazy var feed: FeedView = {
        let made = FeedView(title: "リファクタリング", content: view)
        made.onRemove = { [weak self] in self?.toggle() }
        return made
    }()

    private var isOpen: Bool { view.window != nil }

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button.image = EditorWindowController.cloudImage("character.cursor.ibeam")
        button.isBordered = false
        button.toolTip = "リファクタリング"
        button.target = self
        button.action = #selector(toggle)
        editor.addTopButton(button)
        view.onSearch = { [weak self] in self?.search() }
        view.onMove = { [weak self] in self?.move($0) }
        view.onReplace = { [weak self] in self?.replaceAll() }
        view.onClose = { [weak self] in self?.clearMarks() }
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: .settingsChanged, object: nil)
    }

    @objc private func toggle() {
        guard let editor else { return }
        editor.toggleTopFeed(feed, height: Self.height)
        if isOpen { editor.window?.makeFirstResponder(view.searchField) }
    }

    private func targets() -> [URL] {
        guard let editor else { return [] }
        guard view.allFiles, let base = editor.projectDirectory else { return editor.fileURL.map { [$0] } ?? [] }
        return Array(Set(ProjectSearch.files(in: base) + editor.openTexts.map(\.url)))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func search() {
        generation += 1
        let token = generation
        guard let editor, isOpen else { return }
        let query = view.searchField.stringValue
        guard !query.isEmpty else { return finish([]) }
        let open = Dictionary(editor.openTexts, uniquingKeysWith: { a, _ in a })
        let urls = targets()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = urls.flatMap { url -> [RefactorHit] in
                guard let text = open[url] ?? RefactorSearch.text(of: url) else { return [] }
                return RefactorSearch.ranges(of: query, in: text as NSString).map { RefactorHit(url: url, range: $0) }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.finish(found)
            }
        }
    }

    private func finish(_ found: [RefactorHit]) {
        hits = found
        index = -1
        updateCount()
        paint()
    }

    private func updateCount() {
        view.countLabel.stringValue = index >= 0 ? "\(index + 1) / \(hits.count) 件" : "\(hits.count) 件"
    }

    @objc private func paint() {
        guard let editor else { return }
        let color = (PluginStore.color(Self.pluginID, "highlightColor") ?? .systemYellow).withAlphaComponent(0.45)
        let mine = isOpen ? hits.filter { $0.url == editor.fileURL }.map { (range: $0.range, color: color) } : []
        CodeView.setBackgrounds(mine, owner: Self.pluginID, in: editor.textView)
    }

    private func clearMarks() {
        generation += 1
        work?.cancel()
        hits = []
        index = -1
        updateCount()
        if let textView = editor?.textView { CodeView.setBackgrounds([], owner: Self.pluginID, in: textView) }
    }

    private func move(_ step: Int) {
        guard !hits.isEmpty else { return }
        index = index < 0 ? (step > 0 ? 0 : hits.count - 1) : (index + step + hits.count) % hits.count
        updateCount()
        editor?.reveal(hits[index].url, range: hits[index].range)
        paint()
    }

    private func replaceAll() {
        guard let editor, !hits.isEmpty else { return }
        let query = view.searchField.stringValue, replacement = view.replaceField.stringValue
        guard query != replacement else { return }
        if let error = editor.saveAll() { return editor.showError(error) }
        var originals: [URL: String] = [:]
        for url in Set(hits.map(\.url)) {
            guard let text = RefactorSearch.text(of: url) else { continue }
            do {
                try text.replacingOccurrences(of: query, with: replacement, options: .literal).write(to: url, atomically: false, encoding: .utf8)
                originals[url] = text
            } catch {
                editor.showError(error)
                break
            }
        }
        let count = hits.filter { originals[$0.url] != nil }.count
        reload(Array(originals.keys))
        Toasts.post("\(count) 件を変換しました", message: "\(originals.count) ファイル", actions: [("元に戻す", { [weak self] in self?.restore(originals) })], in: editor.window)
    }

    private func restore(_ originals: [URL: String]) {
        guard let editor else { return }
        if let error = editor.saveAll() { return editor.showError(error) }
        for (url, text) in originals {
            do {
                try text.write(to: url, atomically: false, encoding: .utf8)
            } catch {
                editor.showError(error)
            }
        }
        reload(Array(originals.keys))
    }

    private func reload(_ urls: [URL]) {
        guard let editor else { return }
        editor.reloadExternal(Set(urls.map(\.standardizedFileURL.path)))
        search()
    }

    func fileOpened() { paint() }

    func textChanged() {
        guard isOpen else { return }
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.search() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        editor?.removeTopFeed(feed)
        clearMarks()
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(MultiCursorPlugin()) }
