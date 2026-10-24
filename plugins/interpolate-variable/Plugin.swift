import AppKit
@testable import FlareStackIDE

final class InterpolateVariablePlugin: NativePlugin {
    let id = VariableCompleter.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { InterpolateVariableAddon(code: code) }
}

final class InterpolateVariableAddon: TextAddon {
    private weak var code: CodeEditing?
    private let completer = VariableCompleter()
    private var lastTyped: String?
    private var projectFiles: [URL] = []
    private var loading = false

    init(code: CodeEditing) {
        self.code = code
        completer.extraWords = { [weak self] in self?.words() ?? [] }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: code.scrollView.contentView)
        loadFiles()
    }

    var priority: Int { 10 }

    @objc private func scrolled() { completer.hide() }

    private func loadFiles() {
        guard let base = code?.projectDirectory, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = ProjectSearch.files(in: base)
            DispatchQueue.main.async {
                self?.projectFiles = files
                self?.loading = false
            }
        }
    }

    private func words() -> [String] {
        guard let code, let url = code.fileURL else { return [] }
        let ext = url.pathExtension.lowercased()
        var words = Set(projectFiles.filter { $0.pathExtension.lowercased() == ext && !ext.isEmpty }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil })
        for (other, text) in code.openTexts where other != url && other.pathExtension.lowercased() == ext {
            words.formUnion(VariableCompleter.words(in: text).keys)
        }
        return Array(words)
    }

    func shouldChange(_ range: NSRange, text: String) -> Bool {
        lastTyped = text
        return true
    }

    func doCommand(_ selector: Selector) -> Bool { completer.handle(selector) }

    func selectionChanged() {
        if lastTyped == nil { completer.hide() }
    }

    func textChanged() {
        defer { lastTyped = nil }
        guard let code, let url = code.fileURL, let typed = lastTyped else { return completer.hide() }
        let wordish = typed.isEmpty ? completer.isVisible
            : typed.utf16.count == 1 && typed.range(of: #"^[A-Za-z0-9_$]$"#, options: .regularExpression) != nil
        guard wordish else { return completer.hide() }
        completer.update(code.textView, ext: url.pathExtension.lowercased())
    }

    func treeChanged() { loadFiles() }

    func dismiss() { completer.hide() }

    func detach() {
        completer.hide()
        NotificationCenter.default.removeObserver(self)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(InterpolateVariablePlugin()) }
