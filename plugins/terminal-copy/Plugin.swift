import AppKit
@testable import FlareStackIDE

final class TerminalCopyPlugin: NativePlugin {
    let id = "terminal-copy"
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { TerminalCopyAddon() }
}

final class TerminalCopyAddon: WindowAddon {
    private static var users = 0

    init() {
        Self.users += 1
        TerminalView.onSelect = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func detach() {
        Self.users -= 1
        if Self.users <= 0 { TerminalView.onSelect = nil }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(TerminalCopyPlugin()) }
