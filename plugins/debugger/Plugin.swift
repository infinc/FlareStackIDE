import AppKit
@testable import FlareStackIDE

final class DebuggerPlugin: NativePlugin {
    static let pluginID = "debugger"
    static let locationChanged = Notification.Name("Debugger.locationChanged")
    static var location: (path: String, line: Int)? {
        didSet { NotificationCenter.default.post(name: locationChanged, object: nil) }
    }

    let id = DebuggerPlugin.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { DebuggerTextAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { DebuggerWindowAddon(editor: editor) }
}

func canonicalPath(_ url: URL) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(url.path, &buffer).map { String(cString: $0) } ?? url.standardizedFileURL.path
}

enum BreakpointStore {
    static let changed = Notification.Name("Debugger.breakpointsChanged")
    private static let key = "Plugin.debugger.breakpoints"

    static var all: [String: Set<Int>] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        return raw.mapValues(Set.init).filter { !$0.value.isEmpty }
    }

    static func lines(_ path: String) -> Set<Int> { all[path] ?? [] }

    static func toggle(_ path: String, line: Int) {
        var current = all
        var lines = current[path] ?? []
        if lines.remove(line) == nil { lines.insert(line) }
        current[path] = lines
        save(current)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["path": path])
    }

    static func clear() {
        save([:])
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func save(_ value: [String: Set<Int>]) {
        UserDefaults.standard.set(value.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }, forKey: key)
    }
}

final class DebuggerTextAddon: NSObject, TextAddon {
    private weak var code: CodeEditing?
    private static let owner = "debugger.line"

