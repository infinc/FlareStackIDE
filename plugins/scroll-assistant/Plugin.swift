import AppKit
@testable import FlareStackIDE

final class ScrollAssistantPlugin: NativePlugin {
    let id = "scroll-assistant"
    func textAddon(for code: CodeEditing) -> TextAddon? {
        (code.scrollView as? CodeScrollView).map { ScrollAssistantAddon(code: code, scroll: $0) }
    }
}

final class ScrollAssistantAddon: TextAddon {
    private weak var code: CodeEditing?
    private weak var scroll: CodeScrollView?
    private let map: Minimap

    init(code: CodeEditing, scroll: CodeScrollView) {
        self.code = code
        self.scroll = scroll
        map = Minimap(textView: code.textView, scroll: scroll)
        scroll.gutter = map
        (code as? EditorWindowController)?.setOverlayInset(Minimap.width)
    }

    func fileOpened() { map.contentChanged() }

    func textChanged() { map.textChanged() }

    func detach() {
        scroll?.gutter = nil
        (code as? EditorWindowController)?.setOverlayInset(0)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ScrollAssistantPlugin()) }
