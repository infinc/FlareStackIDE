import AppKit

final class LightEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let pluginID = "light-editor"
    let url: URL
    var onClose: (() -> Void)?
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let status = NSButton()
    private var dirty = false
    private var timer: Timer?

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) — Light Editer"
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        window.setFrameAutosaveName("Light:\(url.path)")
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        _ = textView.layoutManager
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = self
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            textView.string = text
        } else {
            textView.string = "このファイルは表示できません。"
            textView.isEditable = false
        }
        scroll.setLineNumbers(true, textView: textView)

        status.isBordered = false
        status.target = self
        status.action = #selector(save)
        status.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
        ])
        window?.contentView = content
        updateStatus()
    }

    @objc private func applySettings() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Settings.font, .foregroundColor: Settings.foreground,
                                                    .paragraphStyle: Settings.paragraphStyle]
        textView.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.typingAttributes = attrs
        textView.font = Settings.font
        textView.backgroundColor = Settings.background
        scroll.backgroundColor = Settings.background
        textView.insertionPointColor = Settings.foreground
        let wrap = Settings.wrapLines
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        scroll.hasHorizontalScroller = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scroll.contentSize.width
        } else {
            textView.autoresizingMask = []
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        window?.appearance = Settings.surfaceColor(.editor).map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua)! }
        timer?.invalidate()
        timer = Settings.autosaveEnabled && !Settings.autosaveImmediate
            ? Timer.scheduledTimer(timeInterval: Settings.autosaveInterval, target: self, selector: #selector(save), userInfo: nil, repeats: true)
            : nil
        updateStatus()
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        if Settings.autosaveImmediate { save() } else { updateStatus() }
    }

    private func updateStatus() {
        status.image = EditorWindowController.cloudImage(dirty ? "icloud.and.arrow.up" : "checkmark.icloud")
        status.toolTip = dirty ? (Settings.autosaveEnabled ? "保存中…" : "未保存（クリックで保存）") : "保存済み"
        window?.isDocumentEdited = dirty
    }

    @objc func save() {
        guard dirty, textView.isEditable else { return }
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
        } catch {
            if let window, window.attachedSheet == nil { NSAlert(error: error).beginSheetModal(for: window) }
        }
        updateStatus()
    }

    @objc func saveDocument(_ sender: Any?) { save() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        save()
        return !dirty
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose?()
    }
}
