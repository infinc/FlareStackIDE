import AppKit
@testable import FlareStackIDE

final class RemoteSSHPlugin: NativePlugin {
    let id = RemoteSSH.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { RemoteSSHAddon(editor: editor) }
}

final class RemoteSSHAddon: NSObject, WindowAddon, CommandProviding {
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var watcher: FileWatcher?
    private var pending: Set<String> = []
    private var pushWork: DispatchWorkItem?
    private var quietUntil = Date.distantPast
    private var busy = false
    private var feed: FeedView?
    private let container = NSView()
    private var pane: TerminalPane?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "network", tip: "リモート (SSH)", target: self, action: #selector(buttonClicked))
        editor.addStripButton(button, id: "remote-ssh")
        if let target {
            button.contentTintColor = .controlAccentColor
            button.toolTip = "リモート: \(target.label)"
            startWatching()
        }
    }

    private var local: URL? { editor?.baseDirectory.standardizedFileURL }
    private var target: RemoteTarget? { local.flatMap(RemoteSSH.target) }

    @objc private func buttonClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if let target {
            let header = NSMenuItem(title: target.label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            add("リモートから取得", #selector(pullClicked), enabled: !busy)
            add("リモートのターミナルを開く", #selector(terminalClicked))
            add("リモートとの同期をやめる", #selector(disconnectClicked))
            menu.addItem(.separator())
        }
        add("SSH で接続…", #selector(connectClicked))
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX, y: button.bounds.maxY), in: button)
    }

    @objc private func connectClicked() {
        guard let window = editor?.window else { return }
        let alert = NSAlert()
        alert.messageText = "SSH で接続"
        alert.informativeText = "リモートのフォルダを手元に取得してプロジェクトとして開きます。保存すると変更したファイルを送り返します。鍵（ssh-agent）で接続できるホストだけに対応しています。"
        let host = NSComboBox()
        host.addItems(withObjectValues: RemoteSSH.configuredHosts + RemoteSSH.recent.map(\.host))
        host.placeholderString = "ホスト（~/.ssh/config の Host か user@host）"
        host.stringValue = RemoteSSH.recent.first?.host ?? RemoteSSH.configuredHosts.first ?? ""
        let path = NSTextField(string: RemoteSSH.recent.first?.path ?? "")
        path.placeholderString = "リモートのフォルダ（例: /home/user/project）"
        let stack = NSStackView(views: [host, path])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 58)
        [host, path].forEach { $0.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "接続")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = host
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let target = RemoteTarget(host: host.stringValue.trimmingCharacters(in: .whitespaces),
                                      path: path.stringValue.trimmingCharacters(in: .whitespaces))
            guard !target.host.isEmpty, target.path.hasPrefix("/") || target.path.hasPrefix("~") else {
                Toasts.post("ホストと、/ か ~ で始まるフォルダを入力してください", in: window)
                return
            }
            self?.connect(target)
        }
    }

    private func connect(_ target: RemoteTarget) {
        let window = editor?.window
        let toast = Toasts.post("\(target.label) に接続しています…", in: window)
        DispatchQueue.global(qos: .userInitiated).async {
            let local = RemoteSSH.mirror(for: target)
            let failure = RemoteSSH.check(target) ?? RemoteSSH.pull(target, into: local)
            DispatchQueue.main.async {
                toast?.dismiss()
                if let failure {
                    Toasts.post("\(target.label) に接続できませんでした", message: failure, in: window)
                    return
                }
                var mirrors = RemoteSSH.mirrors
                mirrors[local.standardizedFileURL.path] = target
                RemoteSSH.mirrors = mirrors
                RemoteSSH.recent = [target] + RemoteSSH.recent.filter { $0 != target }
                let project = Project(name: "\(target.host): \((target.path as NSString).lastPathComponent)", path: local.path)
                (NSApp.delegate as? AppDelegate)?.welcomeOpen(project)
            }
        }
    }

    private func startWatching() {
        guard let local, watcher == nil else { return }
        quietUntil = Date().addingTimeInterval(2)
        watcher = FileWatcher(path: local.path) { [weak self] changes in self?.changed(changes) }
    }

    private func changed(_ changes: FileChanges) {
        guard let local, Date() > quietUntil else { return }
        let prefix = local.path + "/"
        let paths = changes.modified.union(changes.structural).filter { $0.hasPrefix(prefix) }
        let relative = paths.map { String($0.dropFirst(prefix.count)) }.filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != ".env" } && !path.contains(".sb-")
        }
        let files = relative.filter { name in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: prefix + name, isDirectory: &directory) && !directory.boolValue
        }
        guard !files.isEmpty else { return }
        pending.formUnion(files)
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func push() {
        guard let target, let local, !pending.isEmpty else { return }
        let files = Array(pending).sorted()
        pending = []
        let window = editor?.window
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure = RemoteSSH.push(files, of: target, from: local)
            DispatchQueue.main.async {
                if let failure {
                    Toasts.post("\(target.host) に送れませんでした", message: failure,
                                actions: [("もう一度送る", {
                                    self?.pending.formUnion(files)
                                    self?.push()
                                })], in: window)
                }
            }
        }
    }

    @objc private func pullClicked() {
        guard let target, let local, !busy else { return }
        if let error = editor?.saveAll() { return editor?.showError(error) ?? () }
        busy = true
        let window = editor?.window
        let toast = Toasts.post("\(target.label) から取得しています…", in: window)
        quietUntil = .distantFuture
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = RemoteSSH.pull(target, into: local)
            DispatchQueue.main.async {
                guard let self else { return }
                toast?.dismiss()
                self.busy = false
                self.quietUntil = Date().addingTimeInterval(2)
                if let failure {
                    Toasts.post("取得できませんでした", message: failure, in: window)
                } else {
                    self.editor?.reloadTree()
                    Toasts.post("\(target.label) から取得しました", in: window)
                }
            }
        }
    }

    @objc private func terminalClicked() {
        guard let editor, let target, let local else { return }
        let feed = self.feed ?? {
            let made = FeedView(title: "リモート: \(target.host)", content: container)
            made.onRemove = { [weak self, weak made] in if let made { self?.editor?.hideBottom(made) } }
            editor.addFeed(made, button: button)
            self.feed = made
            return made
        }()
        if pane?.running != true {
            pane?.removeFromSuperview()
            let next = TerminalPane(cwd: local.path, command: RemoteSSH.terminalCommand(target))
            next.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(next)
            NSLayoutConstraint.activate([
                next.topAnchor.constraint(equalTo: container.topAnchor),
                next.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                next.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                next.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            pane = next
        }
        if feed.isHidden { editor.showBottom(feed) }
        DispatchQueue.main.async { [weak self] in self?.pane?.focus() }
    }

    @objc private func disconnectClicked() {
        guard let local, let target else { return }
        var mirrors = RemoteSSH.mirrors
        mirrors[local.path] = nil
        RemoteSSH.mirrors = mirrors
        watcher?.stop()
        watcher = nil
        button.contentTintColor = nil
        button.toolTip = "リモート (SSH)"
        Toasts.post("\(target.label) との同期をやめました", message: "手元のコピーは \(local.path) に残っています", in: editor?.window)
    }

    var commands: [PaletteCommand] {
        var list = [PaletteCommand(id: "remote.connect", title: "リモート: SSH で接続…") { [weak self] in self?.connectClicked() }]
        if target != nil {
            list += [
                PaletteCommand(id: "remote.pull", title: "リモート: リモートから取得") { [weak self] in self?.pullClicked() },
                PaletteCommand(id: "remote.terminal", title: "リモート: ターミナルを開く") { [weak self] in self?.terminalClicked() },
            ]
        }
        return list
    }

    func detach() {
        pushWork?.cancel()
        push()
        watcher?.stop()
        watcher = nil
        pane?.stop()
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(RemoteSSHPlugin()) }
