import AppKit
@testable import FlareStackIDE

final class SessionRestorePlugin: NativePlugin {
    let id = "session-restore"
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? {
        editor.projectDirectory == nil ? nil : SessionRestoreAddon(editor: editor)
    }
}

struct SessionState: Codable {
    var left: [String] = []
    var leftSelected: String?
    var right: [String] = []
    var rightSelected: String?
    var cursors: [String: [Int]] = [:]
}

final class SessionRestoreAddon: NSObject, WindowAddon {
    private weak var editor: EditorWindowController?
    private let key: String
    private var cursors: [String: [Int]] = [:]
    private var restoring = false
    private var restored = false
    private var work: DispatchWorkItem?
    private weak var watchedRight: NSTextView?

    init(editor: EditorWindowController) {
        self.editor = editor
        key = "Plugin.session-restore.\(editor.baseDirectory.standardizedFileURL.path)"
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: editor.textView)
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView)
        center.addObserver(self, selector: #selector(terminating), name: NSApplication.willTerminateNotification, object: nil)
        editor.scrollView.contentView.postsBoundsChangedNotifications = true
        DispatchQueue.main.async { [weak self] in self?.restore() }
    }

    private func relative(_ url: URL) -> String? {
        guard let base = editor?.baseDirectory.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    private func absolute(_ path: String) -> URL? {
        guard let base = editor?.baseDirectory, !path.contains("..") else { return nil }
        let url = base.appendingPathComponent(path)
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue ? url : nil
    }

    private func load() -> SessionState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    private func record(_ textView: NSTextView?, url: URL?) {
        guard !restoring, let textView, let url, let path = relative(url) else { return }
        let range = textView.selectedRange()
        let offset = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        cursors[path] = [range.location, range.length, Int(offset)]
    }

    private func snapshot() -> SessionState? {
        guard let editor else { return nil }
        record(editor.textView, url: editor.fileURL)
        record(editor.splitTextView, url: editor.splitFileURL)
        var state = SessionState()
        state.left = editor.openURLs.compactMap(relative)
        state.leftSelected = editor.fileURL.flatMap(relative)
        state.right = editor.splitURLs.compactMap(relative)
        state.rightSelected = editor.splitFileURL.flatMap(relative)
        let open = Set(state.left + state.right)
        state.cursors = cursors.filter { open.contains($0.key) }
        return state
    }

    private func save() {
        work?.cancel()
        work = nil
        guard restored, !restoring, let state = snapshot(), let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func scheduleSave() {
        guard restored, !restoring else { return }
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func apply(_ textView: NSTextView?, path: String?, state: SessionState) {
        guard let textView, let path, let saved = state.cursors[path], saved.count >= 2 else { return }
        let length = (textView.string as NSString).length
        let location = min(max(saved[0], 0), length)
        let range = NSRange(location: location, length: min(max(saved[1], 0), length - location))
        textView.setSelectedRange(range)
        guard let scroll = textView.enclosingScrollView else { return }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if saved.count >= 3 {
            let maxY = max(textView.frame.height - scroll.contentView.bounds.height, 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(saved[2]), maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            textView.scrollRangeToVisible(range)
        }
    }

    private func restore() {
        defer {
            restored = true
            watchRight()
        }
        guard let editor, let state = load(), editor.openURLs.isEmpty else { return }
        restoring = true
        defer { restoring = false }
        cursors = state.cursors
        let left = state.left.compactMap { path in absolute(path).map { (path, $0) } }
        let right = state.right.compactMap { path in absolute(path).map { (path, $0) } }
        for (_, url) in left { editor.open(url) }
        for (_, url) in right { editor.openRight(url) }
        if let path = state.rightSelected, let url = absolute(path), editor.splitURLs.contains(url) {
            editor.openRight(url)
            apply(editor.splitTextView, path: path, state: state)
        }
        if let path = state.leftSelected ?? left.last?.0, let url = absolute(path), editor.openURLs.contains(url) {
            editor.open(url)
            apply(editor.textView, path: path, state: state)
        }
    }

    private func watchRight() {
        guard let textView = editor?.splitTextView, textView !== watchedRight else { return }
        if let old = watchedRight {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: old)
        }
        watchedRight = textView
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard let editor, let textView = note.object as? NSTextView else { return }
        record(textView, url: textView === editor.textView ? editor.fileURL : editor.splitFileURL)
        scheduleSave()
    }

    @objc private func scrolled() {
        guard let editor else { return }
        record(editor.textView, url: editor.fileURL)
        scheduleSave()
    }

    @objc private func terminating() { save() }

    func fileOpened() {
        watchRight()
        scheduleSave()
    }

    func textChanged() { scheduleSave() }

    func bufferClosed(_ url: URL) {
        watchRight()
        scheduleSave()
    }

    func detach() {
        save()
        NotificationCenter.default.removeObserver(self)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(SessionRestorePlugin()) }
