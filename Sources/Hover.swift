import AppKit

private final class HoverShade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum ButtonHover {
    private static let shade = HoverShade()
    private static weak var hovered: NSView?

    static func tint(for view: NSView) -> NSColor {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in set(nil) }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { event in
            update(event)
            return event
        }
    }

    private static func update(_ event: NSEvent) {
        guard let content = event.window?.contentView, let frame = content.superview else { return set(nil) }
        let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil))
        set(hit.flatMap { sequence(first: $0, next: \.superview).first(where: isTarget) })
    }

    private static func isTarget(_ view: NSView) -> Bool {
        if let button = view as? NSButton { return button.isEnabled }
        return view is TabItemView
    }

    private static func set(_ view: NSView?) {
        guard view !== hovered else { return }
        hovered = view
        shade.removeFromSuperview()
        guard let view else { return }
        let insets = view.alignmentRectInsets
        shade.frame = NSRect(x: insets.left, y: insets.bottom, width: view.bounds.width - insets.left - insets.right,
                             height: view.bounds.height - insets.top - insets.bottom)
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.layer?.cornerRadius = 5
        shade.layer?.backgroundColor = tint(for: view).withAlphaComponent(0.14).cgColor
        view.addSubview(shade)
    }
}
