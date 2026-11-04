import AppKit
@testable import FlareStackIDE

final class ScratchPadPlugin: NativePlugin {
    let id = ScratchPadAddon.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { ScratchPadAddon(editor: editor) }
}

final class ScratchPadAddon: NSObject, WindowAddon {
    static let pluginID = "scratch-pad"
    private static let buttonID = "scratch-pad"
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var feed: FeedView?
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        Self.placeInUpperGroup()
        button = ToolStripButton(symbol: "note.text", tip: "メモ", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: Self.buttonID)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        applySettings()
    }

    private static func placeInUpperGroup() {
        let defaults = UserDefaults.standard
        let upperKey = "BigTab.Order.Upper", lowerKey = "BigTab.Order.Lower"
        let upper = defaults.stringArray(forKey: upperKey) ?? ["folder", "plugin"]
        let lower = defaults.stringArray(forKey: lowerKey) ?? []
        guard !upper.contains(buttonID), !lower.contains(buttonID) else { return }
        defaults.set(upper + [buttonID], forKey: upperKey)
    }

    @objc private func applySettings() {
        textView.font = Settings.font
        textView.textColor = Settings.foreground
        textView.insertionPointColor = Settings.foreground
        textView.drawsBackground = false
        textView.typingAttributes = [.font: Settings.font, .foregroundColor: Settings.foreground]
        if let storage = textView.textStorage {
            storage.addAttributes([.font: Settings.font, .foregroundColor: Settings.foreground], range: NSRange(location: 0, length: storage.length))
        }
    }

    @objc private func toggle() {
        guard let editor else { return }
        let feed = self.feed ?? {
            let clear = FeedView.barButton(symbol: "trash", tip: "メモを全て消す", target: self, action: #selector(clearAll))
            let made = FeedView(title: "メモ", content: scroll, extras: [clear])
            made.onRemove = { [weak self] in self?.toggle() }
            editor.addFeed(made, button: button)
            self.feed = made
            return made
        }()
        editor.toggleBottom(feed)
        if !feed.isHidden { DispatchQueue.main.async { [weak self] in self?.focus() } }
    }

    private func focus() { textView.window?.makeFirstResponder(textView) }

    @objc private func clearAll() {
        guard !textView.string.isEmpty else { return }
        textView.selectAll(nil)
        textView.insertText("", replacementRange: textView.selectedRange())
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ScratchPadPlugin()) }
