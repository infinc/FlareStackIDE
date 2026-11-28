import AppKit

extension EditorWindowController {
    func updateProjectTitle() {
        projectButton.attributedTitle = NSAttributedString(string: project.name + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor])
        window?.title = "\(project.name) — \(appName)"
    }

    func menuItem(_ title: String, _ action: Selector?, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    @objc func projectClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("プロジェクト名を変更…", #selector(renameProject)))
        menu.addItem(menuItem("プロジェクトの設定…", #selector(projectSettingsClicked)))
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

    @objc private func projectSettingsClicked() {
        let project = project
        Popups.show("project-settings-\(project.path)", title: "プロジェクトの設定", over: window) { ProjectSettingsView(project: project) }
    }

    func showHistory(_ url: URL) {
        LocalHistory.show(url, editor: self)
    }

    @objc func historyItem(_ sender: Any?) {
        if let url = (sender as? NSMenuItem)?.representedObject as? URL ?? node(of: sender)?.url { showHistory(url) }
    }

    func restoreHistory(_ data: Data, to url: URL) {
        if let error = saveAll() { return showError(error) }
        if let old = try? Data(contentsOf: url) { LocalHistory.record(url, data: old, merge: false) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return showError(error)
        }
        LocalHistory.record(url, data: data, merge: false)
        reloadExternal([url.standardizedFileURL.path])
        refreshGit()
        Toasts.post("「\(url.lastPathComponent)」を以前の版に戻しました", in: window)
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

    @objc func pathClicked(_ gesture: NSClickGestureRecognizer) {
        guard let url = selectedURL, url.isFileURL else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("パスをコピー", #selector(copyCurrentPath(_:)), url.path))
        menu.addItem(menuItem("相対パスをコピー", #selector(copyCurrentPath(_:)), relativePath(url)))
        menu.addItem(menuItem("Finderで表示", #selector(revealCurrent(_:)), url.path))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fileLabel.bounds.height + 4), in: fileLabel)
    }

    func relativePath(_ url: URL) -> String {
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
