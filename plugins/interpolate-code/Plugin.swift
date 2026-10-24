import AppKit
@testable import FlareStackIDE

final class InterpolateCodePlugin: NativePlugin {
    let id = CodeInterpolator.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { InterpolateCodeAddon(code: code) }
}

final class InterpolateCodeAddon: TextAddon {
    private weak var code: CodeEditing?

    init(code: CodeEditing) { self.code = code }

    func shouldChange(_ range: NSRange, text: String) -> Bool {
        guard let textView = code?.textView else { return true }
        return CodeInterpolator.shouldChange(textView, range: range, text: text)
    }

    func doCommand(_ selector: Selector) -> Bool {
        guard let code, let url = code.fileURL else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return CodeInterpolator.newline(code.textView, ext: url.pathExtension.lowercased())
        case #selector(NSResponder.deleteBackward(_:)):
            return CodeInterpolator.deleteBackward(code.textView)
        default:
            return false
        }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(InterpolateCodePlugin()) }
