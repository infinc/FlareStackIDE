import AppKit
@testable import FlareStackIDE

final class OutlineSymbol {
    let name: String
    let kind: Int
    let detail: String
    let start: Int
    var end: Int
    let selection: Int
    var children: [OutlineSymbol]

    init(name: String, kind: Int, detail: String = "", start: Int, end: Int, selection: Int, children: [OutlineSymbol] = []) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.start = start
        self.end = end
        self.selection = selection
        self.children = children
    }

    static let heading = 100

    convenience init?(lsp item: [String: Any]) {
        guard let name = item["name"] as? String, let start = item["start"] as? Int else { return nil }
        let length = item["length"] as? Int ?? 0
        let children = (item["children"] as? [[String: Any]] ?? []).compactMap { OutlineSymbol(lsp: $0) }
        self.init(name: name, kind: item["kind"] as? Int ?? 0, detail: item["detail"] as? String ?? "",
                  start: start, end: start + length, selection: item["selection"] as? Int ?? start, children: children)
    }

    func contains(_ offset: Int) -> Bool { start <= offset && offset < max(end, start + 1) }

    var symbolName: String {
        switch kind {
        case 5, 23, 26: return "c.square"
        case 6, 9, 12, 24, 25: return "f.square"
        case 7, 8, 13, 14, 20: return "v.square"
        case 10, 22: return "e.square"
        case 11: return "p.square"
        case 2, 3, 4, 1: return "m.square"
        case Self.heading: return "number"
        default: return "circle.square"
        }
    }

    var tint: NSColor {
        switch kind {
        case 5, 23, 26: return .systemOrange
        case 6, 9, 12, 24, 25: return .systemPurple
        case 7, 8, 13, 14, 20: return .systemBlue
        case 10, 22: return .systemGreen
        case 11: return .systemTeal
        default: return .secondaryLabelColor
        }
    }

    static func nest(_ flat: [OutlineSymbol]) -> [OutlineSymbol] {
        var roots: [OutlineSymbol] = []
        var stack: [OutlineSymbol] = []
        for symbol in flat.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }) {
            while let last = stack.last, !(last.start <= symbol.start && symbol.end <= last.end) { stack.removeLast() }
            if let parent = stack.last { parent.children.append(symbol) } else { roots.append(symbol) }
            stack.append(symbol)
        }
        return roots
    }
}

