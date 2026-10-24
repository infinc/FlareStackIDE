import AppKit
@testable import FlareStackIDE

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class VariableCompleter: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let pluginID = "interpolate-variable"
    private static let prose: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text", "rtf", "log", "csv", "tsv"]
    private static let maxShown = 8

    var extraWords: (() -> [String])?
    private let panel: CompletionPanel
    private let table = NSTableView()
    private weak var textView: NSTextView?
    private var items: [String] = []
    private var prefixRange = NSRange(location: NSNotFound, length: 0)
    private var accepting = false

    override init() {
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        let column = NSTableColumn(identifier: .init("word"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    private static var acceptsEnter: Bool { PluginStore.setting(pluginID, "acceptKey")?.lowercased() == "enter" }

    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
    }

    static func words(in text: String) -> [String: Int] {
        let chars = Array(text.utf16.prefix(Highlighter.limit))
        var counts: [String: Int] = [:]
        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else { i += 1; continue }
            let start = i
            while i < chars.count, isWordChar(chars[i]) { i += 1 }
            guard i - start >= 2, !(chars[start] >= 48 && chars[start] <= 57) else { continue }
            counts[String(decoding: chars[start..<i], as: UTF16.self), default: 0] += 1
        }
        return counts
    }

    func update(_ textView: NSTextView, ext: String) {
        guard !accepting, !Self.prose.contains(ext), !textView.hasMarkedText() else { return hide() }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return hide() }
        let string = textView.string as NSString
        var start = selection.location
        while start > 0, Self.isWordChar(string.character(at: start - 1)) { start -= 1 }
        let range = NSRange(location: start, length: selection.location - start)
        guard range.length > 0, !(string.character(at: start) >= 48 && string.character(at: start) <= 57) else { return hide() }
        if selection.location < string.length, Self.isWordChar(string.character(at: selection.location)) { return hide() }
        let prefix = string.substring(with: range)
        var counts = Self.words(in: textView.string)
        if let own = counts[prefix] { counts[prefix] = own - 1 }
        for word in extraWords?() ?? [] where counts[word] == nil { counts[word] = 0 }
        let lower = prefix.lowercased()
        let found = counts.filter { $0.key != prefix && $0.key.lowercased().hasPrefix(lower) }
            .sorted { a, b in
                let ac = a.key.hasPrefix(prefix), bc = b.key.hasPrefix(prefix)
                if ac != bc { return ac }
                if a.value != b.value { return a.value > b.value }
                return a.key.count != b.key.count ? a.key.count < b.key.count : a.key < b.key
            }
            .prefix(40).map(\.key)
        guard !found.isEmpty else { return hide() }
        self.textView = textView
        items = found
        prefixRange = range
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        place(textView)
    }

    private func place(_ textView: NSTextView) {
        guard let window = textView.window else { return hide() }
        let rect = textView.firstRect(forCharacterRange: NSRange(location: prefixRange.location, length: 0), actualRange: nil)
        guard rect != .zero else { return hide() }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let longest = items.prefix(40).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        let width = min(max(longest + 40, 160), 420)
        let height = CGFloat(min(items.count, Self.maxShown)) * table.rowHeight + 6
        var origin = NSPoint(x: rect.minX - 6, y: rect.minY - height - 2)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = rect.maxY + 2 }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func handle(_ selector: Selector) -> Bool {
        guard panel.isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertTab(_:)):
            guard !Self.acceptsEnter else { hide(); return false }
            accept()
        case #selector(NSResponder.insertNewline(_:)):
            guard Self.acceptsEnter else { hide(); return false }
            accept()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)): hide(); return false
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func accept() {
        guard let textView, items.indices.contains(table.selectedRow) else { return hide() }
        let word = items[table.selectedRow]
        let length = (textView.string as NSString).length
        guard NSMaxRange(prefixRange) <= length else { return hide() }
        hide()
        accepting = true
        textView.insertText(word, replacementRange: prefixRange)
        accepting = false
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        accept()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let word = items[row]
        let text = NSMutableAttributedString(string: word, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
        text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                          range: NSRange(location: 0, length: min(prefixRange.length, text.length)))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
