import AppKit
@testable import FlareStackIDE

final class CodeScannerPlugin: NativePlugin {
    let id = CodeScanner.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? {
        CodeScanner.make().map { CodeScannerAddon(editor: editor, scanner: $0) }
    }
}

final class CodeScannerAddon: WindowAddon {
    private weak var editor: EditorWindowController?
    private let scanner: CodeScanner
    private var work: DispatchWorkItem?
    private var diagnostics: [URL: [Diagnostic]] = [:]
    private let badge = ProblemBadge()
    private let problemsView = ProblemsView()
    private var feed: FeedView?

    init(editor: EditorWindowController, scanner: CodeScanner) {
        self.editor = editor
        self.scanner = scanner
        CodeView.replaceLayoutManager(editor.textView, with: DiagnosticLayoutManager())
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.toggleProblems() }
        editor.addOverlay(badge)
        problemsView.onSelect = { [weak editor] in editor?.reveal($0.url, range: $0.range) }
        apply()
        schedule(delay: 0)
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
        scanner.scan(editor.textView.string, url: url) { [weak self] found in
            guard let self, self.editor?.isOpen(url) == true else { return }
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
        (textView.layoutManager as? DiagnosticLayoutManager)?.marks = valid.map { ($0.range, $0.color) }
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.toolTip, range: NSRange(location: 0, length: storage.length))
            for item in valid {
                let kind = item.severity == .error ? "エラー" : "警告"
                storage.addAttribute(.toolTip, value: "\(kind): \(item.message)", range: item.range)
            }
            storage.endEditing()
        }
        editor.recolor()
        textView.needsDisplay = true
    }

    func fileOpened() {
        apply()
        schedule(delay: 0)
    }

    func textChanged() { schedule(delay: 0.5) }

    func bufferClosed(_ url: URL) {
        diagnostics[url] = nil
        problemsView.show(editor?.openURLs.flatMap { diagnostics[$0] ?? [] } ?? [])
    }

    func decorate(_ layout: NSLayoutManager) {
        guard let layout = layout as? DiagnosticLayoutManager else { return }
        for mark in layout.marks where mark.color == .systemRed {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed, forCharacterRange: mark.range)
        }
    }

    func detach() {
        work?.cancel()
        badge.removeFromSuperview()
        if let feed { editor?.removeFeed(feed) }
        guard let editor else { return }
        if let storage = editor.textView.textStorage {
            storage.removeAttribute(.toolTip, range: NSRange(location: 0, length: storage.length))
        }
        CodeView.replaceLayoutManager(editor.textView, with: NSLayoutManager())
        editor.recolor()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CodeScannerPlugin()) }