enum OutlineScan {
    private static let modifiers = #"(?:(?:public|private|internal|fileprivate|open|static|final|override|export|default|async|abstract|protected|sealed|data|inline|virtual|extern|unsafe|mutating|nonisolated|pub(?:\([^)]*\))?|@\w+(?:\([^)]*\))?)\s+)*"#
    private static let types = try! NSRegularExpression(pattern: #"^([ \t]*)"# + modifiers
        + #"(class|struct|enum|protocol|interface|extension|actor|trait|impl|module|namespace|object|union)\s+([A-Za-z_][\w.]*)"#)
    private static let functions = try! NSRegularExpression(pattern: #"^([ \t]*)"# + modifiers
        + #"(func|def|fn|function|fun|sub|proc|init|deinit)\b\s*(?:\([^)]*\)\s*)?([A-Za-z_$][\w$]*[?!]?)?"#)
    private static let arrows = try! NSRegularExpression(pattern: #"^([ \t]*)(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>)"#)
    private static let headings = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$"#)
    private static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let kinds: [String: Int] = ["class": 5, "struct": 23, "enum": 10, "protocol": 11, "interface": 11, "extension": 5,
                                               "actor": 5, "trait": 11, "impl": 5, "module": 2, "namespace": 3, "object": 5, "union": 23,
                                               "init": 9, "deinit": 9]

    static func scan(_ text: String, ext: String) -> [OutlineSymbol] {
        let ns = text as NSString
        let isMarkdown = markdown.contains(ext)
        var roots: [OutlineSymbol] = []
        var stack: [(level: Int, symbol: OutlineSymbol)] = []
        var location = 0
        var count = 0
        var fenced = false
        func close(at offset: Int, below level: Int) {
            while let last = stack.last, last.level >= level {
                last.symbol.end = offset
                stack.removeLast()
            }
        }
        while location < ns.length, count < 50000 {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(range); count += 1 }
            let line = ns.substring(with: range).trimmingCharacters(in: .newlines)
            if isMarkdown, line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, let (symbol, level) = match(line, offset: range.location, markdown: isMarkdown) else {
                if !isMarkdown, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    if let last = stack.last, indent <= last.level, !line.trimmingCharacters(in: .whitespaces).hasPrefix("}") || indent < last.level {
                        close(at: range.location, below: indent)
                    }
                }
                continue
            }
            close(at: range.location, below: level)
            if let parent = stack.last?.symbol { parent.children.append(symbol) } else { roots.append(symbol) }
            stack.append((level, symbol))
        }
        close(at: ns.length, below: Int.min)
        return roots
    }

    private static func match(_ line: String, offset: Int, markdown: Bool) -> (OutlineSymbol, Int)? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        let group = { (m: NSTextCheckingResult, i: Int) -> String? in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        if markdown {
            guard let m = headings.firstMatch(in: line, range: all), let marks = group(m, 1), let title = group(m, 2) else { return nil }
            return (OutlineSymbol(name: title, kind: OutlineSymbol.heading, start: offset, end: offset + ns.length,
                                  selection: offset + m.range(at: 2).location), marks.count)
        }
        if let m = types.firstMatch(in: line, range: all), let keyword = group(m, 2), let name = group(m, 3) {
            let indent = m.range(at: 1).length
            return (OutlineSymbol(name: name, kind: kinds[keyword] ?? 5, detail: keyword, start: offset, end: offset + ns.length,
                                  selection: offset + m.range(at: 3).location), indent)
        }
        if let m = functions.firstMatch(in: line, range: all), let keyword = group(m, 2) {
            let name = group(m, 3) ?? keyword
            guard name != keyword || keyword == "init" || keyword == "deinit" else { return nil }
            let indent = m.range(at: 1).length
            let kind = kinds[keyword] ?? (indent > 0 ? 6 : 12)
            let at = m.range(at: 3).location == NSNotFound ? m.range(at: 2).location : m.range(at: 3).location
            return (OutlineSymbol(name: name, kind: kind, start: offset, end: offset + ns.length, selection: offset + at), indent)
        }
        if let m = arrows.firstMatch(in: line, range: all), let name = group(m, 2) {
            return (OutlineSymbol(name: name, kind: 12, start: offset, end: offset + ns.length,
                                  selection: offset + m.range(at: 2).location), m.range(at: 1).length)
        }
        return nil
    }
}

final class OutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((OutlineSymbol) -> Void)?
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let empty = NSTextField(labelWithString: "シンボルはありません")
    private var roots: [OutlineSymbol] = []
    private var shown: [OutlineSymbol] = []
    private var filtering: Bool { !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    private var programmatic = false

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("symbol"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        search.placeholderString = "絞り込み"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.delegate = self
        empty.textColor = .tertiaryLabelColor
        [search, scroll, empty].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ symbols: [OutlineSymbol]) {
        roots = symbols
        apply()
    }

    private func apply() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            shown = roots
        } else {
            func flatten(_ list: [OutlineSymbol]) -> [OutlineSymbol] { list.flatMap { [$0] + flatten($0.children) } }
            shown = flatten(roots).filter { $0.name.lowercased().contains(query) }
        }
        empty.isHidden = !shown.isEmpty
        outline.reloadData()
        if !filtering { outline.expandItem(nil, expandChildren: true) }
    }

    func reveal(_ offset: Int) {
        guard !filtering else { return }
        var path: [OutlineSymbol] = []
        var level = roots
        while let found = level.last(where: { $0.contains(offset) }) {
            path.append(found)
            level = found.children
        }
        programmatic = true
        defer { programmatic = false }
        guard let target = path.last else { return outline.deselectAll(nil) }
        path.dropLast().forEach { outline.expandItem($0) }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func controlTextDidChange(_ obj: Notification) { apply() }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let symbol = item as? OutlineSymbol else { return shown.count }
        return filtering ? 0 : symbol.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let symbol = item as? OutlineSymbol else { return shown[index] }
        return symbol.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !filtering && !((item as? OutlineSymbol)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let symbol = item as? OutlineSymbol else { return nil }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = symbol.tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let name = NSTextField(labelWithString: symbol.name)
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: symbol.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let stack = NSStackView(views: [icon, name, detail])
        stack.spacing = 5
        stack.toolTip = symbol.detail.isEmpty ? symbol.name : "\(symbol.name)  \(symbol.detail)"
        return stack
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !programmatic, NSApp.currentEvent?.type == .keyDown, let symbol = outline.item(atRow: outline.selectedRow) as? OutlineSymbol else { return }
        onSelect?(symbol)
    }

    @objc private func rowClicked() {
        guard let symbol = outline.item(atRow: outline.clickedRow) as? OutlineSymbol else { return }
        onSelect?(symbol)
    }
}
