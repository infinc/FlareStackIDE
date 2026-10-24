import AppKit
@testable import FlareStackIDE

final class RunnerPlugin: NativePlugin {
    let id = RunnerStore.pluginID
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { RunnerAddon(editor: editor) }
}

final class RunnerAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private let runner: RunnerStore
    private var button: RunButton!
    private var feed: FeedView?
    private let container = NSView()
    private var pane: TerminalPane?
    private var config: RunConfig?

    init(editor: EditorWindowController) {
        self.editor = editor
        runner = RunnerStore(project: editor.project, base: editor.baseDirectory)
        super.init()
        button = RunButton(target: self, action: #selector(runClicked))
        button.onMenu = { [weak self] in self?.showMenu($0) }
        editor.addStripButton(button, id: "run")
        updateTip()
    }

    private func item(_ title: String, _ action: Selector?, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func updateTip() {
        button.play.toolTip = runner.selected.map { "実行: \($0.name)" } ?? "実行（起動構成を作成）"
    }

    @objc private func runClicked() {
        if let config = runner.selected { return run(config) }
        newConfig()
    }

    private func showMenu(_ anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if runner.configs.isEmpty {
            let none = item("起動構成なし", nil)
            none.isEnabled = false
            menu.addItem(none)
        }
        for config in runner.configs {
            let entry = item(config.name, #selector(selectConfig(_:)), config.id)
            entry.state = config.id == runner.selectedID ? .on : .off
            entry.toolTip = runner.command(for: config)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("新しい起動構成…", #selector(newConfig)))
        if let selected = runner.selected {
            menu.addItem(item("「\(selected.name)」を編集…", #selector(editConfig)))
            menu.addItem(item("「\(selected.name)」を削除", #selector(deleteConfig)))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX, y: anchor.bounds.maxY), in: anchor)
    }

    @objc private func selectConfig(_ sender: NSMenuItem) {
        runner.selectedID = sender.representedObject as? String
        updateTip()
    }

    @objc private func newConfig() {
        guard let editor else { return }
        let initial = editor.fileURL.map { RunConfig(name: $0.lastPathComponent, directory: "", script: editor.relativePath($0)) }
        guard let config = RunnerStore.edit(initial, base: editor.baseDirectory, title: "新しい起動構成") else { return }
        var created = config
        created.id = UUID().uuidString
        runner.upsert(created)
        updateTip()
    }

    @objc private func editConfig() {
        guard let editor, let selected = runner.selected,
              let config = RunnerStore.edit(selected, base: editor.baseDirectory, title: "起動構成を編集") else { return }
        runner.upsert(config)
        updateTip()
    }

    @objc private func deleteConfig() {
        guard let selected = runner.selected else { return }
        runner.remove(selected.id)
        updateTip()
    }

    private func run(_ config: RunConfig) {
        guard let editor else { return }
        if let error = editor.saveAll() { return editor.showError(error) }
        let feed = self.feed ?? {
            let stop = FeedView.barButton(symbol: "stop.fill", tip: "停止", target: self, action: #selector(stopRun))
            let again = FeedView.barButton(symbol: "arrow.clockwise", tip: "再実行", target: self, action: #selector(rerun))
            let made = FeedView(title: "実行", content: container, extras: [stop, again])
            made.onRemove = { [weak self, weak made] in
                guard let made else { return }
                self?.editor?.hideBottom(made)
            }
            editor.addFeed(made, button: button.play)
            self.feed = made
            return made
        }()
        pane?.stop()
        pane?.removeFromSuperview()
        let next = TerminalPane(cwd: runner.directory(of: config).path, command: runner.command(for: config))
        next.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: container.topAnchor),
            next.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        pane = next
        self.config = config
        feed.title = "実行: \(config.name)"
        if feed.isHidden { editor.showBottom(feed) }
        DispatchQueue.main.async { next.focus() }
    }

    @objc private func stopRun() {
        guard let pane, pane.running else { return }
        pane.stop()
        pane.show("\r\n\u{1B}[2m[停止しました]\u{1B}[0m\r\n")
    }

    @objc private func rerun() {
        if let config = config.flatMap({ c in runner.configs.first { $0.id == c.id } }) ?? runner.selected { run(config) }
    }

    func detach() {
        pane?.stop()
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(RunnerPlugin()) }
