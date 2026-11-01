import AppKit
@testable import FlareStackIDE

final class GitActionsPlugin: NativePlugin {
    let id = "git-actions"
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { GitActionsAddon(editor: editor) }
}

final class GitActionsAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var view: GitActionsView?
    private var feed: FeedView?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "arrow.triangle.pull", tip: "Git Actions", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: "git-actions")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(reload), name: NSWindow.didBecomeKeyNotification, object: editor.window)
        applySettings()
    }

    @objc private func applySettings() {
        button.isHidden = !Settings.gitEnabled
        if !Settings.gitEnabled, let feed, !feed.isHidden { editor?.hideBottom(feed) }
    }

    @objc private func reload() {
        if feed?.isHidden == false { view?.reload() }
    }

    @objc private func toggle() {
        guard let editor else { return }
        let feed = self.feed ?? {
            let content = GitActionsView(editor: editor)
            let refresh = FeedView.barButton(symbol: "arrow.clockwise", tip: "再読み込み", target: content, action: #selector(GitActionsView.reload))
            let made = FeedView(title: "Git Actions", content: content, extras: [refresh])
            made.onRemove = { [weak self] in self?.toggle() }
            editor.addFeed(made, button: button)
            view = content
            self.feed = made
            return made
        }()
        editor.toggleBottom(feed)
        reload()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        view = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(GitActionsPlugin()) }
