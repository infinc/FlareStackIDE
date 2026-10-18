import AppKit

final class TabItemView: NSView, NSTextFieldDelegate {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onMove: (() -> Void)?
    var draggable = false
    private var dragStart: CGFloat?
    private var dragged = false
    private var oldTitle = ""
    var selected = false { didSet { updateColor() } }
    var plain = false { didSet { needsDisplay = true } }
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    private let label = NSTextField(labelWithString: "")

    init(title: String, closable: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        updateColor()
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ]
        if closable {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "閉じる")!
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))!,
                                 target: self, action: #selector(closeClicked))
            close.isBordered = false
            close.toolTip = "タブを閉じる"
            close.translatesAutoresizingMaskIntoConstraints = false
            addSubview(close)
            constraints += [
                close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                close.centerYAnchor.constraint(equalTo: centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 16),
                close.heightAnchor.constraint(equalToConstant: 16),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, onRename != nil {
            beginRename()
            return
        }
        dragStart = event.locationInWindow.x
        dragged = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggable, let start = dragStart, let stack = superview as? NSStackView else { return }
        let dx = event.locationInWindow.x - start
        guard dragged || abs(dx) > 4 else { return }
        dragged = true
        let tabs = stack.arrangedSubviews.filter { $0 is TabItemView }
        guard let mine = tabs.firstIndex(of: self) else { return }
        let x = stack.convert(event.locationInWindow, from: nil).x
        if mine + 1 < tabs.count, x > tabs[mine + 1].frame.midX {
            move(in: stack, after: tabs[mine + 1])
            dragStart = event.locationInWindow.x
        } else if mine > 0, x < tabs[mine - 1].frame.midX {
            move(in: stack, before: tabs[mine - 1])
            dragStart = event.locationInWindow.x
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMove?() }
        dragStart = nil
        dragged = false
    }

    private func move(in stack: NSStackView, after: NSView? = nil, before: NSView? = nil) {
        stack.removeArrangedSubview(self)
        let anchor = (after ?? before)!
        guard let index = stack.arrangedSubviews.firstIndex(of: anchor) else { return }
        stack.insertArrangedSubview(self, at: after != nil ? index + 1 : index)
        stack.layoutSubtreeIfNeeded()
    }

    private func beginRename() {
        oldTitle = label.stringValue
        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = false
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.delegate = self
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        let name = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            label.stringValue = oldTitle
        } else {
            onRename?(name)
        }
    }

    private func updateColor() {
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !plain else { return }
        let color = selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25)
                             : NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    @objc private func closeClicked() { onClose?() }
}

final class TabStrip: NSView {
    let stack = NSStackView()
    private let scroll = NSScrollView()

    init(trailing: NSView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        var constraints = [
            heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            addSubview(trailing)
            constraints += [
                scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -4),
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                trailing.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ]
        } else {
            constraints.append(scroll.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        NotificationCenter.default.addObserver(self, selector: #selector(applyColors), name: .settingsChanged, object: nil)
        applyColors()
    }

    @objc private func applyColors() { paint(.midTab) }

    required init?(coder: NSCoder) { fatalError() }

    func reveal(_ view: NSView) {
        layoutSubtreeIfNeeded()
        view.scrollToVisible(view.bounds)
    }
}

final class FeedView: NSView {
    var onRemove: (() -> Void)?
    let content: NSView
    private var tab: TabItemView!
    var title: String {
        get { tab.title }
        set { tab.title = newValue }
    }

    static func barButton(symbol: String, tip: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))!,
                              target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    static func trailingStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        return stack
    }

    init(title: String, content: NSView, extras: [NSView] = []) {
        self.content = content
        super.init(frame: .zero)
        let minus = Self.barButton(symbol: "minus", tip: "フィードを閉じる", target: nil, action: nil)
        let bar = TabStrip(trailing: Self.trailingStack(extras + [minus]))
        tab = TabItemView(title: title, closable: false)
        tab.selected = true
        tab.plain = true
        bar.stack.addArrangedSubview(tab)
        minus.target = self
        minus.action = #selector(minusClicked)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyColors), name: .settingsChanged, object: nil)
        applyColors()
    }

    @objc private func applyColors() { paint(.feed) }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func minusClicked() { onRemove?() }
}
