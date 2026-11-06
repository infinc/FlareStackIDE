import AppKit
@testable import FlareStackIDE

final class ShortcutPlugin: NativePlugin, PluginSettingsProviding {
    let id = ShortcutStore.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { ShortcutAddon(editor: editor) }
    func settingsView() -> NSView? { ShortcutSettingsView() }
}

final class ShortcutAddon: WindowAddon {
    private weak var editor: EditorWindowController?
    private var monitor: Any?

    init(editor: EditorWindowController) {
        self.editor = editor
        ShortcutStore.live += 1
        ShortcutStore.seedPalette()
        ShortcutStore.applyPaletteKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let editor = self.editor, event.window === editor.window,
                  let shortcut = ShortcutStore.items.first(where: { $0.matches(event) }),
                  let action = ShortcutAction(rawValue: shortcut.action) else { return event }
            DispatchQueue.main.async { self.perform(action) }
            return nil
        }
    }

    private func perform(_ action: ShortcutAction) {
        guard let editor else { return }
        switch action {
        case .run:
            if NativePlugins.plugin("runner") == nil || !editor.pressStripButton("run") {
                Toasts.post("Runner プラグインが必要です", message: "プラグインの一覧から Runner をインストールしてください", in: editor.window)
            }
        case .theme:
            Settings.applyTheme(((Settings.themeIndex ?? -1) + 1) % Settings.themes.count)
        case .close:
            editor.goBack()
        case .palette:
            editor.showCommandPalette(nil)
        case .zoomIn, .zoomOut, .zoomReset:
            if let zoom = action.zoom { Zoom.perform(zoom) }
        }
    }

    func detach() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        ShortcutStore.live -= 1
        ShortcutStore.applyPaletteKey()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ShortcutPlugin()) }
