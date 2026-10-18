import AppKit

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var cached: [FileNode]?

    init(url: URL) {
        self.url = url
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var children: [FileNode] {
        if let cached { return cached }
        let hidden: Set<String> = [".DS_Store", ".git"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let nodes = urls.filter { !hidden.contains($0.lastPathComponent) }.map(FileNode.init).sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cached = nodes
        return nodes
    }

    func invalidate() { cached = nil }

    func refresh() {
        guard let old = cached else { return }
        let existing = Dictionary(old.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
        cached = nil
        cached = children.map { existing[$0.url.standardizedFileURL] ?? $0 }
        cached?.forEach { $0.refresh() }
    }
}

final class Buffer {
    let url: URL
    var text: String
    var dirty = false
    let editable: Bool

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            text = s
            editable = true
        } else {
            text = "このファイルは表示できません。"
            editable = false
        }
    }
}

final class ToolStripButton: NSButton {
    var active = false { didSet { needsDisplay = true } }
    private var symbol = ""
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!

    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        self.symbol = symbol
        isBordered = false
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 30)
        height = heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([width, height])
        applySize()
    }

    func applySize() {
        let side = max(Settings.bigTabWidth - 10, 22)
        width.constant = side
        height.constant = side
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Settings.bigTabIconSize, weight: .regular))
    }

    override func draw(_ dirtyRect: NSRect) {
        if active {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSMenuDelegate {
    private(set) var project: Project
    var onClose: (() -> Void)?
    var onBack: (() -> Void)?
    var onOpenProject: ((Project, Bool) -> Void)?
    var onProjectRenamed: (() -> Void)?

    private let root: FileNode
    private let outline = NSOutlineView()
    private let treeScroll = NSScrollView()
    private let mainSplit = NSSplitView()
    private let rightSplit = NSSplitView()
    private let editorScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { editorScroll.documentView as! NSTextView }
    private let fileLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "左のディレクトリからファイルを選択してください")
    private var folderButton: ToolStripButton!
    private var pluginButton: ToolStripButton!
    private var terminalButton: ToolStripButton!
    private var gitButton: ToolStripButton!
    private var terminalFeed: TerminalFeed?
    private var gitFeed: FeedView?
    private let gitText = NSTextView()
    private let branchView = NSStackView()
    private let branchLabel = NSTextField(labelWithString: "")
    private var git: GitSnapshot?
    private var gitRefreshing = false
    private lazy var rootResolved = root.url.resolvingSymlinksInPath().path
    private var treeFeed: FeedView!
    private let leftPane = NSView()
    private weak var topFeed: FeedView?
    private var pluginFeed: FeedView?
    private let pluginPage = PluginPage()
    private let barHost = NSView()
    private var barHeight: NSLayoutConstraint!
    private let bodyHost = NSView()
    private var ext: EditorExtension?
    private var highlighter: Highlighter?
    private var recolorWork: DispatchWorkItem?
    private let topBar = NSView()
    private let strip = NSView()
    private var selectedURL: URL?
    private let gearButton = NSButton()
    private let settingsMenu = EditorSettingsMenu()
    private let fileTabs = TabStrip()
    private var tabs: [URL: TabItemView] = [:]
    private var buffers: [URL: Buffer] = [:]
    private var current: Buffer?
    private let cloudButton = NSButton()
    private var autosaveTimer: Timer?
    private var cloning: GitClone?
    private let projectButton = NSButton()
    private var topHeight: NSLayoutConstraint!
    private var stripWidth: NSLayoutConstraint!
    private var watcher: FileWatcher?
    private var gitWork: DispatchWorkItem?
    private var runButton: RunButton!
    private lazy var runner = RunnerStore(project: project, base: baseDirectory)
    private var runFeed: FeedView?
    private let runContainer = NSView()
    private var runPane: TerminalPane?
    private var runConfig: RunConfig?
    private var scanner: CodeScanner?
    private var scanWork: DispatchWorkItem?
    private var diagnostics: [URL: [Diagnostic]] = [:]
    private let badge = ProblemBadge()
    private let problemsView = ProblemsView()
    private var problemsFeed: FeedView?

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
        window.center()
        window.setFrameAutosaveName("Editor:\(project.path)")
        NotificationCenter.default.addObserver(self, selector: #selector(applySettings), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pluginsChanged), name: .pluginsChanged, object: nil)
        applyPlugins()
        if !root.isDirectory { open(root.url) }
        applySettings()
        watcher = FileWatcher(path: baseDirectory.path) { [weak self] in
            self?.reloadTree()
            self?.refreshGit()
        }
        PluginStore.refreshCatalog()
    }

    private var baseDirectory: URL { root.isDirectory ? root.url : root.url.deletingLastPathComponent() }

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
        let titleStack = NSStackView(views: [name, branchView, fileLabel])
        titleStack.orientation = .horizontal
        titleStack.spacing = 14
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleStack)
        cloudButton.isBordered = false
        updateCloud()
        cloudButton.target = self
        cloudButton.action = #selector(autosave)
        cloudButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(cloudButton)
        gearButton.image = Self.cloudImage("gearshape")
        gearButton.isBordered = false
        gearButton.toolTip = "エディタ設定"
        gearButton.target = self
        gearButton.action = #selector(gearClicked)
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(gearButton)
        let topLine = NSBox()
        topLine.boxType = .separator
        topLine.translatesAutoresizingMaskIntoConstraints = false

        strip.translatesAutoresizingMaskIntoConstraints = false
        folderButton = ToolStripButton(symbol: "folder", tip: "ディレクトリ", target: self, action: #selector(toggleTree))
        pluginButton = ToolStripButton(symbol: "puzzlepiece.extension", tip: "プラグイン", target: self, action: #selector(togglePlugins))
        terminalButton = ToolStripButton(symbol: "terminal", tip: "ターミナル", target: self, action: #selector(toggleTerminal))
        gitButton = ToolStripButton(symbol: "arrow.triangle.branch", tip: "Git", target: self, action: #selector(toggleGit))
        runButton = RunButton(target: self, action: #selector(runClicked))
        runButton.onMenu = { [weak self] in self?.showRunMenu($0) }
        folderButton.active = true
        let upper = Self.buttonColumn([folderButton, pluginButton])
        let lower = Self.buttonColumn([runButton, terminalButton, gitButton])
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
        treeFeed.onRemove = { [weak self] in self?.hideTop() }
        show(treeFeed, in: leftPane)
        topFeed = treeFeed

        textView.textContainer?.replaceLayoutManager(DiagnosticLayoutManager())
        _ = textView.layoutManager
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = self
        textView.isEditable = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editorScroll.hasHorizontalScroller = true

        let editorPane = NSView()
        barHost.translatesAutoresizingMaskIntoConstraints = false
        barHost.clipsToBounds = true
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        editorPane.addSubview(fileTabs)
        editorPane.addSubview(barHost)
        editorPane.addSubview(bodyHost)
        show(editorScroll, in: bodyHost)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorPane.addSubview(placeholder)
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.toggleProblems() }
        editorPane.addSubview(badge)
        problemsView.onSelect = { [weak self] in self?.reveal($0) }
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
            badge.topAnchor.constraint(equalTo: bodyHost.topAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor, constant: -20),
        ])

        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.addArrangedSubview(editorPane)

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(leftPane)
        mainSplit.addArrangedSubview(rightSplit)
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
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: cloudButton.leadingAnchor, constant: -12),
            cloudButton.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -8),
            gearButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            gearButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            cloudButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
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
        mainSplit.setPosition(260, ofDividerAt: 0)
        fitTreeColumn()
    }

    @objc private func backClicked() {
        guard let window else { return }
        if let error = saveAll() {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        onBack?()
        window.close()
    }

    @objc private func fitTreeColumn() {
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

    private static func buttonColumn(_ buttons: [NSView]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func show(_ view: NSView, in host: NSView) {
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

    private func toggleTop(_ feed: FeedView) {
        if topFeed === feed, !leftPane.isHidden {
            hideTop()
            return
        }
        show(feed, in: leftPane)
        topFeed = feed
        folderButton.active = feed === treeFeed
        pluginButton.active = feed === pluginFeed
        guard leftPane.isHidden else { return }
        leftPane.isHidden = false
        mainSplit.adjustSubviews()
        mainSplit.setPosition(260, ofDividerAt: 0)
    }

    private func hideTop() {
        leftPane.isHidden = true
        folderButton.active = false
        pluginButton.active = false
        mainSplit.adjustSubviews()
    }

    @objc private func toggleTree() { toggleTop(treeFeed) }

    @objc private func togglePlugins() {
        let feed: FeedView
        if let existing = pluginFeed {
            feed = existing
        } else {
            let list = PluginList()
            list.onOpen = { [weak self] id in self?.open(PluginStore.pageURL(id)) }
            list.onError = { [weak self] in self?.showError($0) }
            feed = FeedView(title: "プラグイン", content: list)
            feed.onRemove = { [weak self] in self?.hideTop() }
            pluginFeed = feed
        }
        toggleTop(feed)
    }

    @objc private func gearClicked() { settingsMenu.popUp(from: gearButton) }

    private func showBottom(_ view: NSView) {
        for feed in [terminalFeed, gitFeed, runFeed, problemsFeed].compactMap({ $0 }) where feed !== view { feed.isHidden = true }
        terminalButton.active = view === terminalFeed
        gitButton.active = view === gitFeed
        runButton.play.active = view === runFeed
        view.isHidden = false
        rightSplit.adjustSubviews()
        rightSplit.setPosition(rightSplit.bounds.height * 0.62, ofDividerAt: 0)
    }

    private func hideBottom(_ view: NSView) {
        view.isHidden = true
        rightSplit.adjustSubviews()
        window?.makeFirstResponder(textView)
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
                self.rightSplit.adjustSubviews()
            }
            terminalFeed = feed
            rightSplit.addArrangedSubview(feed)
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
            gitText.isEditable = false
            gitText.isRichText = true
            gitText.textContainerInset = NSSize(width: 6, height: 6)
            gitText.isHorizontallyResizable = true
            gitText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            gitText.textContainer?.widthTracksTextView = false
            gitText.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            gitText.autoresizingMask = [.width]
            let scroll = NSScrollView()
            scroll.documentView = gitText
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            let reload = FeedView.barButton(symbol: "arrow.clockwise", tip: "再読み込み", target: self, action: #selector(reloadGitReport))
            feed = FeedView(title: "Git", content: scroll, extras: [reload])
            feed.onRemove = { [weak self] in self?.toggleGit() }
            gitFeed = feed
            rightSplit.addArrangedSubview(feed)
        }
        gitButton.active = true
        showBottom(feed)
        reloadGitReport()
    }

    @objc private func reloadGitReport() {
        let dir = baseDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = Git.report(for: dir)
            DispatchQueue.main.async {
                self?.gitText.textStorage?.setAttributedString(report)
                self?.gitText.scrollToBeginningOfDocument(nil)
            }
        }
    }

    func refreshGit() {
        guard Settings.gitEnabled else {
            git = nil
            branchView.isHidden = true
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
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
            }
        }
    }

    private func gitState(_ node: FileNode) -> GitFileState? {
        guard let git else { return nil }
        let path = node.url.standardizedFileURL.path
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
        cell.textField?.textColor = gitState(node)?.color ?? .labelColor
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        return cell
    }

    @objc private func treeClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
        open(node.url)
    }

    private func open(_ url: URL) {
        if let id = PluginStore.id(from: url) {
            openPluginPage(id)
            return
        }
        storeCurrent()
        let buffer = buffers[url] ?? Buffer(url: url)
        buffers[url] = buffer
        current = buffer
        selectedURL = url
        addTab(for: url, title: url.lastPathComponent)
        placeholder.isHidden = true
        textView.string = buffer.text
        styleText()
        textView.isEditable = buffer.editable
        highlighter = buffer.editable ? PluginStore.makeHighlighter(for: url) : nil
        (editorScroll.verticalRulerView as? LineNumberRuler)?.textChanged()
        recolor()
        applyDiagnostics()
        scheduleScan(delay: 0)
        attachExtension()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        window?.makeFirstResponder(textView)
        updateTitle()
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
        applyDiagnostics()
        pluginPage.show(id)
        show(pluginPage, in: bodyHost)
        placeholder.isHidden = true
        fileLabel.stringValue = "プラグイン > \(info.name)"
        updateCloud()
    }

    private func attachExtension() {
        guard let current else { return detachExtension() }
        ext = current.editable ? PluginStore.makeExtension(for: current.url, code: editorScroll) : nil
        guard let ext else { return detachExtension() }
        show(ext.bar, in: barHost)
        barHeight.constant = 30
        show(ext.body, in: bodyHost)
        ext.update(text: textView.string)
    }

    private func detachExtension() {
        ext = nil
        barHost.subviews.forEach { $0.removeFromSuperview() }
        barHeight.constant = 0
        show(editorScroll, in: bodyHost)
    }

    private func showEmpty() {
        selectedURL = nil
        highlighter = nil
        detachExtension()
        textView.string = ""
        textView.isEditable = false
        applyDiagnostics()
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
        let runnerOn = PluginStore.isInstalled(RunnerStore.pluginID)
        runButton.isHidden = !runnerOn
        if !runnerOn, let feed = runFeed {
            runPane?.stop()
            if !feed.isHidden { hideBottom(feed) }
            runButton.play.active = false
        }
        updateRunTip()
        let scannerOn = PluginStore.isInstalled(CodeScanner.pluginID)
        if scannerOn != (scanner != nil) {
            scanner = CodeScanner.make()
            diagnostics = [:]
            if scanner == nil, let feed = problemsFeed, !feed.isHidden { hideBottom(feed) }
            applyDiagnostics()
            scheduleScan(delay: 0)
        }
        editorScroll.setLineNumbers(PluginStore.isInstalled(LineNumberRuler.pluginID), textView: textView)
    }

    private func styleText() {
        guard let storage = textView.textStorage else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Settings.font, .foregroundColor: Settings.foreground,
                                                    .paragraphStyle: Settings.paragraphStyle]
        storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attrs
    }

    private func recolor() {
        recolorWork?.cancel()
        recolorWork = nil
        guard let layout = textView.layoutManager else { return }
        let text = textView.string
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        defer { paintErrors() }
        guard let highlighter, let url = current?.url else { return }
        for span in highlighter.spans(text, file: url) {
            layout.addTemporaryAttribute(.foregroundColor, value: span.color, forCharacterRange: span.range)
        }
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
        stripWidth.constant = Settings.bigTabWidth
        [folderButton, pluginButton, runButton.play, terminalButton, gitButton].forEach { $0?.applySize() }
        textView.font = Settings.font
        textView.backgroundColor = Settings.background
        editorScroll.backgroundColor = Settings.background
        textView.insertionPointColor = Settings.foreground
        textView.defaultParagraphStyle = Settings.paragraphStyle
        styleText()
        recolor()
        let wrap = Settings.wrapLines
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        editorScroll.hasHorizontalScroller = !wrap
        if wrap {
            textView.autoresizingMask = [.width]
            textView.frame.size.width = editorScroll.contentSize.width
            textView.textContainer?.containerSize = NSSize(width: editorScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = []
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        ext?.applySettings()

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
            tab.toolTip = url.isFileURL ? url.path : title
            tab.onSelect = { [weak self] in
                guard let self, self.selectedURL != url else { return }
                self.open(url)
            }
            tab.onClose = { [weak self] in self?.closeTab(url) }
            tab.draggable = true
            tabs[url] = tab
            fileTabs.stack.addArrangedSubview(tab)
        }
        tabs.forEach { $0.value.selected = $0.key == url }
        if let tab = tabs[url] { fileTabs.reveal(tab) }
    }

    private func closeTab(_ url: URL) {
        guard let tab = tabs[url] else { return }
        let order = fileTabs.stack.arrangedSubviews
        let index = order.firstIndex(of: tab) ?? 0
        if selectedURL == url { storeCurrent() }
        if let buffer = buffers[url], buffer.dirty, buffer.editable {
            do {
                try buffer.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
                return
            }
        }
        tab.removeFromSuperview()
        tabs[url] = nil
        buffers[url] = nil
        diagnostics[url] = nil
        guard selectedURL == url else { updateTitle(); return }
        current = nil
        let remaining = fileTabs.stack.arrangedSubviews
        if !remaining.isEmpty,
           let next = tabs.first(where: { $0.value === remaining[min(index, remaining.count - 1)] })?.key {
            open(next)
            return
        }
        showEmpty()
    }

    private func storeCurrent() {
        guard let current, current.editable else { return }
        current.text = textView.string
    }

    func textDidChange(_ notification: Notification) {
        ext?.update(text: textView.string)
        scheduleRecolor()
        scheduleScan(delay: 0.5)
        guard let current else { return }
        if Settings.autosaveImmediate, current.editable {
            current.text = textView.string
            do {
                try current.text.write(to: current.url, atomically: false, encoding: .utf8)
                current.dirty = false
            } catch {
                current.dirty = true
            }
            updateTitle()
            scheduleGitRefresh()
            return
        }
        guard !current.dirty else { return }
        current.dirty = true
        updateTitle()
    }

    private func scheduleGitRefresh() {
        gitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshGit() }
        gitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func updateTitle() {
        guard let current else { return updateCloud() }
        let base = baseDirectory
        var relative = current.url.path
        if relative.hasPrefix(base.path + "/") { relative.removeFirst(base.path.count + 1) }
        fileLabel.stringValue = relative.split(separator: "/").joined(separator: " > ")
        updateCloud()
    }

    private func updateCloud() {
        let dirty = buffers.values.contains { $0.dirty }
        cloudButton.image = Self.cloudImage(dirty ? "icloud.and.arrow.up" : "checkmark.icloud")
        cloudButton.toolTip = !dirty ? (Settings.autosaveEnabled ? "自動保存済み" : "保存済み")
            : Settings.autosaveEnabled ? "保存中…" : "未保存（クリックで保存）"
        window?.isDocumentEdited = dirty
    }

    @discardableResult
    func saveAll() -> Error? {
        storeCurrent()
        let dirty = buffers.values.filter { $0.dirty && $0.editable }
        guard !dirty.isEmpty else { return nil }
        defer { refreshGit() }
        for buffer in dirty {
            do {
                try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
                buffer.dirty = false
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

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        runPane?.stop()
        cloning?.cancel()
        autosaveTimer?.invalidate()
        terminalFeed?.stopAll()
        onClose?()
    }
}

extension EditorWindowController {
    private static let refactorKey = "RefactorOnRename"

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        let isRoot = node === root
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        if node.isDirectory {
            add("フォルダ名を変更…", #selector(renameItem(_:)), enabled: !isRoot)
            add("新規ファイル…", #selector(newFileItem(_:)))
        } else {
            add("ファイル名を変更…", #selector(renameItem(_:)), enabled: !isRoot)
            add("ファイルをコピー…", #selector(copyFileItem(_:)))
        }
        add("パスをコピー", #selector(copyPathItem(_:)))
        menu.addItem(.separator())
        add("削除", #selector(deleteItem(_:)), enabled: !isRoot)
    }

    private func node(of sender: Any?) -> FileNode? {
        (sender as? NSMenuItem)?.representedObject as? FileNode
    }

    fileprivate func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func askName(title: String, initial: String, button: String, refactor: Bool = false) -> (name: String, refactor: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: refactor ? 28 : 0, width: 320, height: 24)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: refactor ? 52 : 24))
        accessory.addSubview(field)
        let check = NSButton(checkboxWithTitle: "参照も更新する（リファクタリング）", target: nil, action: nil)
        if refactor {
            UserDefaults.standard.register(defaults: [Self.refactorKey: true])
            check.state = UserDefaults.standard.bool(forKey: Self.refactorKey) ? .on : .off
            check.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
            accessory.addSubview(check)
        }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if refactor { UserDefaults.standard.set(check.state == .on, forKey: Self.refactorKey) }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            showMessage("その名前は使用できません。")
            return nil
        }
        return (name, refactor && check.state == .on)
    }

    private func destination(_ name: String, in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showMessage("「\(name)」は既に存在します。")
            return nil
        }
        return url
    }

    func reloadTree() {
        root.refresh()
        outline.reloadData()
        fitTreeColumn()
    }

    private func reopenTabs(_ map: (URL) -> URL?) {
        let order = fileTabs.stack.arrangedSubviews.compactMap { view in tabs.first { $0.value === view }?.key }
        let selected = selectedURL
        order.forEach { tabs[$0]?.removeFromSuperview() }
        tabs = [:]
        buffers = [:]
        current = nil
        let reopened = order.compactMap(map)
        reopened.forEach { open($0) }
        if let selected, let target = map(selected) {
            open(target)
        } else if reopened.isEmpty {
            showEmpty()
        }
    }

    private static func moved(_ url: URL, from old: URL, to new: URL) -> URL? {
        let path = url.standardizedFileURL.path, oldPath = old.standardizedFileURL.path
        if path == oldPath { return new }
        guard path.hasPrefix(oldPath + "/") else { return url }
        return URL(fileURLWithPath: new.standardizedFileURL.path + path.dropFirst(oldPath.count))
    }

    @objc private func renameItem(_ sender: Any?) {
        guard let node = node(of: sender) else { return }
        let old = node.url
        let kind = node.isDirectory ? "フォルダ" : "ファイル"
        guard let answer = askName(title: "\(kind)名を変更", initial: old.lastPathComponent, button: "変更", refactor: true),
              answer.name != old.lastPathComponent,
              let new = destination(answer.name, in: old.deletingLastPathComponent()) else { return }
        if let error = saveAll() { showError(error); return }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            showError(error)
            return
        }
        let changed = answer.refactor ? Refactor.apply(in: baseDirectory, from: old, to: new, isDirectory: node.isDirectory) : 0
        reopenTabs { Self.moved($0, from: old, to: new) }
        reloadTree()
        refreshGit()
        if changed > 0 { showMessage("\(changed) 件のファイルで参照を更新しました。") }
    }

    @objc private func newFileItem(_ sender: Any?) {
        guard let node = node(of: sender), node.isDirectory,
              let answer = askName(title: "新規ファイル", initial: "", button: "作成"),
              let url = destination(answer.name, in: node.url) else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            showMessage("ファイルを作成できませんでした。")
            return
        }
        reloadTree()
        outline.expandItem(node)
        open(url)
        refreshGit()
    }

    @objc private func copyFileItem(_ sender: Any?) {
        guard let node = node(of: sender), !node.isDirectory else { return }
        let ext = node.url.pathExtension
        let stem = node.url.deletingPathExtension().lastPathComponent
        let initial = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
        guard let answer = askName(title: "ファイルをコピー", initial: initial, button: "コピー"),
              let url = destination(answer.name, in: node.url.deletingLastPathComponent()) else { return }
        if let error = saveAll() { showError(error); return }
        do {
            try FileManager.default.copyItem(at: node.url, to: url)
        } catch {
            showError(error)
            return
        }
        reloadTree()
        open(url)
        refreshGit()
    }

    @objc private func copyPathItem(_ sender: Any?) {
        guard let node = node(of: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func deleteItem(_ sender: Any?) {
        guard let node = node(of: sender), node !== root else { return }
        let alert = NSAlert()
        alert.messageText = "「\(node.url.lastPathComponent)」を削除しますか？"
        alert.informativeText = "ゴミ箱に移動します。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = saveAll() { showError(error); return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            showError(error)
            return
        }
        let gone = node.url.standardizedFileURL.path
        reopenTabs { url in
            let path = url.standardizedFileURL.path
            return path == gone || path.hasPrefix(gone + "/") ? nil : url
        }
        reloadTree()
        refreshGit()
    }
}

extension EditorWindowController {
    private func updateProjectTitle() {
        projectButton.attributedTitle = NSAttributedString(string: project.name + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor])
        window?.title = "\(project.name) — \(appName)"
    }

    private func menuItem(_ title: String, _ action: Selector?, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    @objc private func projectClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("プロジェクト名を変更…", #selector(renameProject)))
        menu.addItem(.separator())
        let others = ProjectStore.all.filter { $0.path != project.path }
        let header = menuItem("他のプロジェクト", nil)
        header.isEnabled = false
        menu.addItem(header)
        if others.isEmpty {
            let none = menuItem("（ありません）", nil)
            none.isEnabled = false
            menu.addItem(none)
        }
        for other in others {
            let item = menuItem(other.name, #selector(otherProjectClicked(_:)), other.path)
            item.toolTip = other.path
            item.image = NSWorkspace.shared.icon(forFile: other.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: projectButton.bounds.height + 4), in: projectButton)
    }

    @objc private func renameProject() {
        let alert = NSAlert()
        alert.messageText = "プロジェクト名を変更"
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }
        if ProjectStore.all.contains(where: { $0.path == project.path }) {
            ProjectStore.rename(project, to: name)
        } else {
            ProjectStore.touch(Project(name: name, path: project.path))
        }
        project.name = name
        updateProjectTitle()
        onProjectRenamed?()
    }

    @objc private func otherProjectClicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let other = ProjectStore.all.first(where: { $0.path == path }) else { return }
        guard FileManager.default.fileExists(atPath: other.path) else {
            showMessage("「\(other.name)」が見つかりません。\n\(other.path)")
            return
        }
        let alert = NSAlert()
        alert.messageText = "「\(other.name)」を開く"
        alert.informativeText = other.path
        alert.addButton(withTitle: "このウィンドウで開く")
        alert.addButton(withTitle: "別のウィンドウで開く")
        alert.addButton(withTitle: "キャンセル")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        if response == .alertFirstButtonReturn, let error = saveAll() {
            showError(error)
            return
        }
        onOpenProject?(other, response == .alertSecondButtonReturn)
    }

    @objc private func pathClicked(_ gesture: NSClickGestureRecognizer) {
        guard let url = selectedURL, url.isFileURL else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("パスをコピー", #selector(copyCurrentPath(_:)), url.path))
        menu.addItem(menuItem("相対パスをコピー", #selector(copyCurrentPath(_:)), relativePath(url)))
        menu.addItem(menuItem("Finderで表示", #selector(revealCurrent(_:)), url.path))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fileLabel.bounds.height + 4), in: fileLabel)
    }

    private func relativePath(_ url: URL) -> String {
        let base = baseDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    @objc private func copyCurrentPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func revealCurrent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

extension EditorWindowController {
    private func updateRunTip() {
        runButton.play.toolTip = runner.selected.map { "実行: \($0.name)" } ?? "実行（起動構成を作成）"
    }

    @objc private func runClicked() {
        if let config = runner.selected { return run(config) }
        newRunConfig()
    }

    private func showRunMenu(_ anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if runner.configs.isEmpty {
            let none = menuItem("起動構成なし", nil)
            none.isEnabled = false
            menu.addItem(none)
        }
        for config in runner.configs {
            let item = menuItem(config.name, #selector(selectRunConfig(_:)), config.id)
            item.state = config.id == runner.selectedID ? .on : .off
            item.toolTip = runner.command(for: config)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("新しい起動構成…", #selector(newRunConfig)))
        if let selected = runner.selected {
            menu.addItem(menuItem("「\(selected.name)」を編集…", #selector(editRunConfig)))
            menu.addItem(menuItem("「\(selected.name)」を削除", #selector(deleteRunConfig)))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX, y: anchor.bounds.maxY), in: anchor)
    }

    @objc private func selectRunConfig(_ sender: NSMenuItem) {
        runner.selectedID = sender.representedObject as? String
        updateRunTip()
    }

    @objc private func newRunConfig() {
        let initial = current.map { RunConfig(name: $0.url.lastPathComponent, directory: "", script: relativePath($0.url)) }
        guard let config = RunnerStore.edit(initial, base: baseDirectory, title: "新しい起動構成") else { return }
        var created = config
        created.id = UUID().uuidString
        runner.upsert(created)
        updateRunTip()
    }

    @objc private func editRunConfig() {
        guard let selected = runner.selected,
              let config = RunnerStore.edit(selected, base: baseDirectory, title: "起動構成を編集") else { return }
        runner.upsert(config)
        updateRunTip()
    }

    @objc private func deleteRunConfig() {
        guard let selected = runner.selected else { return }
        runner.remove(selected.id)
        updateRunTip()
    }

    private func run(_ config: RunConfig) {
        if let error = saveAll() { return showError(error) }
        let feed: FeedView
        if let existing = runFeed {
            feed = existing
        } else {
            let stop = FeedView.barButton(symbol: "stop.fill", tip: "停止", target: self, action: #selector(stopRun))
            let again = FeedView.barButton(symbol: "arrow.clockwise", tip: "再実行", target: self, action: #selector(rerun))
            feed = FeedView(title: "実行", content: runContainer, extras: [stop, again])
            feed.onRemove = { [weak self, weak feed] in
                guard let self, let feed else { return }
                self.hideBottom(feed)
                self.runButton.play.active = false
            }
            runFeed = feed
            feed.isHidden = true
            rightSplit.addArrangedSubview(feed)
        }
        runPane?.stop()
        runPane?.removeFromSuperview()
        let pane = TerminalPane(cwd: runner.directory(of: config).path, command: runner.command(for: config))
        pane.translatesAutoresizingMaskIntoConstraints = false
        runContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: runContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: runContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: runContainer.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: runContainer.bottomAnchor),
        ])
        runPane = pane
        runConfig = config
        feed.title = "実行: \(config.name)"
        if feed.isHidden { showBottom(feed) }
        DispatchQueue.main.async { pane.focus() }
    }

    @objc private func stopRun() {
        guard let pane = runPane, pane.running else { return }
        pane.stop()
        pane.show("\r\n\u{1B}[2m[停止しました]\u{1B}[0m\r\n")
    }

    @objc private func rerun() {
        if let config = runConfig.flatMap({ c in runner.configs.first { $0.id == c.id } }) ?? runner.selected { run(config) }
    }
}

extension EditorWindowController {
    private func toggleProblems() {
        if let feed = problemsFeed, !feed.isHidden {
            hideBottom(feed)
            return
        }
        let feed: FeedView
        if let existing = problemsFeed {
            feed = existing
        } else {
            feed = FeedView(title: "問題", content: problemsView)
            feed.onRemove = { [weak self] in self?.toggleProblems() }
            problemsFeed = feed
            rightSplit.addArrangedSubview(feed)
        }
        showBottom(feed)
        applyDiagnostics()
    }

    private func scheduleScan(delay: TimeInterval) {
        scanWork?.cancel()
        guard scanner != nil, let current, current.editable else { return }
        let work = DispatchWorkItem { [weak self] in self?.scanNow() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scanNow() {
        guard let scanner, let current, current.editable else { return }
        let url = current.url
        scanner.scan(textView.string, url: url) { [weak self] found in
            guard let self, self.buffers[url] != nil else { return }
            self.diagnostics[url] = found
            self.applyDiagnostics()
        }
    }

    private func applyDiagnostics() {
        let url = current?.editable == true ? current?.url : nil
        let mine = url.flatMap { diagnostics[$0] } ?? []
        badge.isHidden = scanner == nil || url == nil
        badge.update(errors: mine.filter { $0.severity == .error }.count, warnings: mine.filter { $0.severity == .warning }.count)
        let order = fileTabs.stack.arrangedSubviews.compactMap { view in tabs.first { $0.value === view }?.key }
        let others = order.filter { $0 != url }.flatMap { diagnostics[$0] ?? [] }
        problemsView.show(mine + others)

        let length = (textView.string as NSString).length
        let valid = mine.filter { NSMaxRange($0.range) <= length }
        (textView.layoutManager as? DiagnosticLayoutManager)?.marks = valid.map { ($0.range, $0.color) }
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.toolTip, range: NSRange(location: 0, length: storage.length))
            for item in valid {
                let kind = item.severity == .error ? "エラー" : "警告"
                storage.addAttribute(.toolTip, value: "\(kind): \(item.message)", range: item.range)
            }
            storage.endEditing()
        }
        recolor()
        textView.needsDisplay = true
    }

    private func paintErrors() {
        guard let layout = textView.layoutManager as? DiagnosticLayoutManager else { return }
        for mark in layout.marks where mark.color == .systemRed {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed, forCharacterRange: mark.range)
        }
    }

    private func reveal(_ item: Diagnostic) {
        if current?.url != item.url { open(item.url) }
        let length = (textView.string as NSString).length
        guard NSMaxRange(item.range) <= length else { return }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(item.range)
        textView.scrollRangeToVisible(item.range)
        textView.showFindIndicator(for: item.range)
    }
}
