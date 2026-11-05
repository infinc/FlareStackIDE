import AppKit

private final class HoverShade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

protocol HoverRefreshing: AnyObject {
    func refreshHover()
}

enum ButtonHover {
    private static let shade = HoverShade()
    private static weak var hovered: NSView?
    private static var restingTint: NSColor?
    private static var refreshQueued = false

    static func tint(for view: NSView) -> NSColor {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    static func activeFill(for view: NSView) -> NSColor { tint(for: view).withAlphaComponent(0.14) }

    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            set(nil)
            refreshTree((note.object as? NSWindow)?.contentView)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .scrollWheel]) { event in
            if event.type == .scrollWheel { queueRefresh(event.window) } else { update(event.window, event.locationInWindow) }
            return event
        }
    }

    static func isUnderMouse(_ view: NSView) -> Bool {
        guard let window = view.window, window.isKeyWindow, !view.isHiddenOrHasHiddenAncestor else { return false }
        return view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private static func queueRefresh(_ window: NSWindow?) {
        guard let window, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async {
            refreshQueued = false
            if window.isKeyWindow { update(window, window.mouseLocationOutsideOfEventStream) }
            refreshTree(window.contentView)
        }
    }

    private static func refreshTree(_ view: NSView?) {
        guard let view else { return }
        (view as? HoverRefreshing)?.refreshHover()
        view.subviews.forEach(refreshTree)
    }

    private static func update(_ window: NSWindow?, _ location: NSPoint) {
        guard let content = window?.contentView, let frame = content.superview else { return set(nil) }
        let hit = content.hitTest(frame.convert(location, from: nil))
        set(hit.flatMap { sequence(first: $0, next: \.superview).first(where: isTarget) })
    }

    private static func isTarget(_ view: NSView) -> Bool {
        if let button = view as? NSButton { return button.isEnabled }
        return view is TabItemView
    }

    private static func isIcon(_ button: NSButton) -> Bool { !button.isBordered && button.image?.isTemplate == true }

    private static func set(_ view: NSView?) {
        guard view !== hovered else { return }
        if let button = hovered as? NSButton, isIcon(button) { button.contentTintColor = restingTint }
        restingTint = nil
        hovered = view
        shade.removeFromSuperview()
        if let button = view as? NSButton {
            guard isIcon(button) else { return }
            restingTint = button.contentTintColor
            button.contentTintColor = tint(for: button)
            return
        }
        guard let view else { return }
        let insets = view.alignmentRectInsets
        shade.frame = NSRect(x: insets.left, y: insets.bottom, width: view.bounds.width - insets.left - insets.right,
                             height: view.bounds.height - insets.top - insets.bottom)
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.layer?.cornerRadius = 5
        shade.layer?.backgroundColor = activeFill(for: view).cgColor
        view.addSubview(shade)
    }
}
