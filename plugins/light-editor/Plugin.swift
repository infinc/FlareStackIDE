import AppKit
@testable import FlareStackIDE

final class LightEditorPlugin: NativePlugin {
    let id = LightEditorWindowController.pluginID
    var opensFiles: Bool { true }
    func fileWindow(for url: URL) -> FileWindow? { LightEditorWindowController(url: url) }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(LightEditorPlugin()) }
