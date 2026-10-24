import AppKit

final class FixedLineHeights: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let font = Settings.font
        let height = Settings.lineHeight
        lineFragmentRect.pointee.size.height = height + Settings.lineSpacing
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = (height - (font.ascender - font.descender)) / 2 + font.ascender
        return true
    }
}

enum CodeView {
    static let lineHeights = FixedLineHeights()

    static func configure(_ textView: NSTextView, scroll: NSScrollView) {
        textView.layoutManager?.delegate = lineHeights
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isEditable = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
    }

    static func applySettings(_ textView: NSTextView, scroll: NSScrollView) {
        textView.font = Settings.font
        textView.backgroundColor = Settings.background
        scroll.backgroundColor = Settings.background
        textView.insertionPointColor = Settings.foreground
        textView.defaultParagraphStyle = Settings.paragraphStyle
        style(textView)
        let wrap = Settings.wrapLines
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        scroll.hasHorizontalScroller = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scroll.contentSize.width
            textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = []
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    static func replace(_ textView: NSTextView, with text: String) {
        guard let storage = textView.textStorage else { return }
        let old = storage.string as NSString, new = text as NSString
        var head = 0
        let limit = min(old.length, new.length)
        while head < limit, old.character(at: head) == new.character(at: head) { head += 1 }
        var tail = 0
        while tail < limit - head, old.character(at: old.length - 1 - tail) == new.character(at: new.length - 1 - tail) { tail += 1 }
        let range = NSRange(location: head, length: old.length - head - tail)
        let inserted = new.substring(with: NSRange(location: head, length: new.length - head - tail))
        let selection = textView.selectedRange()
        let delta = (inserted as NSString).length - range.length
        let shift = { (i: Int) in i >= NSMaxRange(range) ? i + delta : min(i, head + (inserted as NSString).length) }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: inserted, attributes: textView.typingAttributes))
        storage.endEditing()
        let start = shift(selection.location), end = shift(NSMaxRange(selection))
        textView.setSelectedRange(NSRange(location: start, length: max(end - start, 0)))
        textView.undoManager?.removeAllActions()
    }

    static func diskText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func style(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Settings.font, .foregroundColor: Settings.foreground,
                                                    .paragraphStyle: Settings.paragraphStyle]
        storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attrs
    }
}

final class SplitPane: NSView, NSTextViewDelegate {
    var onEmpty: (() -> Void)?
    var onChange: (() -> Void)?
    var onMoveLeft: ((URL) -> Void)?
    var baseDirectory: (() -> URL?)?
    private let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    private var strip: TabStrip!
    private lazy var addons = TextAddons(code: self)
    private var tabs: [URL: TabItemView] = [:]
    private(set) var buffers: [URL: Buffer] = [:]
    private var current: Buffer?
    private var highlighter: Highlighter?
    private var recolorWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        let close = FeedView.barButton(symbol: "xmark", tip: "分割を閉じる", target: nil, action: nil)
        strip = TabStrip(trailing: close)
        close.target = self
        close.action = #selector(closeAll)
        CodeView.configure(textView, scroll: scroll)
        textView.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.clipsToBounds = true
        addSubview(scroll)
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: strip.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyPlugins()
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    var urls: [URL] { strip.stack.arrangedSubviews.compactMap { view in tabs.first { $0.value === view }?.key } }

    var dirty: Bool { buffers.values.contains { $0.dirty } }

    func contains(_ url: URL) -> Bool { tabs[url] != nil }

    func open(_ buffer: Buffer) {
        storeCurrent()
        let url = buffer.url
        buffers[url] = buffer
        if tabs[url] == nil {
            let tab = TabItemView(title: url.lastPathComponent, closable: true)
            tab.toolTip = url.path
            tab.draggable = true
            tab.onSelect = { [weak self] in
                guard let self, self.current?.url != url, let buffer = self.buffers[url] else { return }
                self.open(buffer)
            }
            tab.onClose = { [weak self] in self?.close(url) }
            tab.contextMenu = { [weak self] in self?.menu(for: url) }
            tabs[url] = tab
            strip.stack.addArrangedSubview(tab)
        }
        tabs.forEach { $0.value.selected = $0.key == url }
        if let tab = tabs[url] { strip.reveal(tab) }
        current = buffer
        textView.string = buffer.text
        CodeView.style(textView)
        textView.isEditable = buffer.editable
        highlighter = buffer.editable ? PluginStore.makeHighlighter(for: url) : nil
        recolor()
        addons.each { $0.fileOpened() }
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        window?.makeFirstResponder(textView)
    }

    func select(_ url: URL) {
        if current?.url != url, let buffer = buffers[url] { open(buffer) }
        window?.makeFirstResponder(textView)
    }

    func take(_ url: URL) -> Buffer? {
        guard let buffer = buffers[url] else { return nil }
        storeCurrent()
        remove(url)
        return buffer
    }

