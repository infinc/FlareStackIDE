import AppKit
@testable import FlareStackIDE

final class ZenModePlugin: NativePlugin {
    let id = ZenModeAddon.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { ZenModeAddon(editor: editor) }
}

final class ZenModeAddon: NSObject, WindowAddon, CommandProviding {
    static let pluginID = "zen-mode"
    private static let defaultInset = NSSize(width: 6, height: 6)
    private weak var editor: EditorWindowController?
    private let button = NSButton()
    private var monitor: Any?
    private var enteredFullScreen = false

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button.image = EditorWindowController.cloudImage("rectangle.center.inset.filled")
        button.isBordered = false
        button.toolTip = "集中モード（⌥⌘Z）"
        button.target = self
        button.action = #selector(toggle)
        editor.addTopButton(button)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.editor?.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
                  event.charactersIgnoringModifiers?.lowercased() == "z" || event.keyCode == 6 else { return event }
            self.toggle()
            return nil
        }
        editor.scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: editor.scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: .settingsChanged, object: nil)
    }

    var commands: [PaletteCommand] {
        let on = editor?.focusMode == true
        return [PaletteCommand(id: "zen-mode.toggle", title: on ? "集中モードを終了" : "集中モード", detail: "⌥⌘Z") { [weak self] in self?.toggle() }]
    }

    private var width: Int? { PluginStore.setting(Self.pluginID, "width").flatMap { Double($0) }.map { Int($0) } }
    private var fullScreen: Bool { PluginStore.setting(Self.pluginID, "fullScreen") == "true" }

    @objc private func toggle() {
        guard let editor, let window = editor.window else { return }
        let on = !editor.focusMode
        editor.setFocusMode(on)
        button.contentTintColor = on ? .controlAccentColor : nil
        let isFull = window.styleMask.contains(.fullScreen)
        if on, fullScreen, !isFull {
            enteredFullScreen = true
            window.toggleFullScreen(nil)
        } else if !on, enteredFullScreen {
            enteredFullScreen = false
            if isFull { window.toggleFullScreen(nil) }
        }
        center()
    }

    @objc private func layoutChanged() { center() }

    private func center() {
        guard let editor else { return }
        let textView = editor.textView
        guard editor.focusMode, let columns = width, columns > 0 else {
            if textView.textContainerInset != Self.defaultInset { textView.textContainerInset = Self.defaultInset }
            return
        }
        let charWidth = (" " as NSString).size(withAttributes: [.font: Settings.font]).width
        let visible = editor.scrollView.contentView.bounds.width
        let side = max(Self.defaultInset.width, floor((visible - CGFloat(columns) * charWidth) / 2))
        let inset = NSSize(width: side, height: Self.defaultInset.height)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
    }

    func detach() {
        if editor?.focusMode == true { toggle() }
        editor?.textView.textContainerInset = Self.defaultInset
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ZenModePlugin()) }
