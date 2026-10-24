import AppKit
@testable import FlareStackIDE

final class LinesPlugin: NativePlugin {
    let id = LineNumberRuler.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { LinesAddon(code: code) }
}

final class LinesAddon: TextAddon {
    private weak var code: CodeEditing?

    init(code: CodeEditing) {
        self.code = code
        code.scrollView.setLineNumbers(true, textView: code.textView)
    }

    private func refresh() { (code?.scrollView.verticalRulerView as? LineNumberRuler)?.textChanged() }

    func fileOpened() { refresh() }

    func textChanged() { refresh() }

    func detach() {
        guard let code else { return }
        code.scrollView.setLineNumbers(false, textView: code.textView)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(LinesPlugin()) }
