import AppKit
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

final class GitActionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String, staged: Bool)
        case file(GitChange)
    }

    private weak var editor: EditorWindowController?
    private let branchMenu = NSPopUpButton()
    private let banner = NSStackView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let message = NSTextView()
    private let commitButton = NSButton(title: "コミット", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "Git リポジトリではありません")
    private let body = NSView()
    private var actionButtons: [NSButton] = []
    private var rows: [Row] = []
    private var state: GitState?
    private var busy = false
    private var pendingAction: (() -> Void)?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init(frame: .zero)
        branchMenu.target = self
        branchMenu.action = #selector(branchChosen)
        branchMenu.controlSize = .small
        branchMenu.font = .systemFont(ofSize: 11)
        let actions: [(String, Selector)] = [("Fetch", #selector(fetch)), ("Pull", #selector(pull)), ("Push", #selector(push)),
                                             ("Stash", #selector(stash)), ("Stash Pop", #selector(stashPop))]
        actionButtons = actions.map { title, action in
            let button = NSButton(title: title, target: self, action: action)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            return button
        }
        let menus = [("Stash 一覧", #selector(stashMenu(_:))), ("タグ", #selector(tagMenu(_:))), ("Rebase", #selector(rebaseMenu(_:)))].map { title, action in
            let button = NSButton(title: title + " ▾", target: self, action: action)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            return button
        }
        actionButtons += menus
        let toolbarRow = NSStackView(views: [branchMenu] + actionButtons)
        toolbarRow.spacing = 6
        toolbarRow.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbarRow.alignment = .centerY
        bannerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        bannerLabel.textColor = .systemOrange
        banner.spacing = 6
        banner.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)
        banner.isHidden = true
        let toolbar = NSStackView(views: [banner, toolbarRow])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 0
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.backgroundColor = .clear
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

        message.isRichText = false
        message.font = .systemFont(ofSize: 12)
        message.drawsBackground = false
        message.textContainerInset = NSSize(width: 4, height: 4)
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.isAutomaticDashSubstitutionEnabled = false
        message.autoresizingMask = [.width]
        let messageScroll = NSScrollView()
        messageScroll.documentView = message
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.borderType = .lineBorder
        messageScroll.drawsBackground = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.controlSize = .small
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "コミットメッセージ")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        body.translatesAutoresizingMaskIntoConstraints = false
        [toolbar, list, title, messageScroll, commitButton].forEach(body.addSubview)
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        addSubview(body)
        addSubview(empty)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: body.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            list.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            list.trailingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor),
            messageScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            messageScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            messageScroll.widthAnchor.constraint(equalToConstant: 300),
            messageScroll.bottomAnchor.constraint(equalTo: commitButton.topAnchor, constant: -6),
            commitButton.trailingAnchor.constraint(equalTo: messageScroll.trailingAnchor),
            commitButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

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
        showBanner(loaded)
        rows = []
        if !loaded.staged.isEmpty {
            rows.append(.header("ステージ済み (\(loaded.staged.count))", staged: true))
            rows += loaded.staged.map { .file($0) }
        }
        if !loaded.unstaged.isEmpty {
            rows.append(.header("変更 (\(loaded.unstaged.count))", staged: false))
            rows += loaded.unstaged.map { .file($0) }
        }
        table.reloadData()
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
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func showBanner(_ state: GitState) {
        banner.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let operation = state.operation else { return banner.isHidden = true }
        let left = state.conflicts.isEmpty ? "" : "（競合 \(state.conflicts.count) 件）"
        bannerLabel.stringValue = (operation == "rebase" ? "rebase の途中です" : "マージの途中です") + left
        var views: [NSView] = [bannerLabel]
        if operation == "rebase" {
            views += [smallButton("続ける", #selector(rebaseContinue)), smallButton("スキップ", #selector(rebaseSkip)), smallButton("中止", #selector(rebaseAbort))]
        } else {
            views += [smallButton("マージを完了", #selector(mergeContinue)), smallButton("マージを中止", #selector(mergeAbort))]
        }
        views.forEach(banner.addArrangedSubview)
        banner.isHidden = false
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

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector, row: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.tag = row
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let leading: [NSView]
        let trailing: [NSView]
        switch rows[row] {
        case .header(let title, let staged):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let all = staged ? iconButton("minus", "すべてステージ解除", #selector(unstageAll), row: row)
                : iconButton("plus", "すべてステージ", #selector(stageAll), row: row)
            leading = [label]
            trailing = [all]
        case .file(let change):
            let letter = NSTextField(labelWithString: change.letter)
            letter.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            letter.textColor = change.color
            let path = NSTextField(labelWithString: change.path)
            path.font = .systemFont(ofSize: 11)
            path.lineBreakMode = .byTruncatingMiddle
            path.toolTip = change.path
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            leading = [letter, path]
            trailing = change.staged ? [iconButton("minus", "ステージ解除", #selector(unstage(_:)), row: row)]
                : [iconButton("arrow.uturn.backward", change.kind == .untracked ? "削除" : "変更を破棄", #selector(discard(_:)), row: row),
                   iconButton("plus", "ステージ", #selector(stage(_:)), row: row)]
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: leading + [spacer] + trailing)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        return stack
    }
}
