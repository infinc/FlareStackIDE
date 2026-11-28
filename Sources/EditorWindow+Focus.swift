import AppKit

extension EditorWindowController {
    private struct FocusState {
        var feeds: [NSView]
        var topFeed: (view: NSView, height: CGFloat)?
    }

    private static var focusStates: [ObjectIdentifier: FocusState] = [:]

    var focusMode: Bool { Self.focusStates[ObjectIdentifier(self)] != nil }

    private var verticalSeparators: [NSView] {
        window?.contentView?.subviews.filter { ($0 as? NSBox)?.boxType == .separator && $0.frame.height > $0.frame.width } ?? []
    }

    private var tabsHeight: NSLayoutConstraint? { fileTabs.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil } }

    func setFocusMode(_ on: Bool) {
        let key = ObjectIdentifier(self)
        if on {
            guard Self.focusStates[key] == nil else { return }
            let visible = feeds.map(\.feed).filter { !$0.isHidden && $0.superview != nil }
            let top = topFeedHost.subviews.first.map { ($0, topFeedHeight.constant) }
            Self.focusStates[key] = FocusState(feeds: visible, topFeed: top)
            visible.forEach(hideBottom)
            if let top { toggleTopFeed(top.0, height: top.1) }
            strip.isHidden = true
            stripWidth.constant = 0
            verticalSeparators.forEach { $0.isHidden = true }
            fileTabs.isHidden = true
            tabsHeight?.constant = 0
        } else {
            guard let state = Self.focusStates.removeValue(forKey: key) else { return }
            strip.isHidden = false
            stripWidth.constant = Settings.bigTabWidth
            verticalSeparators.forEach { $0.isHidden = false }
            fileTabs.isHidden = false
            tabsHeight?.constant = 30
            state.feeds.forEach(showBottom)
            if let top = state.topFeed, topFeedHost.subviews.isEmpty { toggleTopFeed(top.view, height: top.height) }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(textView)
    }
}
