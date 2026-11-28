import AppKit

struct SearchHit {
    let url: URL
    let relative: String
    let line: Int?
    let text: String
    let match: NSRange
}

enum ProjectSearch {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".venv", "venv", "__pycache__", ".DS_Store", ".idea"]
    static let maxFileSize = 1_000_000
    static let maxHits = 400

    static func files(in base: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == false { result.append(url) }
            if result.count > 20_000 { break }
        }
        return result
    }

    struct Options {
        var regex = false
        var caseSensitive = false
    }

    struct Replacement {
        let url: URL
        let original: Data
        let text: String
        let format: TextFormat
        let count: Int
    }

    static func matcher(_ query: String, _ options: Options) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: options.regex ? query : NSRegularExpression.escapedPattern(for: query),
                                        options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    static func read(_ url: URL) -> (data: Data, text: String, format: TextFormat)? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url), !data.prefix(4096).contains(0),
              let file = TextFile.read(data) else { return nil }
        return (data, file.text, file.format)
    }

    private static func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    static func run(_ query: String, in base: URL, options: Options = Options(), cancelled: () -> Bool) -> [SearchHit] {
        guard let regex = matcher(query, options) else { return [] }
        let all = files(in: base)
        let prefix = base.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        var names: [SearchHit] = []
        for url in all {
            let name = url.lastPathComponent
            if let match = regex.firstMatch(in: name, range: whole(name)), match.range.length > 0 {
                names.append(SearchHit(url: url, relative: relative(url), line: nil, text: name, match: match.range))
            }
        }
        names.sort { $0.text.count < $1.text.count }
        var lines: [SearchHit] = []
        for url in all {
            if cancelled() || names.count + lines.count >= maxHits { break }
            guard let file = read(url), regex.firstMatch(in: file.text, range: whole(file.text)) != nil else { continue }
            var number = 0
            file.text.enumerateLines { line, stop in
                number += 1
                guard let found = regex.firstMatch(in: line, range: whole(line)), found.range.length > 0 else { return }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let shift = (line as NSString).range(of: trimmed).location
                var match = found.range
                match.location -= shift == NSNotFound ? 0 : shift
                lines.append(SearchHit(url: url, relative: relative(url), line: number, text: trimmed, match: match))
                if names.count + lines.count >= maxHits { stop = true }
            }
        }
        return names + lines
    }

    static func replacements(_ query: String, with replacement: String, in base: URL, options: Options) -> [Replacement] {
        guard let regex = matcher(query, options) else { return [] }
        let template = options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return files(in: base).compactMap { url in
            guard let file = read(url) else { return nil }
            let count = regex.numberOfMatches(in: file.text, range: whole(file.text))
            guard count > 0 else { return nil }
            let text = regex.stringByReplacingMatches(in: file.text, range: whole(file.text), withTemplate: template)
            return text == file.text ? nil : Replacement(url: url, original: file.data, text: text, format: file.format, count: count)
        }
    }

    static func apply(_ plan: [Replacement]) throws -> [URL: Data] {
        var originals: [URL: Data] = [:]
        for item in plan {
            let data = try TextFile.write(item.text, to: item.url, format: item.format, atomically: true)
            LocalHistory.record(item.url, data: data, merge: false, previous: item.original)
            originals[item.url] = item.original
        }
        return originals
    }

    static func restore(_ originals: [URL: Data]) throws {
        for (url, data) in originals {
            try data.write(to: url, options: .atomic)
            LocalHistory.record(url, data: data, merge: false)
        }
    }
}

