import AppKit
import QuartzCore

private final class DragOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DragLift {
    enum Axis { case horizontal, vertical, free }

    private let axis: Axis
    private let overlay = DragOverlay()
    private let lifted = CALayer()
    private let start: NSPoint
    private let origin: CGPoint
    private var last: NSPoint

    init?(view: NSView, rect: NSRect? = nil, event: NSEvent, axis: Axis, background: NSColor? = nil) {
        let rect = rect ?? view.bounds
        guard let content = view.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        self.axis = axis
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        lifted.frame = view.convert(rect, to: overlay)
        lifted.contents = image
        lifted.contentsScale = view.window?.backingScaleFactor ?? 2
        lifted.backgroundColor = background?.cgColor
        lifted.cornerRadius = 5
        lifted.shadowColor = NSColor.black.cgColor
        lifted.shadowRadius = 10
        lifted.shadowOffset = CGSize(width: 0, height: -6)
        lifted.shadowOpacity = 0
        overlay.layer?.addSublayer(lifted)
        origin = lifted.position
        start = overlay.convert(event.locationInWindow, from: nil)
        last = start
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        lifted.transform = Self.lift(tiltX: 0, tiltY: 0)
        lifted.shadowOpacity = 0.35
        CATransaction.commit()
    }

    private static func lift(tiltX: CGFloat, tiltY: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = -1 / 400
        t = CATransform3DTranslate(t, 0, 0, 30)
        t = CATransform3DScale(t, 1.08, 1.08, 1)
        t = CATransform3DRotate(t, tiltX, 0, 1, 0)
        return CATransform3DRotate(t, tiltY, 1, 0, 0)
    }

    func move(_ event: NSEvent) {
        let p = overlay.convert(event.locationInWindow, from: nil)
        let dx = axis == .vertical ? 0 : p.x - last.x
        let dy = axis == .horizontal ? 0 : p.y - last.y
        last = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifted.position = CGPoint(x: origin.x + (axis == .vertical ? 0 : p.x - start.x),
                                  y: origin.y + (axis == .horizontal ? 0 : p.y - start.y))
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        lifted.transform = Self.lift(tiltX: max(-0.4, min(0.4, dx * 0.04)), tiltY: max(-0.4, min(0.4, dy * -0.04)))
        CATransaction.commit()
    }

    func land(on view: NSView, rect: NSRect? = nil, absorb: Bool = false, done: @escaping () -> Void) {
        let frame = view.convert(rect ?? view.bounds, to: overlay)
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: lifted.presentation()?.position ?? lifted.position)
        spring.toValue = NSValue(point: target)
        spring.damping = 18
        spring.stiffness = 260
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        CATransaction.setCompletionBlock { [overlay] in
            overlay.removeFromSuperview()
            done()
        }
        if !absorb { lifted.add(spring, forKey: "drop") }
        lifted.position = target
        lifted.transform = absorb ? CATransform3DMakeScale(0.6, 0.6, 1) : CATransform3DIdentity
        if absorb { lifted.opacity = 0 }
        lifted.shadowOpacity = 0
        CATransaction.commit()
    }
}

final class DragReorder {
    private let view: NSView
    private let stack: NSStackView
    private let movable: (NSView) -> Bool
    private let vertical: Bool
    private let lift: DragLift
    private(set) var moved = false

    init?(view: NSView, event: NSEvent, movable: @escaping (NSView) -> Bool = { _ in true }) {
        guard let stack = view.superview as? NSStackView else { return nil }
        vertical = stack.orientation == .vertical
        guard let lift = DragLift(view: view, event: event, axis: vertical ? .vertical : .horizontal) else { return nil }
        self.view = view
        self.stack = stack
        self.movable = movable
        self.lift = lift
        stack.wantsLayer = true
        view.alphaValue = 0
    }

    private func axis(_ p: NSPoint) -> CGFloat { vertical ? p.y : p.x }

    func drag(_ event: NSEvent) {
        moved = true
        lift.move(event)
        reorder(at: stack.convert(event.locationInWindow, from: nil))
    }

    private func reorder(at point: NSPoint) {
        let items = stack.arrangedSubviews.filter { !$0.isHidden && movable($0) }
        guard let mine = items.firstIndex(of: view) else { return }
        let here = axis(NSPoint(x: view.frame.midX, y: view.frame.midY))
        for neighbor in [mine - 1, mine + 1] where items.indices.contains(neighbor) {
            let other = items[neighbor]
            let there = axis(NSPoint(x: other.frame.midX, y: other.frame.midY))
            guard (axis(point) - there) * (there - here) > 0 else { continue }
            guard let index = stack.arrangedSubviews.firstIndex(of: other) else { return }
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: index)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                stack.layoutSubtreeIfNeeded()
            }
            return
        }
    }

    func end(_ done: (() -> Void)? = nil) {
        stack.layoutSubtreeIfNeeded()
        lift.land(on: view) { [view] in
            view.alphaValue = 1
            done?()
        }
    }
}

final class TabItemView: NSView, NSTextFieldDelegate {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onMove: (() -> Void)?
    var draggable = false
    var contextMenu: (() -> NSMenu?)?
    private var dragStart: NSEvent?
    private var reorder: DragReorder?
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
        dragStart = event
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggable, let start = dragStart else { return }
        if reorder == nil {
            guard abs(event.locationInWindow.x - start.locationInWindow.x) > 4 else { return }
            reorder = DragReorder(view: self, event: start) { $0 is TabItemView }
        }
        reorder?.drag(event)
    }

    override func mouseUp(with event: NSEvent) {
        if let reorder {
            reorder.end()
            onMove?()
        }
        reorder = nil
        dragStart = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

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
        stack.setHuggingPriority(.required, for: .horizontal)
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
