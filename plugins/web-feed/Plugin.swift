import AppKit
@testable import FlareStackIDE

final class WebFeedPlugin: NativePlugin {
    let id = WebFeed.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { WebFeedAddon(editor: editor) }
}

final class WebFeedAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var feed: WebFeed?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "magnifyingglass", tip: "Web Feed", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: "web")
    }

    @objc private func toggle() {
        guard let editor else { return }
        if let feed, !feed.isHidden { return editor.hideBottom(feed) }
        let feed = self.feed ?? {
            let made = WebFeed()
            made.onRemove = { [weak self] in self?.toggle() }
            editor.addFeed(made, button: button)
            self.feed = made
            return made
        }()
        editor.showBottom(feed)
        DispatchQueue.main.async { feed.focus() }
    }

    func detach() {
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(WebFeedPlugin()) }