final class SearchPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class SearchPanel: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((URL, Int?, String) -> Void)?
    var onReplace: ((String, String, ProjectSearch.Options) -> Void)?
    private let base: URL
    private let panel: SearchPanelWindow
    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let regex = NSButton(checkboxWithTitle: "正規表現", target: nil, action: nil)
    private let caseSensitive = NSButton(checkboxWithTitle: "大文字と小文字を区別", target: nil, action: nil)
    private let replacement = NSTextField()
    private let replaceButton = NSButton(title: "すべて置換…", target: nil, action: nil)
    private static let headerHeight: CGFloat = 88
    private var hits: [SearchHit] = []
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var height: NSLayoutConstraint!
    private var rowHeights: [CGFloat] = []
    private static let textWidth: CGFloat = 576

    init(base: URL) {
        self.base = base
        panel = SearchPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
                                  styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        field.placeholderString = "プロジェクト内を検索（ファイル名・コード）"
        field.font = .systemFont(ofSize: 16)
        field.controlSize = .large
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(queryChanged)
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("hit"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        for toggle in [regex, caseSensitive] {
            toggle.controlSize = .small
            toggle.font = .systemFont(ofSize: 11)
            toggle.target = self
            toggle.action = #selector(queryChanged)
        }
        replacement.placeholderString = "置換後の文字列"
        replacement.controlSize = .small
        replacement.font = .systemFont(ofSize: 12)
        replacement.target = self
        replacement.action = #selector(replaceClicked)
        replaceButton.bezelStyle = .rounded
        replaceButton.controlSize = .small
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        let options = NSStackView(views: [regex, caseSensitive, replacement, replaceButton])
        options.spacing = 10
        options.translatesAutoresizingMaskIntoConstraints = false

        [field, options, scroll, status].forEach(effect.addSubview)
        height = effect.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        NSLayoutConstraint.activate([
            effect.widthAnchor.constraint(equalToConstant: 640),
            height,
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            options.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            options.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            options.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            status.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        updateHeight()
    }

    var isVisible: Bool { panel.isVisible }

    func show(over parent: NSWindow) {
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        place(over: parent)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func close() { panel.close() }

    private func place(over parent: NSWindow) {
        let frame = parent.frame
        let size = panel.frame.size
        let top = frame.maxY - frame.height * 0.18
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: top))
    }

    private func updateHeight() {
        let rows = rowHeights.prefix(9).reduce(0) { $0 + $1 + 2 }
        let showsStatus = !status.stringValue.isEmpty
        status.isHidden = !showsStatus
        scroll.isHidden = hits.isEmpty
        let value = Self.headerHeight + (hits.isEmpty ? 0 : rows + 8) + (showsStatus ? 18 : 0)
        guard abs(height.constant - value) > 0.5 else { return }
        let top = panel.frame.maxY
        height.constant = value
        panel.setContentSize(NSSize(width: 640, height: value))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    func windowDidResignKey(_ notification: Notification) { panel.close() }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        pending?.cancel()
        panel.parent?.removeChildWindow(panel)
    }

    @objc private func queryChanged() {
        pending?.cancel()
        generation += 1
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            hits = []
            rowHeights = []
            status.stringValue = ""
            table.reloadData()
            updateHeight()
            return
        }
        let current = generation
        let base = base
        let options = currentOptions
        guard ProjectSearch.matcher(query, options) != nil else {
            hits = []
            rowHeights = []
            status.stringValue = "正規表現が正しくありません"
            table.reloadData()
            updateHeight()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ProjectSearch.run(query, in: base, options: options) { [weak self] in self?.generation != current }
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    self.hits = found
                    self.rowHeights = found.map(Self.height)
                    let files = found.filter { $0.line == nil }.count
                    self.status.stringValue = found.isEmpty ? "一致するものはありません"
                        : "ファイル名 \(files) 件・コード \(found.count - files) 件" + (found.count >= ProjectSearch.maxHits ? "　·　さらに結果があります（上限 \(ProjectSearch.maxHits) 件）" : "")
                    self.table.reloadData()
                    if !found.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                    self.updateHeight()
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var currentOptions: ProjectSearch.Options {
        ProjectSearch.Options(regex: regex.state == .on, caseSensitive: caseSensitive.state == .on)
    }

    @objc private func replaceClicked() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, ProjectSearch.matcher(query, currentOptions) != nil else { return }
        let options = currentOptions, value = replacement.stringValue
        panel.close()
        onReplace?(query, value, options)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === field else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): panel.close()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let row = max(0, min(hits.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        openSelected()
    }

    private func openSelected() {
        guard hits.indices.contains(table.selectedRow) else { return }
        let hit = hits[table.selectedRow]
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        panel.close()
        onOpen?(hit.url, hit.line, query)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeights.indices.contains(row) ? rowHeights[row] : table.rowHeight
    }

    private static func height(_ hit: SearchHit) -> CGFloat {
        let (title, detail) = labels(hit)
        let size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        return max(ceil(title.sizeThatFits(size).height + detail.sizeThatFits(size).height) + 8, 40)
    }

    private static func wrapping(_ label: NSTextField, lines: Int) {
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = textWidth
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private static func labels(_ hit: SearchHit) -> (title: NSTextField, detail: NSTextField) {
        let title = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        wrapping(title, lines: 3)
        wrapping(detail, lines: 2)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        if let line = hit.line {
            let text = NSMutableAttributedString(string: hit.text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            if NSMaxRange(hit.match) <= text.length, hit.match.location >= 0 {
                text.addAttributes([.backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                    .foregroundColor: NSColor.black], range: hit.match)
            }
            title.attributedStringValue = text
            detail.stringValue = "\(hit.url.lastPathComponent) : \(line) 行目　—　\(hit.relative)"
        } else {
            let text = NSMutableAttributedString(string: hit.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            if NSMaxRange(hit.match) <= text.length {
                text.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: hit.match)
            }
            title.attributedStringValue = text
            detail.stringValue = "ファイル　—　\(hit.relative)"
        }
        return (title, detail)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: hit.line == nil ? NSWorkspace.shared.icon(forFile: hit.url.path)
                                      : NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let (title, detail) = Self.labels(hit)
        [icon, title, detail].forEach(cell.addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
