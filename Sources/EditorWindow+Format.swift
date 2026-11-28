import AppKit

extension EditorWindowController {
    @objc func formatClicked() {
        guard let current else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let reopen = NSMenuItem(title: "文字コードを指定して開き直す", action: nil, keyEquivalent: "")
        let convert = NSMenuItem(title: "文字コードを変えて保存", action: nil, keyEquivalent: "")
        let reopenMenu = NSMenu(), convertMenu = NSMenu()
        for encoding in TextEncoding.all {
            let again = menuItem(encoding.title, #selector(reopenEncoding(_:)), encoding.id)
            again.state = current.editable && current.format.encoding == encoding ? .on : .off
            reopenMenu.addItem(again)
            let save = menuItem(encoding.title, #selector(convertEncoding(_:)), encoding.id)
            save.state = again.state
            convertMenu.addItem(save)
        }
        reopen.submenu = reopenMenu
        convert.submenu = convertMenu
        convert.isEnabled = current.editable
        menu.addItem(reopen)
        menu.addItem(convert)
        menu.addItem(.separator())
        let header = menuItem("改行コード", nil)
        header.isEnabled = false
        menu.addItem(header)
        for ending in LineEnding.allCases {
            let item = menuItem(ending.title, #selector(lineEndingClicked(_:)), ending.rawValue)
            item.state = current.editable && current.format.lineEnding == ending ? .on : .off
            item.isEnabled = current.editable
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: formatButton.bounds.height + 4), in: formatButton)
    }

    @objc private func reopenEncoding(_ sender: NSMenuItem) {
        guard let current, let encoding = TextEncoding.all.first(where: { $0.id == sender.representedObject as? String }) else { return }
        storeCurrent()
        if current.dirty {
            let alert = NSAlert()
            alert.messageText = "未保存の変更を破棄して開き直しますか？"
            alert.informativeText = "「\(current.url.lastPathComponent)」を \(encoding.title) として読み込み直します。"
            alert.addButton(withTitle: "開き直す")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try current.reopen(as: encoding) } catch { return showError(error) }
        textView.string = current.text
        open(current.url)
    }

    private func changeFormat(_ change: (inout TextFormat) -> Void) {
        guard let current, current.editable else { return }
        storeCurrent()
        let old = current.format
        change(&current.format)
        do {
            try current.save()
        } catch {
            current.format = old
            showError(error)
        }
        updateTitle()
        refreshGit()
    }

    @objc private func convertEncoding(_ sender: NSMenuItem) {
        guard let encoding = TextEncoding.all.first(where: { $0.id == sender.representedObject as? String }) else { return }
        changeFormat { $0.encoding = encoding }
    }

    @objc private func lineEndingClicked(_ sender: NSMenuItem) {
        guard let ending = (sender.representedObject as? String).flatMap(LineEnding.init) else { return }
        changeFormat { $0.lineEnding = ending }
    }

    func tabMenu(_ url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("右に開く", #selector(openRightTab(_:)), url))
        if LocalHistory.isTracked(url) { menu.addItem(menuItem("ローカル履歴…", #selector(historyItem(_:)), url)) }
        if let tab = tabs[url], let pin = tab.onPin {
            menu.addItem(.separator())
            menu.addItem(TabItemView.pinItem(tab.pinned, pin))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("閉じる", #selector(closeTabItem(_:)), url))
        return menu
    }

    @objc private func openRightTab(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openRight(url) }
    }

    @objc private func closeTabItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { closeTab(url) }
    }

    var splitURLs: [URL] { splitPane?.urls ?? [] }

    var splitTextView: NSTextView? { splitPane?.textView }

    var splitFileURL: URL? { splitPane?.fileURL }

    func openRight(_ url: URL) {
        let pane = splitPane ?? makeSplitPane()
        if pane.contains(url) { return pane.select(url) }
        let buffer: Buffer
        if let existing = buffers[url] {
            if selectedURL == url { storeCurrent() }
            buffer = existing
            detachTab(url)
        } else {
            buffer = Buffer(url: url)
        }
        pane.open(buffer)
        updateCloud()
    }

    private func makeSplitPane() -> SplitPane {
        let pane = SplitPane()
        pane.onChange = { [weak self] in self?.updateCloud() }
        pane.onEmpty = { [weak self] in self?.closeSplit() }
        pane.baseDirectory = { [weak self] in self?.projectDirectory }
        pane.tabColor = { [weak self] in self?.gitState($0)?.color }
        pane.onMoveLeft = { [weak self] url in
            guard let self, let buffer = self.splitPane?.take(url) else { return }
            self.storeCurrent()
            self.buffers[url] = buffer
            self.open(url)
        }
        splitPane = pane
        editorSplit.addArrangedSubview(pane)
        editorSplit.layoutSubtreeIfNeeded()
        editorSplit.setPosition(editorSplit.bounds.width / 2, ofDividerAt: 0)
        return pane
    }

    private func closeSplit() {
        guard let pane = splitPane else { return }
        splitPane = nil
        pane.detachAddons()
        pane.removeFromSuperview()
        editorSplit.adjustSubviews()
        updateCloud()
        window?.makeFirstResponder(textView)
    }

    private func detachTab(_ url: URL) {
        guard let tab = tabs[url] else { return }
        let index = fileTabs.stack.arrangedSubviews.filter { $0 is TabItemView }.firstIndex(of: tab) ?? 0
        tab.removeFromSuperview()
        tabs[url] = nil
        buffers[url] = nil
        windowAddons.each { $0.bufferClosed(url) }
        guard selectedURL == url else { return }
        current = nil
        let remaining = fileTabs.stack.arrangedSubviews.filter { $0 is TabItemView }
        if !remaining.isEmpty, let next = tabs.first(where: { $0.value === remaining[min(index, remaining.count - 1)] })?.key {
            return open(next)
        }
        showEmpty()
    }

    @objc func closeAllTabs() { closeTabs(keeping: []) }

    func closeTabs(keeping kept: Set<URL>) {
        storeCurrent()
        let closing = tabs.keys.filter { !kept.contains($0) }
        for url in closing {
            guard let buffer = buffers[url], buffer.dirty, buffer.editable else { continue }
            do {
                try buffer.save()
            } catch {
                return showError(error)
            }
        }
        for url in closing {
            tabs[url]?.removeFromSuperview()
            tabs[url] = nil
            buffers[url] = nil
            windowAddons.each { $0.bufferClosed(url) }
        }
        updateCloud()
        guard let selectedURL, closing.contains(selectedURL) else { return }
        current = nil
        if let next = openURLs.first { return open(next) }
        showEmpty()
    }
}
