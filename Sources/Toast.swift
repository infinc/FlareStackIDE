import AppKit

enum ToastSize: String, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 260
        case .medium: return 320
        case .large: return 400
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1
        case .large: return 1.2
        }
    }
}

final class CountdownBar: NSView {
    var fraction: CGFloat = 1 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var fill = bounds
        fill.size.width *= max(min(fraction, 1), 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

final class Toast: NSVisualEffectView {
    typealias Action = (title: String, handler: () -> Void)

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let countdown = CountdownBar()
    private var timer: Timer?
    private var total: TimeInterval = 0
    private var remaining: TimeInterval = 0
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, message: String? = nil, actions: [Action] = [], showsProgress: Bool = false) {
        super.init(frame: .zero)
        let size = Settings.toastSize
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12 * size.scale, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.stringValue = message ?? (showsProgress ? "準備しています…" : "")
        messageLabel.font = .systemFont(ofSize: 11 * size.scale)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = messageLabel.stringValue.isEmpty
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = !showsProgress
        countdown.isHidden = true

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "閉じる")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9 * size.scale, weight: .semibold))!,
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.toolTip = "通知を閉じる"
        close.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, close])
        header.spacing = 6

        var views: [NSView] = [header, messageLabel, progress]
        if !actions.isEmpty {
            let buttons = NSStackView(views: actions.map { action in
                let button = ToastButton(title: action.title) { [weak self] in
                    action.handler()
                    self?.dismiss()
                }
                button.controlSize = size == .small ? .small : .regular
                return button
            })
            buttons.spacing = 6
            views.append(buttons)
        }
        views.append(countdown)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6 * size.scale
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -22),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            countdown.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            countdown.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    func update(_ status: String, _ value: Double) {
        messageLabel.stringValue = status
        messageLabel.isHidden = false
        progress.doubleValue = value
    }

    func finish(_ status: String, failed: Bool = false) {
        update(status, failed ? progress.doubleValue : 1)
        messageLabel.textColor = failed ? .systemRed : .systemGreen
        startCountdown(Settings.toastDuration * (failed ? 2 : 1))
    }

    func startCountdown(_ seconds: TimeInterval = Settings.toastDuration) {
        timer?.invalidate()
        total = max(seconds, 0.5)
        remaining = total
        countdown.fraction = 1
        countdown.isHidden = false
        let step: TimeInterval = 1.0 / 30
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.hovered { self.remaining -= step }
            self.countdown.fraction = CGFloat(self.remaining / self.total)
            if self.remaining <= 0 { self.dismiss() }
        }
    }

    @objc func dismiss() {
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in
            self?.removeFromSuperview()
        }
    }
}

private final class ToastButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
    }

    @objc private func clicked() { handler?() }
}

private final class HintLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum Toasts {
    private static let containerID = NSUserInterfaceItemIdentifier("FlareStackIDE.toasts")
    private static weak var hintView: NSView?

    static func hint(_ text: String, under view: NSView) {
        guard let content = view.window?.contentView else { return }
        hintView?.removeFromSuperview()
        let label = HintLabel(labelWithString: "  \(text)  ")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 9
        label.sizeToFit()
        label.setFrameSize(NSSize(width: label.frame.width, height: 18))
        let anchor = view.convert(view.bounds, to: content)
        label.setFrameOrigin(NSPoint(x: min(anchor.midX - label.frame.width / 2, content.bounds.maxX - label.frame.width - 6), y: anchor.minY - 24))
        label.alphaValue = 0
        content.addSubview(label, positioned: .above, relativeTo: nil)
        hintView = label
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            label.animator().alphaValue = 1
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    label.animator().alphaValue = 0
                }) { label.removeFromSuperview() }
            }
        }
    }

    private static var target: NSWindow? {
        ([NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows).compactMap { $0 }.first {
            !($0 is NSPanel) && $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil
        }
    }

    @discardableResult
    static func post(_ title: String, message: String? = nil, actions: [Toast.Action] = [], in window: NSWindow? = nil) -> Toast? {
        let toast = Toast(title: title, message: message, actions: actions)
        guard show(toast, in: window) else { return nil }
        toast.startCountdown()
        return toast
    }

    static func progress(_ title: String, in window: NSWindow? = nil) -> Toast? {
        let toast = Toast(title: title, showsProgress: true)
        return show(toast, in: window) ? toast : nil
    }

    private static func show(_ toast: Toast, in window: NSWindow?) -> Bool {
        guard let content = (window ?? target)?.contentView else { return false }
        container(in: content).addArrangedSubview(toast)
        return true
    }

    private static func container(in content: NSView) -> NSStackView {
        if let existing = content.subviews.first(where: { $0.identifier == containerID }) as? NSStackView { return existing }
        let stack = NSStackView()
        stack.identifier = containerID
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        return stack
    }
}
