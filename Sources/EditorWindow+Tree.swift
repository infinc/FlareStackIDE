import AppKit

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
            add("新規フォルダ…", #selector(newFolderItem(_:)))
        } else {
            add("右に開く", #selector(openRightItem(_:)))
            menu.addItem(.separator())
            add("ファイル名を変更…", #selector(renameItem(_:)), enabled: !isRoot)
            add("ファイルをコピー…", #selector(copyFileItem(_:)))
            if LocalHistory.isTracked(node.url) { add("ローカル履歴…", #selector(historyItem(_:))) }
        }
        add("パスをコピー", #selector(copyPathItem(_:)))
        menu.addItem(.separator())
        add("削除", #selector(deleteItem(_:)), enabled: !isRoot)
    }

    func node(of sender: Any?) -> FileNode? {
        (sender as? NSMenuItem)?.representedObject as? FileNode
    }

    func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func showMessage(_ text: String) {
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

    func treeDiffers(_ paths: Set<String>) -> Bool {
        guard !paths.isEmpty else { return false }
        let base = realpath(root.url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? root.url.standardizedFileURL.path
        var info = stat()
        let exists = { (path: String) in lstat(path, &info) == 0 }
        guard root.isDirectory else {
            return (paths.contains(base) || paths.contains(root.url.standardizedFileURL.path)) && !exists(base)
        }
        for path in paths {
            guard path.hasPrefix(base + "/") else { return true }
            let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
            guard let name = parts.last else { return true }
            if FileNode.hiddenNames.contains(name) { continue }
            var parent: FileNode? = root
            for part in parts.dropLast() { parent = parent?.loadedChild(part) }
            guard let parent, parent.isLoaded else { continue }
            if (parent.loadedChild(name) != nil) != exists(path) { return true }
        }
        return false
    }

    func reloadTree() {
        textAddons.each { $0.treeChanged() }
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
        splitPane?.remap(map)
        let reopened = order.compactMap(map)
        reopened.forEach { open($0) }
        if let selected, let target = map(selected) {
            open(target)
        } else if reopened.isEmpty {
            showEmpty()
        }
    }

    @objc private func openRightItem(_ sender: Any?) {
        guard let node = node(of: sender), !node.isDirectory else { return }
        openRight(node.url)
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

    @objc private func newFolderItem(_ sender: Any?) {
        guard let node = node(of: sender), node.isDirectory,
              let answer = askName(title: "新規フォルダ", initial: "", button: "作成"),
              let url = destination(answer.name, in: node.url) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            showError(error)
            return
        }
        reloadTree()
        outline.expandItem(node)
        refreshGit()
    }

    func moveNode(_ node: FileNode, into folder: FileNode) {
        let old = node.url
        let name = old.lastPathComponent
        guard let new = destination(name, in: folder.url) else { return }
        let alert = NSAlert()
        alert.messageText = "「\(name)」を「\(folder.url.lastPathComponent)」へ移動します"
        alert.informativeText = "参照している import やパスも新しい場所に合わせて更新（リファクタリング）しますか？"
        alert.addButton(withTitle: "リファクタリングして移動")
        alert.addButton(withTitle: "移動のみ")
        alert.addButton(withTitle: "キャンセル")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        if let error = saveAll() { showError(error); return }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            showError(error)
            return
        }
        let changed = response == .alertFirstButtonReturn
            ? Refactor.move(in: baseDirectory, from: old, to: new, isDirectory: node.isDirectory) : 0
        reopenTabs { Self.moved($0, from: old, to: new) }
        reloadTree()
        outline.expandItem(folder)
        refreshGit()
        if changed > 0 { showMessage("\(changed) 件のファイルで参照を更新しました。") }
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
        let original = node.url
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        } catch {
            showError(error)
            return
        }
        let gone = original.standardizedFileURL.path
        let inside = { (url: URL) -> Bool in
            let path = url.standardizedFileURL.path
            return path == gone || path.hasPrefix(gone + "/")
        }
        let closed = openURLs.filter(inside)
        reopenTabs { inside($0) ? nil : $0 }
        reloadTree()
        refreshGit()
        guard let trashed = trashed as URL? else { return }
        Toasts.post("「\(original.lastPathComponent)」をゴミ箱に移動しました", actions: [("元に戻す", { [weak self] in
            self?.restoreFromTrash(trashed, to: original, reopening: closed)
        })], in: window)
    }

    private func restoreFromTrash(_ trashed: URL, to original: URL, reopening urls: [URL]) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: original.path) else {
            return showMessage("「\(original.lastPathComponent)」は既に存在するため戻せません。")
        }
        do {
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: trashed, to: original)
        } catch {
            return showError(error)
        }
        reloadTree()
        refreshGit()
        urls.filter { fm.fileExists(atPath: $0.path) }.forEach { open($0) }
        Toasts.post("「\(original.lastPathComponent)」を元に戻しました", in: window)
    }
}
