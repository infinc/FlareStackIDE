import AppKit
@testable import FlareStackIDE

final class HelpMePlugin: NativePlugin {
    let id = "help-me"
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { HelpMeAddon(editor: editor) }
}

final class HelpMeAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        configure(undoButton, symbol: "arrow.uturn.backward", tip: "巻き戻す", action: #selector(undoClicked))
        configure(redoButton, symbol: "arrow.uturn.forward", tip: "やり直す", action: #selector(redoClicked))
        editor.addTopButton(undoButton)
        editor.addTopButton(redoButton)
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = EditorWindowController.cloudImage(symbol)
        button.isBordered = false
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    @objc private func undoClicked() {
        guard let manager = editor?.textView.undoManager, manager.canUndo else { return Toasts.hint("これ以上戻せません", under: undoButton) }
        manager.undo()
    }

    @objc private func redoClicked() {
        guard let manager = editor?.textView.undoManager, manager.canRedo else { return Toasts.hint("これ以上進めません", under: redoButton) }
        manager.redo()
    }

    func detach() {
        undoButton.removeFromSuperview()
        redoButton.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(HelpMePlugin()) }
