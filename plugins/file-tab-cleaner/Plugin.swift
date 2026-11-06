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
        button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "固定していないタブを閉じる")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))!, target: nil, action: nil)
        super.init()
        button.isBordered = false
        button.toolTip = "固定していないタブを閉じる"
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        code.tabStrip?.stack.insertArrangedSubview(button, at: 0)
        attach()
    }

    private var tabs: [TabItemView] { code?.tabStrip?.stack.arrangedSubviews.compactMap { $0 as? TabItemView } ?? [] }

    private func attach() {
        for tab in tabs where tab.onPin == nil && tab.url?.isFileURL == true {
            tab.onPin = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.toggle(tab)
            }
        }
    }

    private func toggle(_ tab: TabItemView) {
        tab.pinned.toggle()
        arrange()
        Toasts.hint(tab.pinned ? "タブを固定しました" : "固定を解除しました", under: tab)
    }

    private func arrange() {
        guard let stack = code?.tabStrip?.stack else { return }
        let pinned = tabs.filter(\.pinned)
        let start = (stack.arrangedSubviews.firstIndex(of: button) ?? -1) + 1
        for (offset, tab) in pinned.enumerated() where stack.arrangedSubviews.firstIndex(of: tab) != start + offset {
            stack.removeArrangedSubview(tab)
            stack.insertArrangedSubview(tab, at: start + offset)
        }
    }

    func fileOpened() { attach() }

    @objc private func clicked() {
        guard let code else { return }
        let kept = Set(tabs.filter(\.pinned).compactMap(\.url))
        if let closer = code as? TabClosing {
            closer.closeTabs(keeping: kept)
        } else {
            code.closeAllTabs()
        }
    }

    func detach() {
        button.removeFromSuperview()
        for tab in tabs {
            tab.onPin = nil
            tab.pinned = false
        }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(FileTabCleanerPlugin()) }