    private func menu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let left = NSMenuItem(title: "左に開く", action: #selector(moveLeftItem(_:)), keyEquivalent: "")
        left.target = self
        left.representedObject = url
        menu.addItem(left)
        let close = NSMenuItem(title: "閉じる", action: #selector(closeItem(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = url
        menu.addItem(close)
        return menu
    }

    @objc private func moveLeftItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onMoveLeft?(url)
    }

    @objc private func closeItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        close(url)
    }

    private func close(_ url: URL) {
        if current?.url == url { storeCurrent() }
        if let buffer = buffers[url], buffer.dirty, buffer.editable {
            do {
                try buffer.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
                return
            }
        }
        remove(url)
        onChange?()
    }

    private func remove(_ url: URL) {
        guard let tab = tabs[url] else { return }
        let order = strip.stack.arrangedSubviews.filter { $0 is TabItemView }
        let index = order.firstIndex(of: tab) ?? 0
        tab.removeFromSuperview()
        tabs[url] = nil
        buffers[url] = nil
        guard current?.url == url else { return }
        current = nil
        let remaining = strip.stack.arrangedSubviews.filter { $0 is TabItemView }
        if let next = remaining.isEmpty ? nil : tabs.first(where: { $0.value === remaining[min(index, remaining.count - 1)] })?.key,
           let buffer = buffers[next] {
            open(buffer)
        } else {
            onEmpty?()
        }
    }

    @objc func closeAll() {
        if let error = saveAll() {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        tabs.values.forEach { $0.removeFromSuperview() }
        tabs = [:]
        buffers = [:]
        current = nil
        onChange?()
        onEmpty?()
    }

    func remap(_ map: (URL) -> URL?) {
        storeCurrent()
        let order = urls
        let selected = current?.url
        tabs.values.forEach { $0.removeFromSuperview() }
        tabs = [:]
        buffers = [:]
        current = nil
        let reopened = order.compactMap(map)
        reopened.forEach { open(Buffer(url: $0)) }
        if let selected, let target = map(selected), let buffer = buffers[target] { open(buffer) }
        if reopened.isEmpty { onEmpty?() }
    }

    private func storeCurrent() {
        guard let current, current.editable else { return }
        current.text = textView.string
    }

    func reloadExternal(_ changed: (URL) -> Bool) {
        for (url, buffer) in buffers where buffer.editable && !buffer.dirty && changed(url) {
            guard let text = CodeView.diskText(url) else { continue }
            if buffer === current {
                guard text != textView.string, !textView.hasMarkedText() else { continue }
                addons.each { $0.dismiss() }
                CodeView.replace(textView, with: text)
                buffer.text = text
                addons.each { $0.textChanged() }
                recolor()
            } else {
                buffer.text = text
            }
        }
    }

    @discardableResult
    func saveAll() -> Error? {
        storeCurrent()
        for buffer in buffers.values where buffer.dirty && buffer.editable {
            do {
                try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
                buffer.dirty = false
            } catch {
                return error
            }
        }
        return nil
    }

    func applySettings() {
        strip.paint(.midTab)
        CodeView.applySettings(textView, scroll: scroll)
        recolor()
    }

    func applyPlugins() {
        addons.sync()
        if let current {
            highlighter = current.editable ? PluginStore.makeHighlighter(for: current.url) : nil
            recolor()
        }
    }

    private func recolor() {
        recolorWork?.cancel()
        recolorWork = nil
        guard let layout = textView.layoutManager else { return }
        let text = textView.string
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        guard let highlighter, let url = current?.url else { return }
        for span in highlighter.spans(text, file: url) {
            layout.addTemporaryAttribute(.foregroundColor, value: span.color, forCharacterRange: span.range)
        }
    }

    func detachAddons() { addons.detachAll() }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        return addons.shouldChange(range, text: text)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { addons.doCommand(selector) }

    func textViewDidChangeSelection(_ notification: Notification) { addons.each { $0.selectionChanged() } }

    func textDidChange(_ notification: Notification) {
        addons.each { $0.textChanged() }
        if highlighter != nil {
            recolorWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.recolor() }
            recolorWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        guard let current, current.editable else { return }
        current.text = textView.string
        if Settings.autosaveImmediate {
            current.dirty = (try? current.text.write(to: current.url, atomically: false, encoding: .utf8)) == nil
        } else {
            current.dirty = true
        }
        onChange?()
    }
}

extension SplitPane: CodeEditing {
    var scrollView: NSScrollView { scroll }
    var fileURL: URL? { current?.editable == true ? current?.url : nil }
    var tabStrip: TabStrip? { strip }
    var projectDirectory: URL? { baseDirectory?() }

    var openTexts: [(url: URL, text: String)] {
        storeCurrent()
        return buffers.values.filter { $0.editable }.map { ($0.url, $0.text) }
    }

    func closeAllTabs() { closeAll() }
}
