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
        updateVisibility()
    }

    private func updateVisibility() {
        guard let scroll else { return }
        let visible = code?.fileURL != nil
        if visible, scroll.gutter !== map {
            scroll.gutter = map
            (code as? OverlayHosting)?.setOverlayInset(Minimap.width)
        } else if !visible, scroll.gutter === map {
            scroll.gutter = nil
            (code as? OverlayHosting)?.setOverlayInset(0)
        }
    }

    func fileOpened() {
        updateVisibility()
        map.contentChanged()
    }

    func textChanged() { map.textChanged() }

    func detach() {
        scroll?.gutter = nil
        (code as? OverlayHosting)?.setOverlayInset(0)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ScrollAssistantPlugin()) }