    init(code: CodeEditing) {
        self.code = code
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(rulerClicked(_:)), name: PluginEvent.rulerClicked, object: code.textView)
        center.addObserver(self, selector: #selector(publish), name: PluginEvent.breakpointsRequest, object: code.textView)
        center.addObserver(self, selector: #selector(publish), name: BreakpointStore.changed, object: nil)
        center.addObserver(self, selector: #selector(publish), name: DebuggerPlugin.locationChanged, object: nil)
        publish()
    }

    private var path: String? { code?.fileURL.map(canonicalPath) }

    @objc private func rulerClicked(_ note: Notification) {
        guard note.userInfo?["option"] as? Bool == true, note.userInfo?["zone"] as? String == "line",
              let line = note.userInfo?["line"] as? Int, let path else { return }
        BreakpointStore.toggle(path, line: line)
    }

    @objc private func publish() {
        guard let textView = code?.textView else { return }
        let lines = path.map(BreakpointStore.lines) ?? []
        NotificationCenter.default.post(name: PluginEvent.breakpoints, object: textView, userInfo: ["lines": lines])
        let current = DebuggerPlugin.location.flatMap { $0.path == path ? $0.line : nil }
        NotificationCenter.default.post(name: PluginEvent.debugLine, object: textView, userInfo: current.map { ["line": $0] })
        var marks: [(range: NSRange, color: NSColor)] = []
        if let current {
            let text = textView.string as NSString
            let starts = LineIndex.starts(text)
            if current >= 1, current <= starts.count {
                let range = text.lineRange(for: NSRange(location: starts[current - 1], length: 0))
                marks.append((range, NSColor.systemYellow.withAlphaComponent(0.25)))
            }
        }
        CodeView.setBackgrounds(marks, owner: Self.owner, in: textView)
    }

    func fileOpened() { publish() }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let textView = code?.textView {
            CodeView.setBackgrounds([], owner: Self.owner, in: textView)
            NotificationCenter.default.post(name: PluginEvent.breakpoints, object: textView, userInfo: ["lines": Set<Int>()])
            NotificationCenter.default.post(name: PluginEvent.debugLine, object: textView, userInfo: nil)
        }
    }
}

final class DebuggerWindowAddon: NSObject, WindowAddon, CommandProviding {
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private let controls = NSStackView()
    private var startButton: NSButton!
    private var stepButtons: [NSButton] = []
    private var stopButton: NSButton!
    private var feed: FeedView?
    private let view = DebugFeedView()
    private var session: DAPSession?
    private var frames: [DAPFrame] = []

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button = ToolStripButton(symbol: "ladybug", tip: "デバッグ", target: self, action: #selector(toggleFeed))
        editor.addStripButton(button, id: "debugger")
        startButton = Self.control("play.fill", "デバッグを開始（今のファイル）", self, #selector(startClicked))
        stepButtons = [
            Self.control("forward.fill", "続行", self, #selector(continueClicked)),
            Self.control("arrow.uturn.forward", "ステップオーバー", self, #selector(stepOver)),
            Self.control("arrow.down.to.line", "ステップイン", self, #selector(stepIn)),
            Self.control("arrow.up.to.line", "ステップアウト", self, #selector(stepOut)),
        ]
        stopButton = Self.control("stop.fill", "デバッグを停止", self, #selector(stopClicked))
        [startButton!] .forEach(controls.addArrangedSubview)
        stepButtons.forEach(controls.addArrangedSubview)
        controls.addArrangedSubview(stopButton)
        controls.spacing = 2
        controls.toolTip = "デバッグ"
        editor.addTopButton(controls)
        view.onSelectFrame = { [weak self] in self?.select(frame: $0) }
        view.onEvaluate = { [weak self] in self?.evaluate($0) }
        view.onExpand = { [weak self] reference, done in self?.session?.variables(reference, done) }
        updateControls()
    }

    private static func control(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func updateControls() {
        let state = session?.state ?? .ended
        startButton.isHidden = state != .ended
        stepButtons.forEach { $0.isHidden = state == .ended; $0.isEnabled = state == .stopped }
        stopButton.isHidden = state == .ended
        stopButton.contentTintColor = state == .ended ? .secondaryLabelColor : .systemRed
        button.contentTintColor = state == .ended ? nil : .systemOrange
        feed?.title = switch state {
        case .ended: "デバッグ"
        case .starting: "デバッグ: 起動中…"
        case .running: "デバッグ: 実行中"
        case .stopped: "デバッグ: 停止中"
        }
    }

    private func ensureFeed() -> FeedView? {
        guard let editor else { return nil }
        if let feed { return feed }
        let clear = FeedView.barButton(symbol: "trash", tip: "ブレークポイントをすべて削除", target: self, action: #selector(clearBreakpoints))
        let made = FeedView(title: "デバッグ", content: view, extras: [clear])
        made.onRemove = { [weak self, weak made] in if let made { self?.editor?.hideBottom(made) } }
        editor.addFeed(made, button: button)
        feed = made
        return made
    }

    @objc private func toggleFeed() {
        guard let editor, let feed = ensureFeed() else { return }
        editor.toggleBottom(feed)
        updateControls()
    }

    @objc private func clearBreakpoints() {
        let paths = BreakpointStore.all.keys
        BreakpointStore.clear()
        paths.forEach { session?.setBreakpoints($0, []) }
    }

    @objc private func startClicked() {
        guard let editor else { return }
        guard let file = editor.fileURL.map({ URL(fileURLWithPath: canonicalPath($0)) }) else {
            Toasts.post("デバッグするファイルを開いてください", in: editor.window)
            return
        }
        if let error = editor.saveAll() { return editor.showError(error) }
        let root = editor.baseDirectory
        let ext = file.pathExtension.lowercased()
        let adapter: Result<DebugAdapter, Error>
        if DebugAdapter.pythonExtensions.contains(ext) {
            adapter = DebugAdapter.python(file: file, root: root)
        } else if DebugAdapter.nativeExtensions.contains(ext) {
            guard let program = chooseProgram(root: root) else { return }
            adapter = DebugAdapter.lldb(program: program, root: root)
        } else {
            Toasts.post("このファイルはデバッグできません", message: "Python（debugpy）と、ビルドした実行ファイル（lldb-dap）に対応しています",
                        in: editor.window)
            return
        }
        switch adapter {
        case .failure(let error):
            Toasts.post("デバッグを開始できません", message: error.localizedDescription, in: editor.window)
        case .success(let adapter):
            start(adapter, root: root)
        }
    }

    private func programKey(_ root: URL) -> String { "Plugin.debugger.program.\(root.standardizedFileURL.path)" }

    private func chooseProgram(root: URL) -> URL? {
        let saved = UserDefaults.standard.string(forKey: programKey(root)).map { URL(fileURLWithPath: $0) }
        let panel = NSOpenPanel()
        panel.title = "デバッグする実行ファイルを選択"
        panel.message = "ビルド済みの実行ファイル（デバッグ情報付き。swiftc -g / clang -g など）を選んでください"
        panel.prompt = "デバッグ"
        panel.canChooseDirectories = false
        panel.directoryURL = saved?.deletingLastPathComponent() ?? root
        if let saved { panel.nameFieldStringValue = saved.lastPathComponent }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: programKey(root))
        return url
    }

    private func start(_ adapter: DebugAdapter, root: URL) {
        session?.stop()
        view.reset()
        let next = DAPSession(adapter: adapter) { BreakpointStore.all }
        next.onState = { [weak self, weak next] state in
            guard let self, let next, self.session === next else { return }
            if state != .stopped { DebuggerPlugin.location = nil }
            if state == .running || state == .ended { self.view.showFrames([]) }
            if state == .ended {
                self.view.append(L("\(adapter.name) を終了しました") + "\n", category: "console")
                self.session = nil
            }
            self.updateControls()
        }
        next.onStopped = { [weak self] _, reason in self?.stopped(reason) }
        next.onOutput = { [weak self] category, text in self?.view.append(text, category: category) }
        session = next
        NotificationCenter.default.addObserver(self, selector: #selector(breakpointsChanged(_:)), name: BreakpointStore.changed, object: nil)
        if let feed = ensureFeed(), feed.isHidden { editor?.showBottom(feed) }
        view.append(L("\(adapter.name) で \(adapter.launch["name"] as? String ?? "") を起動します") + "\n", category: "console")
        guard next.start(directory: root) else {
            session = nil
            Toasts.post("デバッガを起動できませんでした", message: adapter.command.joined(separator: " "), in: editor?.window)
            return updateControls()
        }
        updateControls()
    }

    @objc private func breakpointsChanged(_ note: Notification) {
        guard let path = note.userInfo?["path"] as? String else { return }
        session?.setBreakpoints(path, BreakpointStore.lines(path))
    }

    private func stopped(_ reason: String) {
        session?.stackTrace { [weak self] frames in
            guard let self else { return }
            self.frames = frames
            self.view.showFrames(frames)
            if let index = frames.firstIndex(where: { $0.path != nil }) { self.select(frame: index) }
        }
    }

    private func select(frame index: Int) {
        guard frames.indices.contains(index) else { return }
        let frame = frames[index]
        view.selectFrame(index)
        if let path = frame.path, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let canonical = canonicalPath(url)
            editor?.openLocation(editorURL(for: url, canonical: canonical), line: frame.line, column: frame.column > 0 ? frame.column : nil)
            DebuggerPlugin.location = (canonical, frame.line)
        }
        session?.scopes(frame.id) { [weak self] scopes in self?.view.showVariables(scopes) }
    }

    private func editorURL(for url: URL, canonical: String) -> URL {
        guard let editor else { return url }
        if let open = editor.openURLs.first(where: { canonicalPath($0) == canonical }) { return open }
        let base = editor.baseDirectory
        let root = canonicalPath(base)
        guard canonical.hasPrefix(root + "/") else { return url.standardizedFileURL }
        return base.appendingPathComponent(String(canonical.dropFirst(root.count + 1)))
    }

    private func evaluate(_ expression: String) {
        guard let session else { return view.append(L("デバッグ中ではありません") + "\n", category: "stderr") }
        view.append("› \(expression)\n", category: "input")
        let frame = view.selectedFrame.flatMap { frames.indices.contains($0) ? frames[$0].id : nil }
        session.evaluate(expression, frame: frame) { [weak self] result in self?.view.append(result + "\n", category: "result") }
    }

    @objc private func continueClicked() { session?.step("continue") }
    @objc private func stepOver() { session?.step("next") }
    @objc private func stepIn() { session?.step("stepIn") }
    @objc private func stepOut() { session?.step("stepOut") }
    @objc private func stopClicked() { session?.stop() }

    var commands: [PaletteCommand] {
        var list = [PaletteCommand(id: "debugger.start", title: "デバッグ: 今のファイルをデバッグ") { [weak self] in self?.startClicked() }]
        if session != nil {
            list += [
                PaletteCommand(id: "debugger.continue", title: "デバッグ: 続行") { [weak self] in self?.continueClicked() },
                PaletteCommand(id: "debugger.next", title: "デバッグ: ステップオーバー") { [weak self] in self?.stepOver() },
                PaletteCommand(id: "debugger.in", title: "デバッグ: ステップイン") { [weak self] in self?.stepIn() },
                PaletteCommand(id: "debugger.out", title: "デバッグ: ステップアウト") { [weak self] in self?.stepOut() },
                PaletteCommand(id: "debugger.stop", title: "デバッグ: 停止") { [weak self] in self?.stopClicked() },
            ]
        }
        list.append(PaletteCommand(id: "debugger.clear", title: "デバッグ: ブレークポイントをすべて削除") { [weak self] in self?.clearBreakpoints() })
        return list
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        session?.stop()
        session = nil
        DebuggerPlugin.location = nil
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
        controls.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(DebuggerPlugin()) }
