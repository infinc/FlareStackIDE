import AppKit
@testable import FlareStackIDE

final class FileTabCleanerPlugin: NativePlugin {
    let id = "file-tab-cleaner"
    func textAddon(for code: CodeEditing) -> TextAddon? { FileTabCleanerAddon(code: code) }
}

final class FileTabCleanerAddon: NSObject, TextAddon {
    private weak var code: CodeEditing?
    private let button: NSButton

    init(code: CodeEditing) {
        self.code = code
        button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "タブをすべて閉じる")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))!, target: nil, action: nil)
        super.init()
        button.isBordered = false
        button.toolTip = "タブをすべて閉じる"
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        code.tabStrip?.stack.insertArrangedSubview(button, at: 0)
    }

    @objc private func clicked() { code?.closeAllTabs() }

    func detach() { button.removeFromSuperview() }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(FileTabCleanerPlugin()) }
