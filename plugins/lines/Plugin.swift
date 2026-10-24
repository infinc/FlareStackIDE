import AppKit
@testable import FlareStackIDE

final class LinesPlugin: NativePlugin, PluginSettingsProviding {
    let id = LineNumberRuler.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { LinesAddon(code: code) }
    func settingsView() -> NSView? {
        let title = NSTextField(labelWithString: "プレビュー")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, LinesPreview()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }
}

final class LinesAddon: TextAddon {
    private weak var code: CodeEditing?

    init(code: CodeEditing) {
        self.code = code
        show()
    }

    private func show() {
        guard let code else { return }
        code.scrollView.setLineNumbers(true, textView: code.textView)
        refresh()
    }

    private func refresh() { (code?.scrollView.verticalRulerView as? LineNumberRuler)?.textChanged() }

    func fileOpened() {
        show()
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    func treeChanged() { show() }

    func textChanged() { refresh() }

    func detach() {
        guard let code else { return }
        code.scrollView.setLineNumbers(false, textView: code.textView)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(LinesPlugin()) }
