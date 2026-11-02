import AppKit
@testable import FlareStackIDE

final class CodeScannerPlugin: NativePlugin {
    let id = CodeScanner.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? {
        CodeScanner.make().map { CodeScannerAddon(editor: editor, scanner: $0) }
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

    init(editor: EditorWindowController, scanner: CodeScanner) {
        self.editor = editor
        self.scanner = scanner
        CodeView.replaceLayoutManager(editor.textView, with: DiagnosticLayoutManager())
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.toggleProblems() }
        editor.addOverlay(badge)
        problemsView.onSelect = { [weak editor] in editor?.reveal($0.url, range: $0.range) }
        NotificationCenter.default.addObserver(self, selector: #selector(marksRequested), name: CodeScanner.marksRequest, object: editor.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(textEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: editor.textView.textStorage)
        hover.start()
        apply()
        schedule(delay: 0)
    }

    @objc private func marksRequested() { postMarks() }

    @objc private func textEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
              let layout = editor?.textView.layoutManager as? DiagnosticLayoutManager else { return }
        layout.shiftMarks(edited: storage.editedRange, delta: storage.changeInLength)
    }

    private func postMarks() {
        guard let textView = editor?.textView else { return }
        let mine = editor?.fileURL.flatMap { diagnostics[$0] } ?? []
        let lines = { (severity: Diagnostic.Severity) in Set(mine.filter { $0.severity == severity }.map(\.line)) }
        NotificationCenter.default.post(name: CodeScanner.marksChanged, object: textView,
                                        userInfo: ["errors": lines(.error), "warnings": lines(.warning)])
    }

    private func toggleProblems() {
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
        let mine = url.flatMap { diagnostics[$0] } ?? []
        badge.isHidden = url == nil
        badge.update(errors: mine.filter { $0.severity == .error }.count, warnings: mine.filter { $0.severity == .warning }.count)
        let others = editor.openURLs.filter { $0 != url }.flatMap { diagnostics[$0] ?? [] }
        problemsView.show(mine + others)

        let length = (textView.string as NSString).length
        let valid = mine.filter { NSMaxRange($0.range) <= length }
        (textView.layoutManager as? DiagnosticLayoutManager)?.marks = valid.map {
            DiagnosticMark(range: $0.range, color: $0.color, message: "\($0.severity == .error ? "エラー" : "警告"): \($0.message)")
        }
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
        problemsView.show(editor?.openURLs.flatMap { diagnostics[$0] ?? [] } ?? [])
    }

    func decorate(_ layout: NSLayoutManager) {
        guard let layout = layout as? DiagnosticLayoutManager else { return }
        let length = layout.textStorage?.length ?? 0
        for mark in layout.marks where mark.color == .systemRed && NSMaxRange(mark.range) <= length {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed, forCharacterRange: mark.range)
        }
    }

    func detach() {
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

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CodeScannerPlugin()) }
