import AppKit
@testable import FlareStackIDE

final class CodeScannerPlugin: NativePlugin {
    let id = CodeScanner.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? {
        CodeScanner.make().map { CodeScannerAddon(editor: editor, scanner: $0) }
    }
    func textAddon(for code: CodeEditing) -> TextAddon? {
        guard let pane = code as? SplitPane else { return nil }
        return CodeScanner.make().map { SplitScannerAddon(pane: pane, scanner: $0) }
    }
}

final class CodeScannerAddon: WindowAddon {
    private static let idleDelay: TimeInterval = 1.5
    private weak var editor: EditorWindowController?
    private let scanner: CodeScanner
    private var work: DispatchWorkItem?
    private var diagnostics: [URL: [Diagnostic]] = [:]
    private let badge = ProblemBadge()
    private let problemsView = ProblemsView()
    private var feed: FeedView?
    private var revision = 0
    private lazy var hover = DiagnosticHover(editor: editor)
    private static let all = NSHashTable<CodeScannerAddon>.weakObjects()
    private let splits = NSHashTable<SplitScannerAddon>.weakObjects()

    static func owner(of window: NSWindow?) -> CodeScannerAddon? {
        all.allObjects.first { $0.editor?.window != nil && $0.editor?.window === window }
    }

    init(editor: EditorWindowController, scanner: CodeScanner) {
        self.editor = editor
        self.scanner = scanner
        Self.all.add(self)
        CodeView.replaceLayoutManager(editor.textView, with: DiagnosticLayoutManager())
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.toggleProblems() }
        editor.addOverlay(badge)
        problemsView.onSelect = { [weak self, weak editor] item in
            if self?.splits.allObjects.contains(where: { $0.reveal(item) }) == true { return }
            editor?.reveal(item.url, range: item.range)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(marksRequested), name: CodeScanner.marksRequest, object: editor.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(textEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: editor.textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(externalChanged), name: ExternalDiagnostics.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lspFilesChanged), name: ExternalDiagnostics.filesChanged, object: nil)
        ExternalDiagnostics.install()
        hover.start()
        apply()
        schedule(delay: 0)
    }

    @objc private func externalChanged() { DispatchQueue.main.async { [weak self] in self?.apply() } }

    @objc private func lspFilesChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.apply()
            self?.schedule(delay: 0)
        }
    }

    private func merged(_ url: URL?) -> [Diagnostic] {
        guard let url, let editor else { return [] }
        let own = diagnostics[url] ?? []
        let text = editor.fileURL == url ? editor.textView.string : editor.openTexts.first { $0.url == url }?.text ?? ""
        return ExternalDiagnostics.merge(own, url: url, text: text)
    }

    @objc private func marksRequested() { postMarks() }

    @objc private func textEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
              let layout = editor?.textView.layoutManager as? DiagnosticLayoutManager else { return }
        layout.shiftMarks(edited: storage.editedRange, delta: storage.changeInLength)
    }

    private func postMarks() {
        guard let textView = editor?.textView else { return }
        let mine = merged(editor?.fileURL)
        let lines = { (severity: Diagnostic.Severity) in Set(mine.filter { $0.severity == severity }.map(\.line)) }
        NotificationCenter.default.post(name: CodeScanner.marksChanged, object: textView,
                                        userInfo: ["errors": lines(.error), "warnings": lines(.warning)])
    }

    func register(_ split: SplitScannerAddon) {
        splits.add(split)
        refreshProblems()
    }

    func refreshProblems() {
        let url = editor?.fileURL
        let mine = merged(url)
        let others = editor?.openURLs.filter { $0 != url }.flatMap { merged($0) } ?? []
        let right = splits.allObjects.flatMap(\.shown).filter { item in !(mine + others).contains { $0.url == item.url } }
        problemsView.show(mine + others + right)
    }

    func toggleProblems() {
        guard let editor else { return }
        let feed = self.feed ?? {
            let made = FeedView(title: "問題", content: problemsView)
            made.onRemove = { [weak self] in self?.toggleProblems() }
            editor.addFeed(made, button: nil)
            self.feed = made
            return made
        }()
        editor.toggleBottom(feed)
        apply()
    }

    private func schedule(delay: TimeInterval) {
        work?.cancel()
        guard editor?.fileURL != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.scan() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scan() {
        guard let editor, let url = editor.fileURL else { return }
        let scanned = revision
        scanner.scan(editor.textView.string, url: url) { [weak self] found in
            guard let self, self.editor?.isOpen(url) == true else { return }
            if self.editor?.fileURL == url, self.revision != scanned { return }
            self.diagnostics[url] = found
            self.apply()
        }
    }

    private func apply() {
        guard let editor else { return }
        let textView = editor.textView
        let url = editor.fileURL
        let mine = merged(url)
        badge.isHidden = url == nil
        badge.update(errors: mine.filter { $0.severity == .error }.count, warnings: mine.filter { $0.severity == .warning }.count)
        refreshProblems()

        let length = (textView.string as NSString).length
        let valid = mine.filter { NSMaxRange($0.range) <= length }
        (textView.layoutManager as? DiagnosticLayoutManager)?.marks = valid.map(\.mark)
        hover.hide()
        editor.recolor()
        textView.needsDisplay = true
        postMarks()
    }

    func fileOpened() {
        revision += 1
        apply()
        schedule(delay: 0)
    }

    func textChanged() {
        revision += 1
        hover.hide()
        schedule(delay: Self.idleDelay)
    }

    func bufferClosed(_ url: URL) {
        diagnostics[url] = nil
        refreshProblems()
    }

    func decorate(_ layout: NSLayoutManager) {
        guard let layout = layout as? DiagnosticLayoutManager else { return }
        let length = layout.textStorage?.length ?? 0
        for mark in layout.marks where mark.color == .systemRed && NSMaxRange(mark.range) <= length {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed, forCharacterRange: mark.range)
        }
    }

    func detach() {
        Self.all.remove(self)
        work?.cancel()
        hover.stop()
        NotificationCenter.default.removeObserver(self)
        if let textView = editor?.textView {
            NotificationCenter.default.post(name: CodeScanner.marksChanged, object: textView, userInfo: ["errors": Set<Int>(), "warnings": Set<Int>()])
        }
        badge.removeFromSuperview()
        if let feed { editor?.removeFeed(feed) }
        guard let editor else { return }
        CodeView.replaceLayoutManager(editor.textView, with: NSLayoutManager())
        editor.recolor()
    }
}

