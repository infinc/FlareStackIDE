import AppKit

final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String, color: NSColor, symbol: String? = nil, mono: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        label.stringValue = text
        label.font = mono ? .monospacedSystemFont(ofSize: 10.5, weight: .medium) : .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [label]
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))!)
            icon.contentTintColor = color
            views.insert(icon, at: 0)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class TimelineCell: NSTableCellView {
    static let spacing: CGFloat = 14
    static let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemRed, .systemIndigo, .systemBrown]
    var graph = GraphRow()
    var head = false

    static func x(_ lane: Int) -> CGFloat { 16 + CGFloat(lane) * spacing }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        func stroke(_ from: Int, _ to: Int, _ y0: CGFloat, _ y1: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            let a = NSPoint(x: Self.x(from), y: y0), b = NSPoint(x: Self.x(to), y: y1)
            path.move(to: a)
            if from == to { path.line(to: b) }
            else { path.curve(to: b, controlPoint1: NSPoint(x: a.x, y: (y0 + y1) / 2), controlPoint2: NSPoint(x: b.x, y: (y0 + y1) / 2)) }
            Self.colors[(from == graph.lane ? to : from) % Self.colors.count].setStroke()
            path.stroke()
        }
        graph.upper.forEach { stroke($0.0, $0.1, bounds.minY, mid) }
        graph.lower.forEach { stroke($0.0, $0.1, mid, bounds.maxY) }
        let r: CGFloat = head ? 6 : 4.5
        let dot = NSRect(x: Self.x(graph.lane) - r, y: mid - r, width: r * 2, height: r * 2)
        Self.colors[graph.lane % Self.colors.count].setFill()
        NSBezierPath(ovalIn: dot).fill()
        if head {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 2.5, dy: 2.5)).fill()
        }
    }

    override var isFlipped: Bool { true }
}

