import AppKit

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSMenuDelegate {
    var project: Project
    var onClose: (() -> Void)?
    var onBack: (() -> Void)?
    var onOpenProject: ((Project, Bool) -> Void)?
    var onProjectRenamed: (() -> Void)?

    let root: FileNode
    let outline = TreeOutline()
    private let treeScroll = NSScrollView()
    private let mainSplit = NSSplitView()
    private let rightSplit = NSSplitView()
    let editorScroll = CodeScrollView.make()
    var textView: NSTextView { editorScroll.documentView as! NSTextView }
    let fileLabel = NSTextField(labelWithString: "")
    let formatButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "左のディレクトリからファイルを選択してください")
    private var folderButton: ToolStripButton!
    private var pluginButton: ToolStripButton!
    private var terminalButton: ToolStripButton!
    private var gitButton: ToolStripButton!
    private var terminalFeed: TerminalFeed?
    private var gitFeed: FeedView?
    private let gitPanel = GitPanel()
    private let branchView = NSStackView()
    private let branchLabel = NSTextField(labelWithString: "")
    private var git: GitSnapshot?
    private var gitRefreshing = false
    private lazy var rootResolved = root.url.resolvingSymlinksInPath().path
    private var treeFeed: FeedView!
    private let leftPane = NSView()
    private let rightColumn = NSView()
    let topFeedHost = NSView()
    let topFeedLine = NSBox()
    var topFeedHeight: NSLayoutConstraint!
    private var pluginFeed: FeedView?
    private let pluginPage = PluginPage()
    private let barHost = NSView()
    private var barHeight: NSLayoutConstraint!
    private var floatConstraints: [NSLayoutConstraint] = []
    var overlayInset: CGFloat = 0
    var overlayTrailing: [NSLayoutConstraint] = []
    let bodyHost = NSView()
    var ext: EditorExtension?
    private var highlighter: Highlighter?
    private var recolorWork: DispatchWorkItem?
    private let topBar = NSView()
    let strip = NSView()
    var selectedURL: URL?
    private let gearButton = NSButton()
    private let searchButton = NSButton()
    private var searchPanel: SearchPanel?
    private var commandPalette: CommandPalette?
    private let settingsMenu = EditorSettingsMenu()
    let fileTabs = TabStrip()
    let editorSplit = NSSplitView()
    var splitPane: SplitPane?
    var tabs: [URL: TabItemView] = [:]
    var buffers: [URL: Buffer] = [:]
    var current: Buffer?
    private let cloudButton = NSButton()
    let topButtons = NSStackView()
    private var shiftMonitor: Any?
    private var topDragMonitor: Any?
    private var lastShift: TimeInterval?
    private var autosaveTimer: Timer?
    private var cloning: GitClone?
    let projectButton = NSButton()
    private var topHeight: NSLayoutConstraint!
    var stripWidth: NSLayoutConstraint!
    private var watcher: FileWatcher?
    private var gitWork: DispatchWorkItem?
    var upperColumn: NSStackView!
    var lowerColumn: NSStackView!
    var pluginFeeds: [(feed: NSView, button: ToolStripButton?)] = []
    lazy var textAddons = TextAddons(code: self)
    lazy var windowAddons = WindowAddons(editor: self)
    private var resizingFullScreen = false

    init(project: Project) {
        self.project = project
        root = FileNode(url: project.url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(project.name) — \(appName)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        super.init(window: window)
        window.delegate = self
        build()
        restoreFrame()
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pluginsChanged), name: .pluginsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(largeFileAllowed), name: .largeFileAllowed, object: nil)
        applyPlugins()
        if !root.isDirectory { open(root.url) }
        applySettings()
        shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.watchShift(event)
            return event
        }
        topDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.dragTopButton(event) else { return event }
            return nil
        }
        watcher = FileWatcher(path: baseDirectory.path) { [weak self] changes in
            guard let self else { return }
            if !changes.modified.isEmpty { self.reloadExternal(changes.modified) }
            if changes.rescan || self.treeDiffers(changes.structural) {
                self.reloadTree()
                self.refreshGit()
            } else {
                self.scheduleGitRefresh()
            }
        }
        PluginStore.refreshCatalog()
    }

    var baseDirectory: URL { root.isDirectory ? root.url : root.url.deletingLastPathComponent() }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))

        topBar.translatesAutoresizingMaskIntoConstraints = false
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "初期画面に戻る")!,
                            target: self, action: #selector(backClicked))
        back.isBordered = false
        back.toolTip = "初期画面に戻る"
        back.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(back)
        projectButton.isBordered = false
        projectButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        projectButton.imagePosition = .imageTrailing
        projectButton.toolTip = "プロジェクト"
        projectButton.target = self
        projectButton.action = #selector(projectClicked)
        updateProjectTitle()
        let name = projectButton
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pathClicked)))
        fileLabel.lineBreakMode = .byTruncatingHead
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let branchIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "ブランチ")!)
        branchIcon.contentTintColor = .secondaryLabelColor
        branchLabel.font = .systemFont(ofSize: 12, weight: .medium)
        branchLabel.textColor = .secondaryLabelColor
        branchView.orientation = .horizontal
        branchView.spacing = 3
        branchView.addArrangedSubview(branchIcon)
        branchView.addArrangedSubview(branchLabel)
        branchView.isHidden = true
        formatButton.isBordered = false
        formatButton.toolTip = "文字コードと改行コード"
        formatButton.target = self
        formatButton.action = #selector(formatClicked)
        formatButton.isHidden = true
        formatButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleStack = NSStackView(views: [name, branchView, fileLabel, formatButton])
        titleStack.orientation = .horizontal
        titleStack.spacing = 14
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleStack)
        cloudButton.isBordered = false
        updateCloud()
        cloudButton.target = self
        cloudButton.action = #selector(cloudClicked)
        cloudButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(cloudButton)
        searchButton.image = Self.cloudImage("magnifyingglass")
        searchButton.isBordered = false
        searchButton.toolTip = "プロジェクト内を検索"
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(searchButton)
        gearButton.image = Self.cloudImage("gearshape")
        gearButton.isBordered = false
        gearButton.toolTip = "エディタ設定"
        gearButton.target = self
        gearButton.action = #selector(gearClicked)
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(gearButton)
        topButtons.orientation = .horizontal
        topButtons.spacing = 8
        topButtons.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topButtons)
        for (button, id) in [(cloudButton, "cloud"), (searchButton, "search"), (gearButton, "gear")] {
            button.removeFromSuperview()
            button.identifier = NSUserInterfaceItemIdentifier(Self.topPrefix + id)
            insertTopButton(button)
        }
        let topLine = NSBox()
        topLine.boxType = .separator
        topLine.translatesAutoresizingMaskIntoConstraints = false

        strip.translatesAutoresizingMaskIntoConstraints = false
        folderButton = ToolStripButton(symbol: "folder", tip: "ディレクトリ", target: self, action: #selector(toggleTree))
        pluginButton = ToolStripButton(symbol: "puzzlepiece.extension", tip: "プラグイン", target: self, action: #selector(togglePlugins))
        terminalButton = ToolStripButton(symbol: "terminal", tip: "ターミナル", target: self, action: #selector(toggleTerminal))
        gitButton = ToolStripButton(symbol: "arrow.triangle.branch", tip: "Git", target: self, action: #selector(toggleGit))
        folderButton.active = true
        let groups = Self.ordered(upper: [("folder", folderButton), ("plugin", pluginButton)], lower: [("terminal", terminalButton), ("git", gitButton)])
        let upper = Self.buttonColumn(groups.upper)
        let lower = Self.buttonColumn(groups.lower)
        upperColumn = upper
        lowerColumn = lower
        prepareStripButtons()
        strip.addSubview(upper)
        strip.addSubview(lower)
        let stripLine = NSBox()
        stripLine.boxType = .separator
        stripLine.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .small
        outline.style = .sourceList
        outline.target = self
        outline.action = #selector(treeClicked)
        outline.onMove = { [weak self] in self?.moveNode($0, into: $1) }
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.backgroundColor = .clear
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.hasHorizontalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = false
        treeScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitTreeColumn),
                                               name: NSView.frameDidChangeNotification, object: treeScroll.contentView)

        treeFeed = FeedView(title: "ディレクトリ", content: treeScroll)
        treeFeed.onRemove = { [weak self] in self?.toggleTree() }

        _ = textView.layoutManager
        CodeView.configure(textView, scroll: editorScroll)
        textView.delegate = self
        CodeView.onScroll(editorScroll, self, #selector(editorScrolled))

        let editorPane = NSView()
        barHost.translatesAutoresizingMaskIntoConstraints = false
        barHost.clipsToBounds = true
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.clipsToBounds = true
        editorPane.addSubview(bodyHost)
        editorPane.addSubview(barHost)
        editorPane.addSubview(fileTabs)
        show(editorScroll, in: bodyHost)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorPane.addSubview(placeholder)
        pluginPage.onError = { [weak self] in self?.showError($0) }
        barHeight = barHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            fileTabs.topAnchor.constraint(equalTo: editorPane.topAnchor),
            fileTabs.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            fileTabs.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            barHost.topAnchor.constraint(equalTo: fileTabs.bottomAnchor),
            barHost.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            barHeight,
            bodyHost.topAnchor.constraint(equalTo: barHost.bottomAnchor),
            bodyHost.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: bodyHost.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: bodyHost.centerYAnchor),
        ])

        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.addArrangedSubview(editorPane)
        rightSplit.addArrangedSubview(editorSplit)

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        topFeedHost.translatesAutoresizingMaskIntoConstraints = false
        topFeedHost.clipsToBounds = true
        topFeedLine.boxType = .separator
        topFeedLine.isHidden = true
        topFeedLine.translatesAutoresizingMaskIntoConstraints = false
        rightSplit.translatesAutoresizingMaskIntoConstraints = false
        [topFeedHost, topFeedLine, rightSplit].forEach(rightColumn.addSubview)
        topFeedHeight = topFeedHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topFeedHeight,
            topFeedHost.topAnchor.constraint(equalTo: rightColumn.topAnchor),
            topFeedHost.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            topFeedHost.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            topFeedLine.topAnchor.constraint(equalTo: topFeedHost.bottomAnchor),
            topFeedLine.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            topFeedLine.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            rightSplit.topAnchor.constraint(equalTo: topFeedLine.bottomAnchor),
            rightSplit.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            rightSplit.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            rightSplit.bottomAnchor.constraint(equalTo: rightColumn.bottomAnchor),
        ])
        mainSplit.addArrangedSubview(leftPane)
        mainSplit.addArrangedSubview(rightColumn)
        mainSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false

        [topBar, topLine, strip, stripLine, mainSplit].forEach(content.addSubview)
        topHeight = topBar.heightAnchor.constraint(equalToConstant: Settings.bigTabHeight)
        stripWidth = strip.widthAnchor.constraint(equalToConstant: Settings.bigTabWidth)
        NSLayoutConstraint.activate([
            topHeight,
            stripWidth,
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            back.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 10),
            back.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleStack.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 6),
            titleStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: topButtons.leadingAnchor, constant: -12),
            topButtons.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            topButtons.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topLine.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            strip.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            upper.topAnchor.constraint(equalTo: strip.topAnchor, constant: 8),
            upper.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
            lower.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -8),
            lower.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
            lower.topAnchor.constraint(greaterThanOrEqualTo: upper.bottomAnchor, constant: 8),
            stripLine.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            stripLine.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stripLine.leadingAnchor.constraint(equalTo: strip.trailingAnchor),
            stripLine.widthAnchor.constraint(equalToConstant: 1),

            mainSplit.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: stripLine.trailingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])

        window?.contentView = content
        window?.setContentSize(NSSize(width: 1100, height: 720))
        outline.reloadData()
        outline.expandItem(root)
        content.layoutSubtreeIfNeeded()
        showBottom(treeFeed)
        mainSplit.setPosition(260, ofDividerAt: 0)
        fitTreeColumn()
    }

    @objc func backClicked() {
        guard let window else { return }
        if let error = saveAll() {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        onBack?()
        window.close()
    }

    @objc func fitTreeColumn() {
        guard let column = outline.tableColumns.first else { return }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        var width: CGFloat = 0
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FileNode else { continue }
            let text = (node.url.lastPathComponent as NSString).size(withAttributes: [.font: font]).width
            width = max(width, outline.indentationPerLevel * CGFloat(outline.level(forRow: row) + 1) + 16 + 5 + text + 24)
        }
        column.width = max(width, treeScroll.contentView.bounds.width - outline.intercellSpacing.width)
    }

    private static func ordered(upper: [(String, NSView)], lower: [(String, NSView)]) -> (upper: [NSView], lower: [NSView]) {
        (upper + lower).forEach { $0.1.identifier = NSUserInterfaceItemIdentifier($0.0) }
        let top = UserDefaults.standard.stringArray(forKey: upperKey) ?? []
        let bottom = UserDefaults.standard.stringArray(forKey: lowerKey) ?? []
        let inUpper = upper.filter { !bottom.contains($0.0) } + lower.filter { top.contains($0.0) }
        let inLower = lower.filter { !top.contains($0.0) } + upper.filter { bottom.contains($0.0) }
        func sorted(_ items: [(String, NSView)], _ saved: [String]) -> [NSView] {
            let rank = { (i: Int) in saved.firstIndex(of: items[i].0) ?? saved.count + i }
            return items.indices.sorted { rank($0) < rank($1) }.map { items[$0].1 }
        }
        return (sorted(inUpper, top), sorted(inLower, bottom))
    }

    private static func buttonColumn(_ buttons: [NSView]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func show(_ view: NSView, in host: NSView) {
        host.subviews.filter { $0 !== view }.forEach { $0.removeFromSuperview() }
        view.isHidden = false
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    @objc private func toggleTree() { toggleBottom(treeFeed) }

    @objc private func togglePlugins() {
        let feed: FeedView
        if let existing = pluginFeed {
            feed = existing
        } else {
            let list = PluginList()
            list.onOpen = { [weak self] id in self?.open(PluginStore.pageURL(id)) }
            list.onError = { [weak self] in self?.showError($0) }
            let installAll = FeedView.barButton(symbol: "square.and.arrow.down.on.square", tip: "全てインストール", target: list, action: #selector(PluginList.installAll))
            let uninstallAll = FeedView.barButton(symbol: "trash", tip: "全てアンインストール", target: list, action: #selector(PluginList.uninstallAll))
            feed = FeedView(title: "プラグイン", content: list, extras: [installAll, uninstallAll])
            feed.onRemove = { [weak self] in self?.togglePlugins() }
            pluginFeed = feed
            feed.isHidden = true
        }
        toggleBottom(feed)
    }

    @objc private func gearClicked() { settingsMenu.popUp(from: gearButton) }

    private func watchShift(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.window === window, window?.isKeyWindow == true else {
            lastShift = nil
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .shift else {
            if !flags.isEmpty { lastShift = nil }
            return
        }
        if let last = lastShift, event.timestamp - last < 0.4 {
            lastShift = nil
            searchClicked()
        } else {
            lastShift = event.timestamp
        }
    }

    @objc private func searchClicked() {
        guard let window else { return }
        if let panel = searchPanel, panel.isVisible { return panel.close() }
        let panel = searchPanel ?? SearchPanel(base: baseDirectory)
        panel.onOpen = { [weak self] in self?.openHit($0, line: $1, query: $2) }
        panel.onReplace = { [weak self] in self?.replaceInProject($0, with: $1, options: $2) }
        searchPanel = panel
        panel.show(over: window)
    }

    @objc func findInProject(_ sender: Any?) { searchClicked() }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        if let palette = commandPalette, palette.isVisible { return palette.close() }
        let palette = commandPalette ?? CommandPalette()
        commandPalette = palette
        palette.show(over: window, commands: paletteCommands)
    }

    var paletteCommands: [PaletteCommand] {
        var list: [PaletteCommand] = []
        let collect: (AnyObject) -> Void = { if let provider = $0 as? CommandProviding { list += provider.commands } }
        windowAddons.each(collect)
        textAddons.each(collect)
        splitPane?.addons.each(collect)
        list += HostAPI.paletteCommands
        for button in stripButtons {
            guard let tip = button.toolTip, !tip.isEmpty else { continue }
            list.append(PaletteCommand(id: "strip." + tip, title: tip, detail: "アイコン列") { [weak button] in button?.performClick(nil) })
        }
        for view in topButtons.arrangedSubviews {
            func find(_ view: NSView) -> NSButton? { (view as? NSButton) ?? view.subviews.lazy.compactMap(find).first }
            guard let button = find(view), let tip = button.toolTip ?? view.toolTip, !tip.isEmpty else { continue }
            list.append(PaletteCommand(id: "top." + tip, title: tip, detail: "上のバー") { [weak button] in button?.performClick(nil) })
        }
        return list + CommandPalette.menuCommands()
    }

    private func lineRange(_ line: Int) -> NSRange {
        let text = textView.string as NSString
        let starts = LineIndex.starts(of: textView)
        let start = starts[min(max(line - 1, 0), starts.count - 1)]
        return text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
    }

    func openLocation(_ url: URL, line: Int, column: Int?) {
        if selectedURL != url { open(url) }
        window?.makeKeyAndOrderFront(nil)
        guard current?.url == url else { return }
        let text = textView.string as NSString
        let range = lineRange(line)
        let end = NSMaxRange(range) - (text.substring(with: range).hasSuffix("\n") ? 1 : 0)
        let target = NSRange(location: min(range.location + max((column ?? 1) - 1, 0), end), length: 0)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(target)
        CodeView.center(textView, on: target)
        textView.showFindIndicator(for: NSRange(location: range.location, length: end - range.location))
    }

    private func openHit(_ url: URL, line: Int?, query: String) {
        if selectedURL != url { open(url) }
        window?.makeKeyAndOrderFront(nil)
        guard let line, current?.url == url else { return }
        let text = textView.string as NSString
        let lineRange = self.lineRange(line)
        let found = text.range(of: query, options: .caseInsensitive, range: lineRange)
        let target = found.location == NSNotFound ? NSRange(location: lineRange.location, length: 0) : found
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(target)
        CodeView.center(textView, on: target)
        if target.length > 0 { textView.showFindIndicator(for: target) }
    }

    var feeds: [(feed: NSView, button: ToolStripButton?)] {
        [(treeFeed as NSView?, folderButton), (pluginFeed, pluginButton), (terminalFeed, terminalButton), (gitFeed, gitButton)]
            .compactMap { pair in pair.0.map { ($0, pair.1) } } + pluginFeeds
    }

    private func inUpper(_ view: NSView) -> Bool {
        feeds.first { $0.feed === view }?.button?.isDescendant(of: upperColumn) ?? false
    }

    private func closeEmptyLeft() {
        guard !leftPane.isHidden, leftPane.subviews.allSatisfy(\.isHidden) else { return }
        leftPane.isHidden = true
        mainSplit.adjustSubviews()
    }

    private func closeFeed(_ feed: NSView) {
        feed.isHidden = true
        feed.removeFromSuperview()
    }

    func showBottom(_ view: NSView) {
        let upper = inUpper(view)
        let height = rightSplit.arrangedSubviews.count > 1 ? editorSplit.frame.height : rightSplit.bounds.height * 0.62
        for (feed, button) in feeds where inUpper(feed) == upper {
            if feed !== view { closeFeed(feed) }
            button?.active = feed === view
        }
        view.isHidden = false
        if upper {
            show(view, in: leftPane)
            rightSplit.adjustSubviews()
            guard leftPane.isHidden else { return }
            leftPane.isHidden = false
            mainSplit.adjustSubviews()
            mainSplit.setPosition(260, ofDividerAt: 0)
        } else {
            if view.superview !== rightSplit {
                view.translatesAutoresizingMaskIntoConstraints = true
                rightSplit.addArrangedSubview(view)
            }
            closeEmptyLeft()
            rightSplit.adjustSubviews()
            rightSplit.setPosition(height, ofDividerAt: 0)
        }
    }

    func hideBottom(_ view: NSView) {
        feeds.first { $0.feed === view }?.button?.active = false
        closeFeed(view)
        closeEmptyLeft()
        rightSplit.adjustSubviews()
        window?.makeFirstResponder(textView)
    }

    func settleFeeds() {
        feeds.filter { !$0.feed.isHidden && ($0.feed.superview === leftPane) != inUpper($0.feed) }.forEach { showBottom($0.feed) }
    }

    @objc private func toggleTerminal() {
        if let feed = terminalFeed, !feed.isHidden {
            hideBottom(feed)
            terminalButton.active = false
            return
        }
        let feed: TerminalFeed
        if let existing = terminalFeed {
            feed = existing
        } else {
            feed = TerminalFeed(cwd: baseDirectory.path)
            feed.onRemove = { [weak self] in self?.toggleTerminal() }
            feed.onEmpty = { [weak self, weak feed] in
                guard let self, let feed, self.terminalFeed === feed else { return }
                feed.removeFromSuperview()
                self.terminalFeed = nil
                self.terminalButton.active = false
                self.closeEmptyLeft()
                self.rightSplit.adjustSubviews()
            }
            terminalFeed = feed
        }
        terminalButton.active = true
        showBottom(feed)
        DispatchQueue.main.async { feed.focus() }
    }

    @objc private func toggleGit() {
        if let feed = gitFeed, !feed.isHidden {
            hideBottom(feed)
            gitButton.active = false
            return
        }
        let feed: FeedView
        if let existing = gitFeed {
            feed = existing
        } else {
            let reload = FeedView.barButton(symbol: "arrow.clockwise", tip: "再読み込み", target: self, action: #selector(reloadGitReport))
            feed = FeedView(title: "Git", content: gitPanel, extras: [reload])
            feed.onRemove = { [weak self] in self?.toggleGit() }
            gitFeed = feed
        }
        gitButton.active = true
        showBottom(feed)
        reloadGitReport()
    }

    @objc func reloadGitReport() {
        let dir = baseDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let overview = Git.overview(for: dir)
            DispatchQueue.main.async { self?.gitPanel.show(overview) }
        }
    }

    func refreshGit() {
        guard Settings.gitEnabled else {
            git = nil
            branchView.isHidden = true
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
            colorTabs()
            return
        }
        guard !gitRefreshing else { return }
        gitRefreshing = true
        let dir = baseDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Git.snapshot(for: dir)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRefreshing = false
                guard Settings.gitEnabled else { return }
                self.git = snapshot
                self.branchLabel.stringValue = snapshot?.branch ?? ""
                self.branchView.isHidden = snapshot == nil
                let rows = IndexSet(integersIn: 0..<self.outline.numberOfRows)
                self.outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
                self.colorTabs()
            }
        }
    }

    private func colorTabs() {
        tabs.forEach { $0.value.tint = gitState($0.key)?.color }
        splitPane?.colorTabs()
    }

    func gitState(_ url: URL) -> GitFileState? {
        guard let git, url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        let base = root.url.standardizedFileURL.path
        let resolved = path.hasPrefix(base) ? rootResolved + path.dropFirst(base.count) : path
        return git.state(of: resolved)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return 1 }
        return node.isDirectory ? node.children.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return root }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? FileNode)?.invalidate()
    }

    func outlineViewItemDidExpand(_ notification: Notification) { fitTreeColumn() }

    func outlineViewItemDidCollapse(_ notification: Notification) { fitTreeColumn() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byClipping
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.textField?.textColor = gitState(node.url)?.color ?? .labelColor
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        return cell
    }

    @objc private func treeClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
        open(node.url)
    }

    func open(_ url: URL) {
        textAddons.each { $0.dismiss() }
        if let id = PluginStore.id(from: url) {
            openPluginPage(id)
            return
        }
        if let splitPane, splitPane.contains(url) { return splitPane.select(url) }
        storeCurrent()
        let buffer = buffers[url] ?? Buffer(url: url)
        buffers[url] = buffer
        current = buffer
        selectedURL = url
        syncAddons()
        addTab(for: url, title: url.lastPathComponent)
        placeholder.isHidden = true
        textView.string = buffer.text
        styleText()
        textView.isEditable = buffer.editable
        highlighter = buffer.editable ? PluginStore.makeHighlighter(for: url) : nil
        recolor()
        textAddons.each { $0.fileOpened() }
        windowAddons.each { $0.fileOpened() }
        attachExtension()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        window?.makeFirstResponder(textView)
        updateTitle()
        if LargeFile.isLimited(url) { LargeFile.notify(url, in: window) }
    }

    @objc private func largeFileAllowed(_ notification: Notification) {
        guard let current, current.url.standardizedFileURL == notification.object as? URL else { return }
        storeCurrent()
        syncAddons()
        textView.isEditable = current.editable
        highlighter = current.editable ? PluginStore.makeHighlighter(for: current.url) : nil
        recolor()
        textAddons.each { $0.fileOpened() }
        windowAddons.each { $0.fileOpened() }
        attachExtension()
    }

    private func syncAddons() {
        if let current, LargeFile.isLimited(current.url) {
            textAddons.detachAll()
            windowAddons.detachAll()
        } else {
            textAddons.sync()
            windowAddons.sync()
        }
    }

    private func openPluginPage(_ id: String) {
        guard let info = PluginStore.info(id) else { return }
        storeCurrent()
        current = nil
        let url = PluginStore.pageURL(id)
        selectedURL = url
        addTab(for: url, title: info.name)
        highlighter = nil
        detachExtension()
        syncAddons()
        windowAddons.each { $0.fileOpened() }
        pluginPage.show(id)
        show(pluginPage, in: bodyHost)
        placeholder.isHidden = true
        fileLabel.stringValue = "プラグイン > \(info.name)"
        updateCloud()
    }

    private func attachExtension() {
        guard let current else { return detachExtension() }
        guard !LargeFile.isLimited(current.url) else {
            textView.isEditable = false
            return detachExtension()
        }
        let viewer = NativePlugins.viewer(for: current.url)
        textView.isEditable = current.editable && viewer == nil
        ext = viewer ?? (current.editable ? NativePlugins.codePreview(for: current.url, code: editorScroll) ?? PluginStore.makeExtension(for: current.url, code: editorScroll) : nil)
        guard let ext else { return detachExtension() }
        show(ext.body, in: bodyHost)
        layoutExtensionBar()
        ext.update(text: textView.string)
    }

    func layoutExtensionBar() {
        guard let ext else { return }
        let bar = ext.bar
        NSLayoutConstraint.deactivate(floatConstraints)
        floatConstraints = []
        bar.removeFromSuperview()
        barHost.subviews.forEach { $0.removeFromSuperview() }
        if ext.floating {
            barHeight.constant = 0
            bar.translatesAutoresizingMaskIntoConstraints = false
            bodyHost.addSubview(bar)
            let corner = ext.corner
            let ruler = editorScroll.rulersVisible ? editorScroll.verticalRulerView?.ruleThickness ?? 0 : 0
            floatConstraints = [
                bar.heightAnchor.constraint(equalToConstant: 28),
                corner.right ? bar.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -18 - overlayInset)
                    : bar.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor, constant: 18 + ruler),
            ]
            if corner.top {
                let top = bar.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: 14)
                top.priority = .defaultHigh
                floatConstraints.append(top)
                if corner.right {
                    floatConstraints += overlays.map { bar.topAnchor.constraint(greaterThanOrEqualTo: $0.bottomAnchor, constant: 8) }
                }
            } else {
                floatConstraints.append(bar.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor, constant: -14))
            }
            NSLayoutConstraint.activate(floatConstraints)
        } else {
            show(bar, in: barHost)
            barHeight.constant = 30
        }
    }

    private func detachExtension() {
        NSLayoutConstraint.deactivate(floatConstraints)
        floatConstraints = []
        ext?.bar.removeFromSuperview()
        ext = nil
        barHost.subviews.forEach { $0.removeFromSuperview() }
        barHeight.constant = 0
        show(editorScroll, in: bodyHost)
    }

    func showEmpty() {
        selectedURL = nil
        highlighter = nil
        detachExtension()
        textView.string = ""
        textView.isEditable = false
        syncAddons()
        textAddons.each { $0.fileOpened() }
        windowAddons.each { $0.fileOpened() }
        placeholder.isHidden = false
        fileLabel.stringValue = ""
        updateCloud()
    }

    @objc private func pluginsChanged() {
        (pluginFeed?.content as? PluginList)?.reload()
        pluginPage.refresh()
        applyPlugins()
        if let current {
            storeCurrent()
            highlighter = current.editable ? PluginStore.makeHighlighter(for: current.url) : nil
            recolor()
            attachExtension()
        }
    }

    private func applyPlugins() {
        syncAddons()
        splitPane?.applyPlugins()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text, textView === self.textView else { return true }
        return textAddons.shouldChange(range, text: text)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === self.textView else { return false }
        return textAddons.doCommand(selector)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textAddons.each { $0.selectionChanged() }
    }

    private func styleText() { CodeView.style(textView) }

    func recolor() {
        recolorWork?.cancel()
        recolorWork = nil
        guard let layout = textView.layoutManager else { return }
        CodeView.highlight(textView, with: highlighter, file: current?.url)
        textAddons.decorate(layout)
        windowAddons.each { $0.decorate(layout) }
    }

    @objc private func editorScrolled() {
        guard highlighter != nil, Highlighter.needsWindow((textView.string as NSString).length) else { return }
        scheduleRecolor()
    }

    private func scheduleRecolor() {
        guard highlighter != nil else { return }
        recolorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recolor() }
        recolorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc private func applySettings() {
        topBar.paint(.bigTab)
        strip.paint(.bigTab)
        topHeight.constant = Settings.bigTabHeight
        stripWidth.constant = focusMode ? 0 : Settings.bigTabWidth
        stripButtons.forEach { $0.applySize() }
        CodeView.applySettings(textView, scroll: editorScroll)
        recolor()
        splitPane?.applySettings()
        if let ext {
            let wasFloating = ext.floating
            ext.applySettings()
            if wasFloating || ext.floating { layoutExtensionBar() }
        }

        autosaveTimer?.invalidate()
        autosaveTimer = Settings.autosaveEnabled && !Settings.autosaveImmediate
            ? Timer.scheduledTimer(timeInterval: Settings.autosaveInterval, target: self, selector: #selector(autosave),
                                   userInfo: nil, repeats: true)
            : nil
        updateCloud()

        gitButton.isHidden = !Settings.gitEnabled
        if !Settings.gitEnabled, let feed = gitFeed, !feed.isHidden {
            hideBottom(feed)
            gitButton.active = false
        }
        refreshGit()
    }

    private func addTab(for url: URL, title: String) {
        if tabs[url] == nil {
            let tab = TabItemView(title: title, closable: true)
            tab.url = url
            tab.toolTip = url.isFileURL ? url.path : title
            tab.onSelect = { [weak self] in
                guard let self, self.selectedURL != url else { return }
                self.open(url)
            }
            tab.onClose = { [weak self] in self?.closeTab(url) }
            if url.isFileURL { tab.contextMenu = { [weak self] in self?.tabMenu(url) } }
            tab.draggable = true
            tab.tint = gitState(url)?.color
            tabs[url] = tab
            fileTabs.stack.addArrangedSubview(tab)
        }
        tabs.forEach { $0.value.selected = $0.key == url }
        if let tab = tabs[url] { fileTabs.reveal(tab) }
    }

    func closeTab(_ url: URL) {
        guard let tab = tabs[url] else { return }
        let index = fileTabs.stack.arrangedSubviews.filter { $0 is TabItemView }.firstIndex(of: tab) ?? 0
        if selectedURL == url { storeCurrent() }
        if let buffer = buffers[url], buffer.dirty, buffer.editable {
            do {
                try buffer.save()
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
                return
            }
        }
        tab.removeFromSuperview()
        tabs[url] = nil
        buffers[url] = nil
        windowAddons.each { $0.bufferClosed(url) }
        guard selectedURL == url else { updateTitle(); return }
        current = nil
        let remaining = fileTabs.stack.arrangedSubviews.filter { $0 is TabItemView }
        if !remaining.isEmpty,
           let next = tabs.first(where: { $0.value === remaining[min(index, remaining.count - 1)] })?.key {
            open(next)
            return
        }
        showEmpty()
    }

    func storeCurrent() {
        guard let current, current.editable else { return }
        current.text = textView.string
    }

    func textDidChange(_ notification: Notification) {
        textAddons.each { $0.textChanged() }
        windowAddons.each { $0.textChanged() }
        ext?.update(text: textView.string)
        scheduleRecolor()
        guard let current else { return }
        if Settings.autosaveImmediate, current.editable {
            current.text = textView.string
            current.scheduleSave { [weak self] in
                self?.updateTitle()
                self?.scheduleGitRefresh()
            }
            updateTitle()
            return
        }
        guard !current.dirty else { return }
        current.dirty = true
        updateTitle()
    }

    func reloadExternal(_ paths: Set<String>) {
        let changed = { (url: URL) -> Bool in
            let real = realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) }
            return paths.contains(url.standardizedFileURL.path) || real.map(paths.contains) == true
        }
        splitPane?.reloadExternal(changed)
        for (url, buffer) in buffers where buffer.editable && !buffer.dirty && changed(url) {
            guard let text = buffer.diskText() else { continue }
            guard buffer === current else {
                buffer.text = text
                continue
            }
            guard text != textView.string, !textView.hasMarkedText() else { continue }
            textAddons.each { $0.dismiss() }
            CodeView.replace(textView, with: text)
            buffer.text = text
            textAddons.each { $0.textChanged() }
            windowAddons.each { $0.textChanged() }
            ext?.update(text: text)
            recolor()
        }
    }

    private func scheduleGitRefresh() {
        gitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshGit() }
        gitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func updateTitle() {
        guard let current else { return updateCloud() }
        let base = baseDirectory
        var relative = current.url.path
        if relative.hasPrefix(base.path + "/") { relative.removeFirst(base.path.count + 1) }
        fileLabel.stringValue = relative.split(separator: "/").joined(separator: " > ")
        updateCloud()
    }

    private func updateFormat() {
        guard let current, selectedURL == current.url else { return formatButton.isHidden = true }
        formatButton.isHidden = false
        formatButton.attributedTitle = NSAttributedString(string: current.editable ? current.format.label : L("文字コード不明"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }

    func updateCloud() {
        updateFormat()
        let dirty = buffers.values.contains { $0.dirty } || splitPane?.dirty == true
        cloudButton.image = Self.cloudImage(dirty ? "icloud.and.arrow.up" : "checkmark.icloud")
        cloudButton.toolTip = (!dirty ? (Settings.autosaveEnabled ? "自動保存済み" : "保存済み") : "未保存") + "（クリックで保存）"
        window?.isDocumentEdited = dirty
    }

    @discardableResult
    func saveAll() -> Error? {
        storeCurrent()
        if let error = splitPane?.saveAll() {
            updateTitle()
            return error
        }
        let dirty = buffers.values.filter { $0.dirty && $0.editable }
        guard !dirty.isEmpty else {
            updateTitle()
            return nil
        }
        defer { refreshGit() }
        for buffer in dirty {
            do {
                try buffer.save()
            } catch {
                updateTitle()
                return error
            }
        }
        updateTitle()
        return nil
    }

    static func cloudImage(_ symbol: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: "自動保存")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))!
    }

    @objc private func autosave() {
        if let error = saveAll(), let window, window.attachedSheet == nil {
            NSAlert(error: error).beginSheetModal(for: window)
        }
        refreshGit()
    }

    @objc private func cloudClicked() {
        if let error = saveAll() { return showError(error) }
        refreshGit()
        Toasts.hint("保存しました", under: cloudButton)
    }

    @objc func saveDocument(_ sender: Any?) {
        autosave()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let error = saveAll() else { return true }
        NSAlert(error: error).beginSheetModal(for: sender)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reloadTree()
        refreshGit()
    }

    func clone(_ request: CloneRequest) {
        guard cloning == nil, let toast = Toasts.progress("\(request.name) をクローン中", in: window) else { return }
        cloning = GitClone(request, progress: { [weak toast] status, value in
            toast?.update(status, value)
        }, completion: { [weak self, weak toast] error in
            guard let self else { return }
            self.cloning = nil
            self.reloadTree()
            self.outline.expandItem(self.root)
            self.refreshGit()
            if let error {
                toast?.finish("クローンに失敗しました", failed: true)
                self.showError(error)
            } else {
                toast?.finish("クローンが完了しました")
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) { textAddons.each { $0.dismiss() } }

    private static let frameKey = "Editor.LastFrame"
    private static let fullScreenKey = "Editor.FullScreen"

    private func restoreFrame() {
        guard let window else { return }
        let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString) ?? .zero
        guard saved.width >= window.minSize.width, saved.height >= window.minSize.height else { return window.center() }
        window.setFrame(window.constrainFrameRect(saved, to: window.screen ?? NSScreen.main), display: false)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard UserDefaults.standard.bool(forKey: Self.fullScreenKey), let window, !window.styleMask.contains(.fullScreen) else { return }
        DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }

    private func saveFrame() {
        guard let window, !resizingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowWillEnterFullScreen(_ notification: Notification) { resizingFullScreen = true }

    func windowDidEnterFullScreen(_ notification: Notification) {
        resizingFullScreen = false
        UserDefaults.standard.set(true, forKey: Self.fullScreenKey)
    }

    func windowWillExitFullScreen(_ notification: Notification) { resizingFullScreen = true }

    func windowDidExitFullScreen(_ notification: Notification) {
        resizingFullScreen = false
        UserDefaults.standard.set(false, forKey: Self.fullScreenKey)
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
        shiftMonitor = nil
        if let topDragMonitor { NSEvent.removeMonitor(topDragMonitor) }
        topDragMonitor = nil
        textAddons.detachAll()
        windowAddons.detachAll()
        splitPane?.detachAddons()
        searchPanel?.close()
        watcher?.stop()
        cloning?.cancel()
        autosaveTimer?.invalidate()
        terminalFeed?.stopAll()
        onClose?()
    }
}
