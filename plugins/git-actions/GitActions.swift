import AppKit
import UniformTypeIdentifiers
@testable import FlareStackIDE

enum GitCommand {
    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
        + (ProcessInfo.processInfo.environment["PATH"] ?? "")

    static func run(_ args: [String], in dir: URL) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["PATH"] = searchPath
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct GitState {
    var top: URL
    var branch: String
    var branches: [String]
    var upstream: String?
    var staged: [GitChange]
    var unstaged: [GitChange]
    var operation: String?
    var remoteBranches: [String] = []
    var stashes: [(ref: String, subject: String)] = []
    var tags: [String] = []
    var conflicts: [String] = []
    var ahead = 0
    var behind = 0
    var lastCommit: String?

    static func load(from dir: URL) -> GitState? {
        guard let root = Git.run(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return nil }
        let top = URL(fileURLWithPath: root)
        let branches = (Git.run(["branch", "--format=%(refname:short)"], in: top) ?? "").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("(") }
        let upstream = Git.run(["rev-parse", "--abbrev-ref", "@{u}"], in: top)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = GitState(top: top, branch: Git.branch(in: top) ?? "", branches: branches, upstream: upstream, staged: [], unstaged: [])
        let lines: ([String]) -> [String] = { (Git.run($0, in: top) ?? "").split(separator: "\n").map(String.init) }
        state.remoteBranches = lines(["branch", "-r", "--format=%(refname:short)"]).filter { !$0.hasSuffix("/HEAD") && $0.contains("/") }
        state.stashes = lines(["stash", "list", "--format=%gd%x00%s"]).compactMap {
            let parts = $0.split(separator: "\0", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        state.tags = lines(["tag", "--sort=-creatordate"])
        state.conflicts = lines(["diff", "--name-only", "--diff-filter=U"])
        if upstream != nil, let counts = Git.run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], in: top)?
            .split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap({ Int($0) }), counts.count == 2 {
            state.ahead = counts[0]
            state.behind = counts[1]
        }
        state.lastCommit = Git.run(["log", "-1", "--format=%h %s"], in: top)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.lastCommit?.isEmpty == true { state.lastCommit = nil }
        if let dir = Git.run(["rev-parse", "--absolute-git-dir"], in: top)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let exists = { FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
            state.operation = exists("rebase-merge") || exists("rebase-apply") ? "rebase" : exists("MERGE_HEAD") ? "merge" : nil
        }
        let entries = (Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: top) ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            i += 1
            guard entry.count > 3 else { continue }
            let x = entry.first!, y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            if x == "R" || x == "C" || y == "R" || y == "C" { i += 1 }
            if x == "?" {
                state.unstaged.append(GitChange(kind: .untracked, path: path, staged: false))
                continue
            }
            if x != " " { state.staged.append(GitChange(kind: kind(x), path: path, staged: true)) }
            if y != " " { state.unstaged.append(GitChange(kind: kind(y), path: path, staged: false)) }
        }
        return state
    }

    private static func kind(_ code: Character) -> GitChange.Kind {
        switch code {
        case "D": return .deleted
        case "R": return .renamed
        case "A": return .added
        default: return .modified
        }
    }
}

final class GitTint: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat
    var stroke: NSColor?

    init(fill: NSColor, radius: CGFloat = 6, stroke: NSColor? = nil) {
        self.fill = fill
        self.radius = radius
        self.stroke = stroke
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.cornerRadius = radius
            layer?.borderWidth = stroke == nil ? 0 : 1
            layer?.borderColor = stroke?.cgColor
        }
    }
}

final class GitMessageView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

