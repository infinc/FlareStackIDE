import AppKit

private final class HiddenRanges {
    let ranges: [NSRange]
    init(_ ranges: [NSRange]) { self.ranges = ranges }
    func contains(_ index: Int) -> Bool { ranges.contains { NSLocationInRange(index, $0) } }
}

private final class BackgroundMarks {
    var owners: [String: [(range: NSRange, color: NSColor)]] = [:]
}

final class FixedLineHeights: NSObject, NSLayoutManagerDelegate {
    private let hidden = NSMapTable<NSTextStorage, HiddenRanges>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    func setHidden(_ ranges: [NSRange], for textView: NSTextView, invalidating: Bool = true) {
        guard let storage = textView.textStorage else { return }
        let old = hidden.object(forKey: storage)?.ranges ?? []
        guard old != ranges else { return }
        if ranges.isEmpty { hidden.removeObject(forKey: storage) } else { hidden.setObject(HiddenRanges(ranges), forKey: storage) }
        if invalidating { invalidate(old + ranges, in: textView) }
    }

    func invalidate(_ ranges: [NSRange], in textView: NSTextView) {
        guard let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: storage.length)
        for range in ranges {
            let clipped = NSIntersectionRange(NSRange(location: max(range.location - 1, 0), length: range.length + 1), whole)
            guard clipped.length > 0 else { continue }
            layout.invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: clipped, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
    }

    private func hidden(in layoutManager: NSLayoutManager) -> HiddenRanges? {
        layoutManager.textStorage.flatMap { hidden.object(forKey: $0) }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let hidden = hidden(in: layoutManager) else { return 0 }
        var changed = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for i in 0..<glyphRange.length where hidden.contains(characterIndexes[i]) { changed[i] = .null }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        hidden(in: layoutManager)?.contains(charIndex) == true ? .zeroAdvancement : action
    }

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

final class CodeScrollView: NSScrollView {
    var gutter: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let gutter { addSubview(gutter) }
            tile()
        }
    }

    static func make() -> CodeScrollView {
        let source = NSTextView.scrollableTextView()
        let scroll = CodeScrollView()
        let document = source.documentView
        source.documentView = nil
        scroll.documentView = document
        scroll.hasVerticalScroller = source.hasVerticalScroller
        scroll.autohidesScrollers = source.autohidesScrollers
        return scroll
    }

    override func tile() {
        super.tile()
        guard let gutter else { return }
        let width = gutter.frame.width
        contentView.frame.size.width = max(contentView.frame.width - width, 0)
        verticalScroller?.frame.origin.x -= width
        horizontalScroller?.frame.size.width -= width
        gutter.frame = NSRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
    }
}

enum CodeView {
    static let lineHeights = FixedLineHeights()
    private static let backgrounds = NSMapTable<NSTextView, BackgroundMarks>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    static func setBackgrounds(_ marks: [(range: NSRange, color: NSColor)], owner: String, in textView: NSTextView) {
        guard let layout = textView.layoutManager, let storage = textView.textStorage else { return }
        let table = backgrounds.object(forKey: textView) ?? BackgroundMarks()
        backgrounds.setObject(table, forKey: textView)
        table.owners[owner] = marks.isEmpty ? nil : marks
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        for key in table.owners.keys.sorted() {
            for mark in table.owners[key] ?? [] where NSMaxRange(mark.range) <= storage.length {
                layout.addTemporaryAttribute(.backgroundColor, value: mark.color, forCharacterRange: mark.range)
            }
        }
    }

