import AppKit
@testable import FlareStackIDE

final class VariableNode {
    let variable: DAPVariable
    var children: [VariableNode]?

    init(_ variable: DAPVariable) { self.variable = variable }
}

final class DebugFeedView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelectFrame: ((Int) -> Void)?
    var onEvaluate: ((String) -> Void)?
    var onExpand: ((Int, @escaping ([DAPVariable]) -> Void) -> Void)?
    private let stackTable = NSTableView()
    private let variablesOutline = NSOutlineView()
    private let console = NSTextView()
    private let input = NSTextField()
    private var frames: [DAPFrame] = []
    private var roots: [VariableNode] = []
    private var selecting = false
    private let split = NSSplitView()
    private var positioned = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        stackTable.addTableColumn(NSTableColumn(identifier: .init("frame")))
        stackTable.headerView = nil
        stackTable.dataSource = self
        stackTable.delegate = self
        stackTable.rowHeight = 20
        stackTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("variable"))
        variablesOutline.addTableColumn(column)
        variablesOutline.outlineTableColumn = column
        variablesOutline.headerView = nil
        variablesOutline.dataSource = self
        variablesOutline.delegate = self
        variablesOutline.rowHeight = 18
        variablesOutline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        console.isEditable = false
        console.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        console.textContainerInset = NSSize(width: 4, height: 4)
        console.isVerticallyResizable = true
        console.autoresizingMask = [.width]
        input.placeholderString = "式を評価（停止中のフレームで実行）"
        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.target = self
        input.action = #selector(submit)
        let consoleScroll = NSScrollView()
        consoleScroll.documentView = console
        consoleScroll.hasVerticalScroller = true
        let consoleBox = NSStackView(views: [consoleScroll, input])
        consoleBox.orientation = .vertical
        consoleBox.spacing = 4
        consoleBox.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 4)
        split.addArrangedSubview(section("呼び出し履歴", stackTable))
        split.addArrangedSubview(section("変数", variablesOutline))
        split.addArrangedSubview(section("デバッグコンソール", consoleBox, scroll: false))
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !positioned, split.bounds.width > 300, split.arrangedSubviews.count == 3 else { return }
        positioned = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let width = self.split.bounds.width
            self.split.setPosition(width * 0.3, ofDividerAt: 0)
            self.split.setPosition(width * 0.62, ofDividerAt: 1)
        }
    }

    private func section(_ title: String, _ content: NSView, scroll: Bool = true) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let body: NSView
        if scroll {
            let wrapper = NSScrollView()
            wrapper.documentView = content
            wrapper.hasVerticalScroller = true
            wrapper.drawsBackground = false
            body = wrapper
        } else {
            body = content
        }
        let stack = NSStackView(views: [label, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 4)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        return stack
    }

    var selectedFrame: Int? { stackTable.selectedRow >= 0 ? stackTable.selectedRow : nil }

    func reset() {
        frames = []
        roots = []
        stackTable.reloadData()
        variablesOutline.reloadData()
        console.string = ""
    }

    func showFrames(_ frames: [DAPFrame]) {
        self.frames = frames
        stackTable.reloadData()
        if frames.isEmpty {
            roots = []
            variablesOutline.reloadData()
        }
    }

    func selectFrame(_ index: Int) {
        selecting = true
        stackTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selecting = false
    }

    func showVariables(_ scopes: [DAPVariable]) {
        roots = scopes.map(VariableNode.init)
        variablesOutline.reloadData()
        if let first = roots.first, first.variable.reference > 0 { variablesOutline.expandItem(first) }
    }

    func append(_ text: String, category: String) {
        let color: NSColor = switch category {
        case "stderr": .systemRed
        case "input": .secondaryLabelColor
        case "console": .tertiaryLabelColor
        default: .labelColor
        }
        console.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]))
        console.scrollToEndOfDocument(nil)
    }

    @objc private func submit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        onEvaluate?(text)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { frames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let frame = frames[row]
        let place = frame.path.map { "\(($0 as NSString).lastPathComponent):\(frame.line)" } ?? "—"
        let label = NSTextField(labelWithString: "\(frame.name)  \(place)")
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = frame.path == nil ? .tertiaryLabelColor : .labelColor
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, stackTable.selectedRow >= 0 else { return }
        onSelectFrame?(stackTable.selectedRow)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? VariableNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? VariableNode else { return roots[index] }
        return node.children?[index] ?? node
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? VariableNode)?.variable.reference ?? 0 > 0
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? VariableNode, node.children == nil else { return }
        node.children = []
        onExpand?(node.variable.reference) { [weak self, weak node] variables in
            guard let self, let node else { return }
            node.children = variables.map(VariableNode.init)
            self.variablesOutline.reloadItem(node, reloadChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let variable = (item as? VariableNode)?.variable else { return nil }
        let text = NSMutableAttributedString(string: variable.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: variable.value.isEmpty ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor])
        if !variable.value.isEmpty {
            text.append(NSAttributedString(string: " = \(variable.value)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = variable.type.map { "\(variable.name): \($0)" }
        return label
    }
}
