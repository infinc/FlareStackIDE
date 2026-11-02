import AppKit
@testable import FlareStackIDE

final class EmmetPlugin: NativePlugin {
    let id = "emmet"
    func textAddon(for code: CodeEditing) -> TextAddon? { EmmetAddon(code: code) }
}

final class EmmetAddon: TextAddon {
    private static let html: Set<String> = ["html", "htm", "xhtml", "vue", "svelte", "php", "erb", "jsx", "tsx", "astro"]
    private static let css: Set<String> = ["css", "scss", "sass", "less"]
    private weak var code: CodeEditing?
    let priority = 5

    init(code: CodeEditing) { self.code = code }

    func doCommand(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertTab(_:)), let code, let ext = code.fileURL?.pathExtension.lowercased(),
              code.textView.selectedRange().length == 0 else { return false }
        let textView = code.textView
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let start = Emmet.abbreviation(before: text, at: caret)
        guard start < caret, start == 0 || text.character(at: start - 1) != 0x3C else { return false }
        let abbreviation = text.substring(with: NSRange(location: start, length: caret - start))
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let lead = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
        let indent = String(lead.prefix { $0 == " " || $0 == "\t" })
        let unit = indent.hasPrefix("\t") ? "\t" : "    "
        let result: (text: String, cursor: Int)?
        if Self.html.contains(ext) {
            result = Emmet.expandHTML(abbreviation, indent: indent, unit: unit)
        } else if Self.css.contains(ext), lead == indent {
            result = Emmet.expandCSS(abbreviation)
        } else {
            result = nil
        }
        guard let result else { return false }
        textView.insertText(result.text, replacementRange: NSRange(location: start, length: caret - start))
        textView.setSelectedRange(NSRange(location: start + result.cursor, length: 0))
        return true
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(EmmetPlugin()) }