    static func center(_ textView: NSTextView, on range: NSRange) {
        guard let layout = textView.layoutManager, let container = textView.textContainer, let scroll = textView.enclosingScrollView else { return }
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let clip = scroll.contentView
        let top = max(min(rect.midY - clip.bounds.height / 2, textView.frame.height - clip.bounds.height), 0)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

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
            textView.frame.size.width = scroll.contentView.frame.width
            textView.textContainer?.containerSize = NSSize(width: scroll.contentView.frame.width, height: CGFloat.greatestFiniteMagnitude)
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

    static func replaceLayoutManager(_ textView: NSTextView, with layout: NSLayoutManager) {
        let rulers = textView.enclosingScrollView?.rulersVisible
        layout.delegate = lineHeights
        textView.textContainer?.replaceLayoutManager(layout)
        if let rulers { textView.enclosingScrollView?.rulersVisible = rulers }
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
    var tabColor: ((URL) -> NSColor?)?
    private let scroll = CodeScrollView.make()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    private var strip: TabStrip!
    private(set) lazy var addons = TextAddons(code: self)
    private var tabs: [URL: TabItemView] = [:]
    private(set) var buffers: [URL: Buffer] = [:]
    private var current: Buffer?
    private var highlighter: Highlighter?
    private var recolorWork: DispatchWorkItem?
    private let barHost = NSView()
    private let bodyHost = NSView()
    private var barHeight: NSLayoutConstraint!
    private var floatConstraints: [NSLayoutConstraint] = []
    private var overlays: [NSView] = []
    private var overlayTrailing: [NSLayoutConstraint] = []
    private var overlayInset: CGFloat = 0
    private var ext: EditorExtension?

    init() {
        super.init(frame: .zero)
        let close = FeedView.barButton(symbol: "xmark", tip: "分割を閉じる", target: nil, action: nil)
        strip = TabStrip(trailing: close)
        close.target = self
        close.action = #selector(closeAll)
        CodeView.configure(textView, scroll: scroll)
        textView.delegate = self
        scroll.clipsToBounds = true
        [barHost, bodyHost].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.clipsToBounds = true
        }
        addSubview(bodyHost)
        addSubview(barHost)
        addSubview(strip)
        barHeight = barHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            barHost.topAnchor.constraint(equalTo: strip.bottomAnchor),
            barHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            barHeight,
            bodyHost.topAnchor.constraint(equalTo: barHost.bottomAnchor),
            bodyHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host(scroll, in: bodyHost)
        applyPlugins()
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    var urls: [URL] { strip.stack.arrangedSubviews.compactMap { view in tabs.first { $0.value === view }?.key } }

    var dirty: Bool { buffers.values.contains { $0.dirty } }

    func contains(_ url: URL) -> Bool { tabs[url] != nil }

    func colorTabs() { tabs.forEach { $0.value.tint = tabColor?($0.key) } }

    func open(_ buffer: Buffer) {
        storeCurrent()
        let url = buffer.url
        buffers[url] = buffer
        if tabs[url] == nil {
            let tab = TabItemView(title: url.lastPathComponent, closable: true)
            tab.toolTip = url.path
            tab.draggable = true
            tab.tint = tabColor?(url)
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
        attachExtension()
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
            detachExtension()
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
        detachExtension()
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
                ext?.update(text: text)
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
        ext?.applySettings()
        if ext?.floating == true { layoutExtensionBar() }
    }

    func applyPlugins() {
        addons.sync()
        if let current {
            storeCurrent()
            highlighter = current.editable ? PluginStore.makeHighlighter(for: current.url) : nil
            recolor()
            attachExtension()
        }
    }

    private func host(_ view: NSView, in host: NSView) {
        host.subviews.filter { $0 !== view }.forEach { $0.removeFromSuperview() }
        view.isHidden = false
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func attachExtension() {
        detachExtension()
        guard let current else { return }
        let viewer = NativePlugins.viewer(for: current.url)
        textView.isEditable = current.editable && viewer == nil
        ext = viewer ?? (current.editable ? PluginStore.makeExtension(for: current.url, code: scroll) : nil)
        guard let ext else { return detachExtension() }
        host(ext.body, in: bodyHost)
        layoutExtensionBar()
        ext.update(text: textView.string)
    }

    private func layoutExtensionBar() {
        guard let ext else { return }
        let bar = ext.bar
        NSLayoutConstraint.deactivate(floatConstraints)
        floatConstraints = []
        bar.removeFromSuperview()
        barHost.subviews.forEach { $0.removeFromSuperview() }
        guard ext.floating else {
            host(bar, in: barHost)
            barHeight.constant = 30
            return
        }
        barHeight.constant = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(bar)
        let corner = ext.corner
        let ruler = scroll.rulersVisible ? scroll.verticalRulerView?.ruleThickness ?? 0 : 0
        floatConstraints = [
            bar.heightAnchor.constraint(equalToConstant: 28),
            corner.right ? bar.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -18 - overlayInset)
                : bar.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor, constant: 18 + ruler),
        ]
        if corner.top {
            let top = bar.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: 14)
            top.priority = .defaultHigh
            floatConstraints.append(top)
            if corner.right {
                floatConstraints += overlays.filter { $0.superview != nil }.map { bar.topAnchor.constraint(greaterThanOrEqualTo: $0.bottomAnchor, constant: 8) }
            }
        } else {
            floatConstraints.append(bar.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(floatConstraints)
    }

    private func detachExtension() {
        NSLayoutConstraint.deactivate(floatConstraints)
        floatConstraints = []
        ext?.bar.removeFromSuperview()
        ext = nil
        barHost.subviews.forEach { $0.removeFromSuperview() }
        barHeight.constant = 0
        host(scroll, in: bodyHost)
    }

    private func recolor() {
        recolorWork?.cancel()
        recolorWork = nil
        guard let layout = textView.layoutManager else { return }
        let text = textView.string
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        defer { addons.decorate(layout) }
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
        ext?.update(text: current.text)
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

extension SplitPane: OverlayHosting {
    func addOverlay(_ view: NSView) {
        guard !overlays.contains(view) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        overlays.append(view)
        let trailing = view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -4 - overlayInset)
        overlayTrailing.append(trailing)
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: 4), trailing])
        if ext?.floating == true { layoutExtensionBar() }
    }

    func removeOverlay(_ view: NSView) {
        guard let index = overlays.firstIndex(of: view) else { return }
        overlays.remove(at: index)
        overlayTrailing.remove(at: index)
        view.removeFromSuperview()
        if ext?.floating == true { layoutExtensionBar() }
    }

    func setOverlayInset(_ inset: CGFloat) {
        overlayInset = inset
        overlayTrailing.forEach { $0.constant = -4 - inset }
        if ext?.floating == true { layoutExtensionBar() }
    }
}
