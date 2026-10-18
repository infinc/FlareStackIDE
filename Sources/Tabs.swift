import AppKit

final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
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

    override func mouseDown(with event: NSEvent) { onSelect?() }

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
        let tab = TabItemView(title: title, closable: false)
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