final class GitActionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String, count: Int, staged: Bool)
        case file(GitChange)
    }

    private weak var editor: EditorWindowController?
    private let branchMenu = NSPopUpButton()
    private let syncLabel = NSTextField(labelWithString: "")
    private let banner = GitTint(fill: NSColor.systemOrange.withAlphaComponent(0.14), radius: 7, stroke: NSColor.systemOrange.withAlphaComponent(0.35))
    private let bannerRow = NSStackView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let message = GitMessageView()
    private let commitButton = NSButton(title: "コミット", target: nil, action: nil)
    private let commitSummary = NSTextField(labelWithString: "")
    private let lastCommit = NSTextField(labelWithString: "")
    private let clean = NSStackView()
    private let empty = NSStackView()
    private let body = NSView()
    private var pullButton: NSButton!
    private var pushButton: NSButton!
    private var actionButtons: [NSButton] = []
    private var rows: [Row] = []
    private var state: GitState?
    private var busy = false
    private var pendingAction: (() -> Void)?

    private static func symbol(_ name: String, _ size: CGFloat = 11, _ weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private func toolButton(_ title: String, _ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, image: Self.symbol(symbol) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = tip
        return button
    }

    private func divider() -> NSView {
        let line = GitTint(fill: .separatorColor, radius: 0)
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    private static func placeholder(_ symbol: String, _ title: String, _ detail: String, into stack: NSStackView) {
        let icon = NSImageView(image: Self.symbol(symbol, 28, .light) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.textColor = .secondaryLabelColor
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor
        [icon, head, sub].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(8, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init(frame: .zero)
        branchMenu.target = self
        branchMenu.action = #selector(branchChosen)
        branchMenu.controlSize = .small
        branchMenu.bezelStyle = .accessoryBarAction
        branchMenu.font = .systemFont(ofSize: 12, weight: .semibold)
        branchMenu.toolTip = "ブランチを切り替え"
        let branchIcon = NSImageView(image: Self.symbol("arrow.triangle.branch", 12, .semibold) ?? NSImage())
        branchIcon.contentTintColor = .controlAccentColor
        syncLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        syncLabel.textColor = .secondaryLabelColor

        let fetchButton = toolButton("Fetch", "arrow.triangle.2.circlepath", "すべてのリモートから取得", #selector(fetch))
        pullButton = toolButton("Pull", "arrow.down.circle", "Pull（fast-forward のみ）", #selector(pull))
        pushButton = toolButton("Push", "arrow.up.circle", "Push", #selector(push))
        let stashButton = toolButton("", "tray.and.arrow.down", "Stash（新規ファイルも含む）", #selector(stash))
        let popButton = toolButton("", "tray.and.arrow.up", "Stash Pop", #selector(stashPop))
        let stashList = toolButton("Stash", "chevron.down", "Stash 一覧", #selector(stashMenu(_:)))
        let tagButton = toolButton("タグ", "chevron.down", "タグ", #selector(tagMenu(_:)))
        let rebaseButton = toolButton("Rebase", "chevron.down", "Rebase", #selector(rebaseMenu(_:)))
        [stashList, tagButton, rebaseButton].forEach { $0.imagePosition = .imageTrailing }
        actionButtons = [fetchButton, pullButton, pushButton, stashButton, popButton, stashList, tagButton, rebaseButton]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbarRow = NSStackView(views: [branchIcon, branchMenu, syncLabel, spacer,
                                             fetchButton, pullButton, pushButton, divider(),
                                             stashButton, popButton, stashList, divider(), tagButton, rebaseButton])
        toolbarRow.spacing = 4
        toolbarRow.setCustomSpacing(2, after: branchIcon)
        toolbarRow.setCustomSpacing(8, after: branchMenu)
        toolbarRow.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        toolbarRow.alignment = .centerY
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        let toolbarLine = GitTint(fill: .separatorColor, radius: 0)

        let warn = NSImageView(image: Self.symbol("exclamationmark.triangle.fill", 12) ?? NSImage())
        warn.contentTintColor = .systemOrange
        bannerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        bannerLabel.textColor = .labelColor
        bannerRow.spacing = 6
        bannerRow.alignment = .centerY
        bannerRow.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        bannerRow.translatesAutoresizingMaskIntoConstraints = false
        bannerRow.addArrangedSubview(warn)
        banner.addSubview(bannerRow)
        banner.isHidden = true

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .custom
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.drawsBackground = false
        list.translatesAutoresizingMaskIntoConstraints = false
        Self.placeholder("checkmark.seal", "作業ツリーはクリーンです", "コミットしていない変更はありません", into: clean)
        clean.isHidden = true

        let card = GitTint(fill: NSColor.labelColor.withAlphaComponent(0.04), radius: 10, stroke: NSColor.separatorColor)
        let cardTitle = NSTextField(labelWithString: "コミット")
        cardTitle.font = .systemFont(ofSize: 12, weight: .bold)
        commitSummary.font = .systemFont(ofSize: 11)
        commitSummary.textColor = .secondaryLabelColor
        commitSummary.lineBreakMode = .byTruncatingTail
        message.placeholder = "メッセージ（⌘↩ でコミット）"
        message.isRichText = false
        message.font = .systemFont(ofSize: 12)
        message.drawsBackground = false
        message.textContainerInset = NSSize(width: 6, height: 6)
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.autoresizingMask = [.width]
        let messageBox = GitTint(fill: .textBackgroundColor, radius: 6, stroke: .separatorColor)
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.drawsBackground = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageBox.addSubview(messageScroll)
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .regular
        commitButton.bezelColor = .controlAccentColor
        commitButton.image = Self.symbol("checkmark", 11, .bold)
        commitButton.imagePosition = .imageLeading
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        lastCommit.font = .systemFont(ofSize: 10)
        lastCommit.textColor = .tertiaryLabelColor
        lastCommit.lineBreakMode = .byTruncatingTail
        lastCommit.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [cardTitle, commitSummary, messageBox, commitButton, lastCommit].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        body.translatesAutoresizingMaskIntoConstraints = false
        [toolbarRow, toolbarLine, banner, list, clean, card].forEach(body.addSubview)
        Self.placeholder("externaldrive.badge.questionmark", "Git リポジトリではありません", "プロジェクトのフォルダで git init すると使えます", into: empty)
        empty.isHidden = true
        addSubview(body)
        addSubview(empty)
        let listUnderToolbar = list.topAnchor.constraint(equalTo: toolbarLine.bottomAnchor, constant: 4)
        listUnderToolbar.priority = .defaultHigh
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbarRow.topAnchor.constraint(equalTo: body.topAnchor),
            toolbarRow.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            toolbarRow.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            toolbarLine.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
            toolbarLine.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            toolbarLine.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            toolbarLine.heightAnchor.constraint(equalToConstant: 1),
            banner.topAnchor.constraint(equalTo: toolbarLine.bottomAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: banner.topAnchor),
            bannerRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            listUnderToolbar,
            list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            list.trailingAnchor.constraint(equalTo: card.leadingAnchor, constant: -10),
            clean.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            clean.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            card.topAnchor.constraint(equalTo: toolbarLine.bottomAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
            card.widthAnchor.constraint(equalToConstant: 300),
            cardTitle.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            commitSummary.firstBaselineAnchor.constraint(equalTo: cardTitle.firstBaselineAnchor),
            commitSummary.leadingAnchor.constraint(equalTo: cardTitle.trailingAnchor, constant: 8),
            commitSummary.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            messageBox.topAnchor.constraint(equalTo: cardTitle.bottomAnchor, constant: 8),
            messageBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            messageBox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            messageBox.bottomAnchor.constraint(equalTo: commitButton.topAnchor, constant: -8),
            messageScroll.topAnchor.constraint(equalTo: messageBox.topAnchor, constant: 1),
            messageScroll.leadingAnchor.constraint(equalTo: messageBox.leadingAnchor, constant: 1),
            messageScroll.trailingAnchor.constraint(equalTo: messageBox.trailingAnchor, constant: -1),
            messageScroll.bottomAnchor.constraint(equalTo: messageBox.bottomAnchor, constant: -1),
            commitButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            commitButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            lastCommit.centerYAnchor.constraint(equalTo: commitButton.centerYAnchor),
            lastCommit.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            lastCommit.trailingAnchor.constraint(lessThanOrEqualTo: commitButton.leadingAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        bannerTop = list.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4)
    }

    private var bannerTop: NSLayoutConstraint?

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        guard let editor else { return }
        let dir = editor.baseDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = GitState.load(from: dir)
            DispatchQueue.main.async { self?.show(loaded) }
        }
    }

    private func show(_ loaded: GitState?) {
        state = loaded
        body.isHidden = loaded == nil
        empty.isHidden = loaded != nil
        guard let loaded else { return pendingAction = nil }
        defer {
            let action = pendingAction
            pendingAction = nil
            action?()
        }
        branchMenu.removeAllItems()
        branchMenu.addItems(withTitles: loaded.branches.contains(loaded.branch) ? loaded.branches : [loaded.branch] + loaded.branches)
        branchMenu.selectItem(withTitle: loaded.branch)
        branchMenu.menu?.addItem(.separator())
        branchMenu.addItem(withTitle: "新しいブランチ…")
        branchMenu.lastItem?.representedObject = Self.newBranch
        if let upstream = loaded.upstream {
            syncLabel.stringValue = loaded.ahead == 0 && loaded.behind == 0 ? "\(upstream) と同期済み" : "\(upstream)  ↑\(loaded.ahead) ↓\(loaded.behind)"
            syncLabel.textColor = loaded.behind > 0 ? .systemOrange : .secondaryLabelColor
        } else {
            syncLabel.stringValue = "上流なし（Push で origin に設定）"
            syncLabel.textColor = .tertiaryLabelColor
        }
        pullButton.title = loaded.behind > 0 ? "Pull \(loaded.behind)" : "Pull"
        pushButton.title = loaded.ahead > 0 ? "Push \(loaded.ahead)" : "Push"
        pushButton.contentTintColor = loaded.ahead > 0 ? .controlAccentColor : nil
        pullButton.contentTintColor = loaded.behind > 0 ? .systemOrange : nil
        showBanner(loaded)
        rows = []
        if !loaded.staged.isEmpty {
            rows.append(.header("ステージ済み", count: loaded.staged.count, staged: true))
            rows += loaded.staged.map { .file($0) }
        }
        if !loaded.unstaged.isEmpty {
            rows.append(.header("変更", count: loaded.unstaged.count, staged: false))
            rows += loaded.unstaged.map { .file($0) }
        }
        clean.isHidden = !rows.isEmpty
        table.reloadData()
        let count = loaded.staged.count
        commitButton.title = count > 0 ? "コミット（\(count)）" : "コミット"
        commitSummary.stringValue = count > 0 ? "\(count) 件 → \(loaded.branch)" : "ステージしたファイルはありません"
        lastCommit.stringValue = loaded.lastCommit.map { "前回: \($0)" } ?? ""
        lastCommit.toolTip = lastCommit.stringValue
    }

    private func perform(_ args: [String], title: String, done: String? = nil, then: (() -> Void)? = nil) {
        guard !busy, let state else { return }
        busy = true
        let window = window
        (actionButtons + [commitButton]).forEach { $0.isEnabled = false }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitCommand.run(args, in: state.top)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                (self.actionButtons + [self.commitButton]).forEach { $0.isEnabled = true }
                if result.ok {
                    if let done { Toasts.post(done, in: window) }
                    then?()
                } else {
                    Toasts.post("\(title)に失敗しました", message: result.output, in: window)
                }
                self.reload()
                self.editor?.refreshGit()
                self.editor?.reloadGitReport()
                NotificationCenter.default.post(name: PluginEvent.gitChanged, object: nil)
            }
        }
    }

    private var saved: Bool {
        guard let error = editor?.saveAll() else { return true }
        editor?.showError(error)
        return false
    }

    @objc private func fetch() { perform(["fetch", "--all"], title: "fetch", done: "fetch しました") }

    @objc private func pull() {
        if saved { perform(["pull", "--ff-only"], title: "pull", done: "pull しました") }
    }

    @objc private func push() {
        perform(state?.upstream == nil ? ["push", "-u", "origin", "HEAD"] : ["push"], title: "push", done: "push しました")
    }

    @objc private func stash() {
        if saved { perform(["stash", "push", "--include-untracked"], title: "stash", done: "stash しました") }
    }

    @objc private func stashPop() {
        if saved { perform(["stash", "pop"], title: "stash pop", done: "stash を戻しました") }
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    private func showBanner(_ state: GitState) {
        bannerRow.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        guard let operation = state.operation else {
            bannerTop?.isActive = false
            return banner.isHidden = true
        }
        let left = state.conflicts.isEmpty ? "" : "（競合 \(state.conflicts.count) 件）"
        bannerLabel.stringValue = (operation == "rebase" ? "rebase の途中です" : "マージの途中です") + left
        var views: [NSView] = [bannerLabel]
        if operation == "rebase" {
            views += [smallButton("続ける", #selector(rebaseContinue)), smallButton("スキップ", #selector(rebaseSkip)), smallButton("中止", #selector(rebaseAbort))]
        } else {
            views += [smallButton("マージを完了", #selector(mergeContinue)), smallButton("マージを中止", #selector(mergeAbort))]
        }
        views.forEach(bannerRow.addArrangedSubview)
        banner.isHidden = false
        bannerTop?.isActive = true
    }

    private func popUp(_ menu: NSMenu, from sender: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func menuItem(_ title: String, _ action: Selector, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func ask(_ title: String, _ detail: String, button: String, fields: [String] = [], check: String? = nil) -> (values: [String], checked: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let inputs = fields.map { placeholder -> NSTextField in
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = placeholder
            return field
        }
        let box = check.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        let stack = NSStackView(views: inputs + (box.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if !stack.arrangedSubviews.isEmpty {
            stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(stack.arrangedSubviews.count) * 32)
            alert.accessoryView = stack
        }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (inputs.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }, box?.state == .on)
    }

    @objc func stashMenu(_ sender: NSButton) {
        guard let state else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("Stash（新規ファイルも含む）", #selector(stash)))
        menu.addItem(.separator())
        if state.stashes.isEmpty {
            let none = NSMenuItem(title: "stash はありません", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for entry in state.stashes {
            let item = NSMenuItem(title: "\(entry.ref)  \(entry.subject)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(menuItem("適用（残す）", #selector(stashApply(_:)), entry.ref))
            sub.addItem(menuItem("Pop（適用して削除）", #selector(stashPopRef(_:)), entry.ref))
            sub.addItem(.separator())
            sub.addItem(menuItem("削除…", #selector(stashDrop(_:)), entry.ref))
            item.submenu = sub
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func stashApply(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String, saved else { return }
        perform(["stash", "apply", ref], title: "stash の適用", done: "\(ref) を適用しました")
    }

    @objc private func stashPopRef(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String, saved else { return }
        perform(["stash", "pop", ref], title: "stash pop", done: "\(ref) を戻しました")
    }

    @objc private func stashDrop(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String,
              ask("\(ref) を削除しますか？", "この操作は元に戻せません。", button: "削除") != nil else { return }
        perform(["stash", "drop", ref], title: "stash の削除", done: "\(ref) を削除しました")
    }

    @objc func tagMenu(_ sender: NSButton) {
        guard let state else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("タグを作成…", #selector(createTag)))
        menu.addItem(menuItem("全てのタグを push", #selector(pushTags)))
        menu.addItem(.separator())
        if state.tags.isEmpty {
            let none = NSMenuItem(title: "タグはありません", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for tag in state.tags.prefix(50) {
            let item = NSMenuItem(title: tag, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(menuItem("push", #selector(pushTag(_:)), tag))
            sub.addItem(menuItem("削除…", #selector(deleteTag(_:)), tag))
            item.submenu = sub
            menu.addItem(item)
        }
        popUp(menu, from: sender)
    }

    @objc private func createTag() {
        guard let input = ask("タグを作成", "現在のコミット（HEAD）に付けます。メッセージを入れると注釈付きタグになります", button: "作成",
                              fields: ["タグ名（例: v1.0.0）", "メッセージ（任意）"]), let name = input.values.first, !name.isEmpty else { return }
        let message = input.values[1]
        perform(message.isEmpty ? ["tag", name] : ["tag", "-a", name, "-m", message], title: "タグの作成", done: "タグ \(name) を作成しました")
    }

    @objc private func pushTags() { perform(["push", "origin", "--tags"], title: "タグの push", done: "タグを push しました") }

    @objc private func pushTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        perform(["push", "origin", "refs/tags/\(tag)"], title: "タグの push", done: "\(tag) を push しました")
    }

    @objc private func deleteTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String,
              let input = ask("タグ \(tag) を削除しますか？", "ローカルのタグを削除します。", button: "削除", check: "origin からも削除する") else { return }
        perform(["tag", "-d", tag], title: "タグの削除", done: input.checked ? nil : "\(tag) を削除しました") { [weak self] in
            guard input.checked else { return }
            self?.perform(["push", "origin", "--delete", "refs/tags/\(tag)"], title: "リモートのタグの削除", done: "\(tag) をローカルと origin から削除しました")
        }
    }

    @objc func rebaseMenu(_ sender: NSButton) {
        guard let state else { return }
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(state.branch) を次の上に rebase", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for branch in state.branches where branch != state.branch { menu.addItem(menuItem(branch, #selector(rebaseOnto(_:)), branch)) }
        if !state.remoteBranches.isEmpty { menu.addItem(.separator()) }
        for branch in state.remoteBranches { menu.addItem(menuItem(branch, #selector(rebaseOnto(_:)), branch)) }
        popUp(menu, from: sender)
    }

    @objc private func rebaseOnto(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String, let state, saved,
              ask("\(state.branch) を \(target) の上に rebase しますか？", "コミットの履歴が書き換わります。push 済みのブランチでは注意してください。", button: "rebase") != nil
        else { return }
        perform(["rebase", target], title: "rebase", done: "\(target) の上に rebase しました")
    }

    @objc private func rebaseContinue() {
        if saved { perform(["-c", "core.editor=true", "rebase", "--continue"], title: "rebase の続行", done: "rebase を続けました") }
    }

    @objc private func rebaseSkip() {
        if saved { perform(["rebase", "--skip"], title: "rebase のスキップ", done: "このコミットをスキップしました") }
    }

    @objc private func rebaseAbort() {
        guard ask("rebase を中止しますか？", "rebase を始める前の状態に戻ります。", button: "中止") != nil else { return }
        perform(["rebase", "--abort"], title: "rebase の中止", done: "rebase を中止しました")
    }

    @objc private func mergeContinue() {
        guard state?.conflicts.isEmpty != false else {
            Toasts.post("競合が残っています", message: "解決してステージしてから完了してください", in: window)
            return
        }
        if saved { perform(["commit", "--no-edit"], title: "マージの完了", done: "マージを完了しました") }
    }

    @objc private func mergeAbort() {
        guard ask("マージを中止しますか？", "マージを始める前の状態に戻ります。", button: "中止") != nil else { return }
        perform(["merge", "--abort"], title: "マージの中止", done: "マージを中止しました")
    }

    private func whenLoaded(_ body: @escaping () -> Void) {
        if state != nil { return body() }
        pendingAction = body
        reload()
    }

    func fetchAction() { whenLoaded { [weak self] in self?.fetch() } }
    func pullAction() { whenLoaded { [weak self] in self?.pull() } }
    func pushAction() { whenLoaded { [weak self] in self?.push() } }
    func stashAction() { whenLoaded { [weak self] in self?.stash() } }

    @objc private func commit() {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state?.staged.isEmpty == false else {
            Toasts.post("ステージしたファイルがありません", in: window)
            return
        }
        guard !text.isEmpty else {
            Toasts.post("コミットメッセージを入力してください", in: window)
            return
        }
        guard saved else { return }
        perform(["commit", "-m", text], title: "コミット", done: "コミットしました") { [weak self] in self?.message.string = "" }
    }

    private static let newBranch = "git-actions.new-branch"

    @objc private func branchChosen() {
        guard let state, let title = branchMenu.titleOfSelectedItem, title != state.branch else { return }
        guard saved else { return branchMenu.selectItem(withTitle: state.branch) }
        guard branchMenu.selectedItem?.representedObject as? String == Self.newBranch else {
            return perform(["switch", title], title: "ブランチの切り替え")
        }
        branchMenu.selectItem(withTitle: state.branch)
        let alert = NSAlert()
        alert.messageText = "新しいブランチ"
        alert.informativeText = "\(state.branch) から作って切り替えます"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        let name = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let branch = name.stringValue.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { perform(["switch", "-c", branch], title: "ブランチの作成") }
    }

    @objc private func stage(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .file(let change) = rows[sender.tag] else { return }
        perform(["--literal-pathspecs", "add", "--", change.path], title: "ステージ")
    }

    @objc private func unstage(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .file(let change) = rows[sender.tag] else { return }
        perform(["--literal-pathspecs", "reset", "-q", "--", change.path], title: "ステージの解除")
    }

    @objc private func stageAll() { perform(["add", "--all"], title: "ステージ") }

    @objc private func unstageAll() { perform(["reset", "-q"], title: "ステージの解除") }

    @objc private func discard(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .file(let change) = rows[sender.tag] else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = change.kind == .untracked ? "\(change.path) を削除しますか？" : "\(change.path) の変更を破棄しますか？"
        alert.informativeText = "この操作は元に戻せません。"
        alert.addButton(withTitle: change.kind == .untracked ? "削除" : "破棄")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn, saved else { return }
        perform(["--literal-pathspecs"] + (change.kind == .untracked ? ["clean", "-f", "--", change.path] : ["checkout", "--", change.path]), title: "変更の破棄")
    }

    @objc private func rowClicked() {
        guard rows.indices.contains(table.clickedRow), case .file(let change) = rows[table.clickedRow], let state else { return }
        let url = state.top.appendingPathComponent(change.path)
        if FileManager.default.fileExists(atPath: url.path) { editor?.open(url) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, row: Int, tint: NSColor = .secondaryLabelColor) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol, 11, .semibold) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = tint
        button.toolTip = tip
        button.tag = row
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func badge(_ change: GitChange) -> NSView {
        let box = GitTint(fill: change.color.withAlphaComponent(0.18), radius: 4)
        let letter = NSTextField(labelWithString: change.letter)
        letter.font = .monospacedSystemFont(ofSize: 10, weight: .heavy)
        letter.textColor = change.color
        letter.alignment = .center
        letter.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(letter)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 18),
            box.heightAnchor.constraint(equalToConstant: 16),
            letter.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 28 : 34 }
        return 24
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let leading: [NSView]
        let trailing: [NSView]
        switch rows[row] {
        case .header(let title, let count, let staged):
            let icon = NSImageView(image: Self.symbol(staged ? "checkmark.circle.fill" : "pencil.circle.fill", 12) ?? NSImage())
            icon.contentTintColor = staged ? .systemGreen : .systemOrange
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = .labelColor
            let pill = GitTint(fill: NSColor.secondaryLabelColor.withAlphaComponent(0.15), radius: 7)
            let number = NSTextField(labelWithString: "\(count)")
            number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            number.textColor = .secondaryLabelColor
            number.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(number)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 14),
                pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
                number.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                number.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                number.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            ])
            let all = NSButton(title: staged ? "すべて解除" : "すべてステージ", image: Self.symbol(staged ? "minus" : "plus", 10, .bold) ?? NSImage(),
                               target: self, action: staged ? #selector(unstageAll) : #selector(stageAll))
            all.bezelStyle = .accessoryBarAction
            all.showsBorderOnlyWhileMouseInside = true
            all.controlSize = .small
            all.font = .systemFont(ofSize: 10, weight: .medium)
            all.imagePosition = .imageLeading
            all.contentTintColor = .secondaryLabelColor
            leading = [icon, label, pill]
            trailing = [all]
        case .file(let change):
            let name = (change.path as NSString).lastPathComponent
            let folder = (change.path as NSString).deletingLastPathComponent
            let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
            let icon = NSImageView(image: NSWorkspace.shared.icon(for: type))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let title = NSTextField(labelWithString: name)
            title.font = .systemFont(ofSize: 12)
            title.textColor = change.kind == .deleted ? .secondaryLabelColor : .labelColor
            title.lineBreakMode = .byTruncatingMiddle
            title.setContentCompressionResistancePriority(.init(400), for: .horizontal)
            let path = NSTextField(labelWithString: folder)
            path.font = .systemFont(ofSize: 10)
            path.textColor = .tertiaryLabelColor
            path.lineBreakMode = .byTruncatingHead
            path.setContentCompressionResistancePriority(.init(300), for: .horizontal)
            let stack = NSStackView(views: [badge(change), icon, title, path])
            stack.spacing = 6
            stack.toolTip = change.path
            leading = [stack]
            trailing = change.staged ? [iconButton("minus", "ステージ解除", #selector(unstage(_:)), row: row)]
                : [iconButton("arrow.uturn.backward", change.kind == .untracked ? "削除" : "変更を破棄", #selector(discard(_:)), row: row, tint: .systemRed),
                   iconButton("plus", "ステージ", #selector(stage(_:)), row: row, tint: .systemGreen)]
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: leading + [spacer] + trailing)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
        return stack
    }
}