final class GitPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let header = NSStackView()
    private let sidebar = NSStackView()
    private let table = NSTableView()
    private let historyTitle = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private var commits: [GitCommit] = []
    private var graph: [GraphRow] = []
    private var graphWidth = 1

    init() {
        super.init(frame: .zero)
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerLine = NSBox()
        headerLine.boxType = .separator
        headerLine.translatesAutoresizingMaskIntoConstraints = false

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sidebar)
        let sideScroll = NSScrollView()
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: sideScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: sideScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: sideScroll.contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: document.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let column = NSTableColumn(identifier: .init("commit"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        historyTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        historyTitle.textColor = .secondaryLabelColor
        historyTitle.translatesAutoresizingMaskIntoConstraints = false
        let history = NSView()
        history.addSubview(historyTitle)
        history.addSubview(tableScroll)
        NSLayoutConstraint.activate([
            historyTitle.topAnchor.constraint(equalTo: history.topAnchor, constant: 10),
            historyTitle.leadingAnchor.constraint(equalTo: history.leadingAnchor, constant: 14),
            tableScroll.topAnchor.constraint(equalTo: historyTitle.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: history.bottomAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sideScroll)
        split.addArrangedSubview(history)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false

        [header, headerLine, split, empty].forEach(addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        DispatchQueue.main.async { [weak self] in self?.split.setPosition(240, ofDividerAt: 0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ info: GitOverview?) {
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let info else {
            split.isHidden = true
            empty.isHidden = false
            empty.stringValue = "このディレクトリはgitで追跡されていません。"
            commits = []
            graph = []
            table.reloadData()
            return
        }
        split.isHidden = false
        empty.isHidden = true
        buildHeader(info)
        buildSidebar(info)
        commits = info.commits
        graph = GraphRow.layout(commits)
        graphWidth = min(graph.map(\.width).max() ?? 1, 12)
        historyTitle.stringValue = "コミット履歴（全ブランチ）　\(info.total)"
        table.reloadData()
        table.scrollRowToVisible(0)
    }

    private func buildHeader(_ info: GitOverview) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "ブランチ")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))!)
        icon.contentTintColor = .controlAccentColor
        let name = NSTextField(labelWithString: info.branch)
        name.font = .systemFont(ofSize: 15, weight: .bold)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(name)
        if let upstream = info.upstream {
            let arrow = NSTextField(labelWithString: "→ \(upstream)")
            arrow.font = .systemFont(ofSize: 12)
            arrow.textColor = .secondaryLabelColor
            header.addArrangedSubview(arrow)
            header.addArrangedSubview(Pill("\(info.ahead) 件 push 待ち", color: info.ahead > 0 ? .systemBlue : .secondaryLabelColor, symbol: "arrow.up"))
            header.addArrangedSubview(Pill("\(info.behind) 件 pull 待ち", color: info.behind > 0 ? .systemPurple : .secondaryLabelColor, symbol: "arrow.down"))
        } else {
            header.addArrangedSubview(Pill("リモート未設定", color: .secondaryLabelColor, symbol: "icloud.slash"))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(spacer)
        let counts: [(String, GitChange.Kind, NSColor)] = [("未追跡", .untracked, .systemOrange), ("追加", .added, .systemGreen), ("変更", .modified, .systemCyan), ("削除", .deleted, .systemRed)]
        for (title, kind, color) in counts {
            let n = info.changes.filter { $0.kind == kind }.count
            header.addArrangedSubview(Pill("\(title) \(n)", color: n > 0 ? color : .tertiaryLabelColor))
        }
    }

    private func section(_ text: String, count: Int) {
        let label = NSTextField(labelWithString: "\(text)　\(count)")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let wrap = NSStackView(views: [label])
        wrap.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 4, right: 10)
        sidebar.addArrangedSubview(wrap)
    }

    private func row(_ views: [NSView], tip: String? = nil) {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 2, right: 10)
        stack.toolTip = tip
        sidebar.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))!)
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func buildSidebar(_ info: GitOverview) {
        section("変更されたファイル", count: info.changes.count)
        if info.changes.isEmpty {
            row([symbol("checkmark.circle.fill", .systemGreen), label("変更はありません", color: .secondaryLabelColor)])
        }
        for change in info.changes.prefix(300) {
            let badge = label(change.letter, size: 10, weight: .bold, color: change.color)
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 3
            badge.layer?.backgroundColor = change.color.withAlphaComponent(0.18).cgColor
            badge.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let file = (change.path as NSString).lastPathComponent
            let dir = (change.path as NSString).deletingLastPathComponent
            var views: [NSView] = [badge, label(file, weight: .medium)]
            if !dir.isEmpty { views.append(label(dir, size: 10.5, color: .tertiaryLabelColor)) }
            row(views, tip: change.path + (change.staged ? "（ステージ済み）" : ""))
        }
        section("ローカルブランチ", count: info.local.count)
        for branch in info.local {
            let current = branch == info.branch
            row([symbol(current ? "checkmark.circle.fill" : "circle", current ? .systemGreen : .tertiaryLabelColor),
                 label(branch, weight: current ? .bold : .regular)])
        }
        section("リモートブランチ", count: info.remote.count)
        for branch in info.remote {
            row([symbol("cloud", .secondaryLabelColor), label(branch, color: .secondaryLabelColor)])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let commit = commits[row]
        let cell = TimelineCell()
        cell.graph = graph[row]
        cell.head = commit.head
        let subject = label(commit.subject, size: 12.5, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail
        let top = NSStackView(views: [subject] + commit.refs.prefix(4).map { ref in
            Pill(ref, color: ref.hasPrefix("tag: ") ? .systemYellow : ref.contains("/") ? .systemPurple : .systemGreen,
                 symbol: ref.hasPrefix("tag: ") ? "tag" : ref.contains("/") ? "cloud" : "arrow.triangle.branch")
        })
        top.spacing = 6
        let hash = Pill(commit.hash, color: .secondaryLabelColor, mono: true)
        let meta = label("\(commit.author)　·　\(commit.date)", size: 11, color: .secondaryLabelColor)
        let bottom = NSStackView(views: [hash, meta])
        bottom.spacing = 6
        let texts = NSStackView(views: [top, bottom])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(texts)
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: TimelineCell.x(graphWidth - 1) + 18),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            texts.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = "\(commit.hash)  \(commit.subject)"
        return cell
    }
}