final class SplitScannerAddon: TextAddon {
    private weak var pane: SplitPane?
    private let scanner: CodeScanner
    private let badge = ProblemBadge()
    private var work: DispatchWorkItem?
    private var revision = 0
    private(set) var items: [Diagnostic] = []
    private lazy var hover = DiagnosticHover(editor: pane)

    init(pane: SplitPane, scanner: CodeScanner) {
        self.pane = pane
        self.scanner = scanner
        CodeView.replaceLayoutManager(pane.textView, with: DiagnosticLayoutManager())
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.owner?.toggleProblems() }
        pane.addOverlay(badge)
        NotificationCenter.default.addObserver(self, selector: #selector(marksRequested), name: CodeScanner.marksRequest, object: pane.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(textEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: pane.textView.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(externalChanged), name: ExternalDiagnostics.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lspFilesChanged), name: ExternalDiagnostics.filesChanged, object: nil)
        ExternalDiagnostics.install()
        hover.start()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.owner?.register(self)
            self.apply()
            self.schedule(delay: 0)
        }
    }

    private var owner: CodeScannerAddon? { CodeScannerAddon.owner(of: pane?.window) }

    @objc private func externalChanged() { DispatchQueue.main.async { [weak self] in self?.apply() } }

    @objc private func lspFilesChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.apply()
            self?.schedule(delay: 0)
        }
    }

    var shown: [Diagnostic] {
        guard let pane, let url = pane.fileURL else { return [] }
        return ExternalDiagnostics.merge(items, url: url, text: pane.textView.string)
    }

    @objc private func marksRequested() { postMarks() }

    @objc private func textEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
              let layout = pane?.textView.layoutManager as? DiagnosticLayoutManager else { return }
        layout.shiftMarks(edited: storage.editedRange, delta: storage.changeInLength)
    }

    private func postMarks() {
        guard let textView = pane?.textView else { return }
        let all = shown
        let lines = { (severity: Diagnostic.Severity) in Set(all.filter { $0.severity == severity }.map(\.line)) }
        NotificationCenter.default.post(name: CodeScanner.marksChanged, object: textView,
                                        userInfo: ["errors": lines(.error), "warnings": lines(.warning)])
    }

    private func schedule(delay: TimeInterval) {
        work?.cancel()
        guard pane?.fileURL != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.scan() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scan() {
        guard let pane, let url = pane.fileURL else { return }
        let scanned = revision
        scanner.scan(pane.textView.string, url: url) { [weak self] found in
            guard let self, self.pane?.fileURL == url, self.revision == scanned else { return }
            self.items = found
            self.apply()
        }
    }

    private func apply() {
        guard let pane else { return }
        let textView = pane.textView
        if pane.fileURL == nil { items = [] }
        badge.isHidden = pane.fileURL == nil
        let all = shown
        badge.update(errors: all.filter { $0.severity == .error }.count, warnings: all.filter { $0.severity == .warning }.count)
        let length = (textView.string as NSString).length
        (textView.layoutManager as? DiagnosticLayoutManager)?.marks = all.filter { NSMaxRange($0.range) <= length }.map(\.mark)
        hover.hide()
        textView.needsDisplay = true
        postMarks()
        owner?.refreshProblems()
    }

    func reveal(_ item: Diagnostic) -> Bool {
        guard let pane, pane.contains(item.url) else { return false }
        pane.select(item.url)
        guard pane.fileURL == item.url, NSMaxRange(item.range) <= (pane.textView.string as NSString).length else { return true }
        pane.textView.setSelectedRange(item.range)
        pane.textView.scrollRangeToVisible(item.range)
        pane.textView.showFindIndicator(for: item.range)
        return true
    }

    func fileOpened() {
        revision += 1
        items = []
        apply()
        schedule(delay: 0)
    }

    func textChanged() {
        revision += 1
        hover.hide()
        schedule(delay: 1.5)
    }

    func detach() {
        work?.cancel()
        hover.stop()
        NotificationCenter.default.removeObserver(self)
        items = []
        owner?.refreshProblems()
        guard let pane else { return }
        NotificationCenter.default.post(name: CodeScanner.marksChanged, object: pane.textView, userInfo: ["errors": Set<Int>(), "warnings": Set<Int>()])
        pane.removeOverlay(badge)
        CodeView.replaceLayoutManager(pane.textView, with: NSLayoutManager())
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CodeScannerPlugin()) }
