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
    private static var live = 0
    private weak var code: CodeEditing?

    static var spacing: CGFloat? {
        Settings.pluginValue(LineNumberRuler.pluginID, "lineSpacing").flatMap(Double.init).map { CGFloat($0) }
    }

    init(code: CodeEditing) {
        self.code = code
        Self.live += 1
        if Self.live == 1 { Settings.lineSpacingOverride = { LinesAddon.spacing } }
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
        Self.live -= 1
        if Self.live == 0 { Settings.lineSpacingOverride = nil }
        guard let code else { return }
        code.scrollView.setLineNumbers(false, textView: code.textView)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(LinesPlugin()) }
