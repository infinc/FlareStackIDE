import AppKit

extension EditorWindowController: CodeEditing, OverlayHosting, TabClosing {
    var scrollView: NSScrollView { editorScroll }
    var fileURL: URL? { current?.editable == true ? current?.url : nil }
    var tabStrip: TabStrip? { fileTabs }
    var projectDirectory: URL? { root.isDirectory ? baseDirectory : nil }

    var openTexts: [(url: URL, text: String)] {
        storeCurrent()
        return buffers.values.filter { $0.editable }.map { ($0.url, $0.text) }
    }

    var openURLs: [URL] { fileTabs.stack.arrangedSubviews.compactMap { view in tabs.first { $0.value === view }?.key } }

    func isOpen(_ url: URL) -> Bool { buffers[url] != nil }

    func reveal(_ url: URL, range: NSRange) {
        if current?.url != url { open(url) }
        guard current?.url == url, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    private static let overlayID = NSUserInterfaceItemIdentifier("editor.overlay")

    var overlays: [NSView] { bodyHost.superview?.subviews.filter { $0.identifier == Self.overlayID } ?? [] }

    func setOverlayInset(_ inset: CGFloat) {
        overlayInset = inset
        overlayTrailing.forEach { $0.constant = -4 - inset }
        if ext?.floating == true { layoutExtensionBar() }
    }

    func addOverlay(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.identifier = Self.overlayID
        bodyHost.superview?.addSubview(view)
        let trailing = view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -4 - overlayInset)
        overlayTrailing.append(trailing)
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: 4), trailing])
        if ext?.floating == true { layoutExtensionBar() }
    }

    func removeOverlay(_ view: NSView) {
        guard view.identifier == Self.overlayID else { return }
        view.removeFromSuperview()
        if ext?.floating == true { layoutExtensionBar() }
    }

    func addTopButton(_ view: NSView) {
        guard view.superview == nil else { return }
        if view.identifier == nil {
            let name = L10n.original(view.toolTip) ?? String(describing: type(of: view))
            view.identifier = NSUserInterfaceItemIdentifier(Self.topPrefix + "plugin." + name)
        }
        insertTopButton(view)
    }

    private static let topKey = "BigTab.Order.Top"
    static let topPrefix = "top."
    private static let builtinTop: Set<String> = ["top.cloud", "top.search", "top.gear"]

    func insertTopButton(_ view: NSView) {
        let saved = UserDefaults.standard.stringArray(forKey: Self.topKey) ?? []
        let id = view.identifier?.rawValue ?? ""
        let views = topButtons.arrangedSubviews
        let index: Int
        if let mine = saved.firstIndex(of: id) {
            index = views.firstIndex { saved.firstIndex(of: $0.identifier?.rawValue ?? "").map { $0 > mine } ?? false } ?? views.count
        } else if Self.builtinTop.contains(id) {
            index = views.count
        } else {
            index = views.firstIndex { Self.builtinTop.contains($0.identifier?.rawValue ?? "") } ?? views.count
        }
        topButtons.insertArrangedSubview(view, at: index)
    }

    func dragTopButton(_ event: NSEvent) -> Bool {
        guard event.window === window, event.modifierFlags.contains(.command), let window,
              let frame = window.contentView?.superview,
              let hit = window.contentView?.hitTest(frame.convert(event.locationInWindow, from: nil)),
              let item = sequence(first: hit, next: { $0.superview }).first(where: { $0.superview === topButtons }) else { return false }
        var reorder: DragReorder?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if reorder == nil {
                guard hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 3 else { continue }
                reorder = DragReorder(view: item, event: event)
            }
            reorder?.drag(next)
        }
        reorder?.end()
        if reorder != nil {
            var order = UserDefaults.standard.stringArray(forKey: Self.topKey) ?? []
            let current = topButtons.arrangedSubviews.compactMap { $0.identifier?.rawValue }
            order.removeAll { current.contains($0) }
            UserDefaults.standard.set(current + order, forKey: Self.topKey)
        }
        return true
    }

    func pressStripButton(_ id: String) -> Bool {
        func find(_ view: NSView) -> ToolStripButton? { (view as? ToolStripButton) ?? view.subviews.lazy.compactMap(find).first }
        guard let view = [upperColumn, lowerColumn].compactMap({ $0 }).flatMap(\.arrangedSubviews)
            .first(where: { $0.identifier?.rawValue == id }), let button = find(view) else { return false }
        button.performClick(nil)
        return true
    }

    func goBack() { backClicked() }

    func addFeed(_ feed: NSView, button: ToolStripButton?) {
        guard !pluginFeeds.contains(where: { $0.feed === feed }) else { return }
        pluginFeeds.append((feed, button))
        feed.isHidden = true
    }

    func removeFeed(_ feed: NSView) {
        if !feed.isHidden { hideBottom(feed) }
        pluginFeeds.removeAll { $0.feed === feed }
    }

    func toggleTopFeed(_ feed: NSView, height: CGFloat) {
        let open = feed.superview === topFeedHost
        topFeedHost.subviews.forEach { $0.removeFromSuperview() }
        topFeedHeight.constant = open ? 0 : height
        topFeedLine.isHidden = open
        if !open { show(feed, in: topFeedHost) }
    }

    func removeTopFeed(_ feed: NSView) {
        if feed.superview === topFeedHost { toggleTopFeed(feed, height: 0) }
    }

    func toggleBottom(_ feed: NSView) {
        if feed.isHidden { showBottom(feed) } else { hideBottom(feed) }
    }

    static let upperKey = "BigTab.Order.Upper"
    static let lowerKey = "BigTab.Order.Lower"

    var stripButtons: [ToolStripButton] {
        func find(_ view: NSView) -> [ToolStripButton] { (view as? ToolStripButton).map { [$0] } ?? view.subviews.flatMap(find) }
        return [upperColumn, lowerColumn].compactMap { $0 }.flatMap(find)
    }

    func prepareStripButtons() {
        stripButtons.forEach {
            $0.onReorder = { [weak self] in self?.stripReordered() }
            $0.groups = { [weak self] in [self?.upperColumn, self?.lowerColumn].compactMap { $0 } }
        }
    }

    private func stripReordered() {
        saveStripOrder()
        settleFeeds()
    }

    private func saveStripOrder() {
        for (stack, key) in [(upperColumn, Self.upperKey), (lowerColumn, Self.lowerKey)] {
            UserDefaults.standard.set(stack?.arrangedSubviews.compactMap { $0.identifier?.rawValue }, forKey: key)
        }
    }

    func addStripButton(_ view: NSView, id: String) {
        guard view.superview == nil else { return }
        view.identifier = NSUserInterfaceItemIdentifier(id)
        let top = UserDefaults.standard.stringArray(forKey: Self.upperKey) ?? []
        let column: NSStackView = top.contains(id) ? upperColumn : lowerColumn
        let saved = top.contains(id) ? top : UserDefaults.standard.stringArray(forKey: Self.lowerKey) ?? []
        let rank = { (key: String?) in key.flatMap { saved.firstIndex(of: $0) } ?? Int.max }
        let mine = rank(id)
        let index = column.arrangedSubviews.firstIndex { rank($0.identifier?.rawValue) > mine } ?? column.arrangedSubviews.count
        column.insertArrangedSubview(view, at: mine == Int.max ? 0 : index)
        stripButtons.forEach { $0.applySize() }
        prepareStripButtons()
    }
}
