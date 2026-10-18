import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, WelcomeDelegate {
    private var splash: NSWindow?
    private var mainWindow: NSWindow?
    private let welcome = WelcomeViewController()
    private var editors: [EditorWindowController] = []
    private var settingsWindow: NSWindow?
    private var cloneSheet: CloneWindowController?
    private var updateButton: NSButton?
    private var latestRelease: Release?
    private lazy var updater = Updater(currentVersion: currentVersion)

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showSplash()
        updater.checkLatest { [weak self] release in
            self?.latestRelease = release
            self?.updateButton?.isHidden = release == nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.splash?.orderOut(nil)
            self?.splash = nil
            self?.showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.forEach { $0.saveAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showSplash() {
        guard let url = Bundle.main.url(forResource: "interpolate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let size = NSSize(width: pixels.width / 2, height: pixels.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        splash = window
    }

    private func showMainWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(appName) v\(currentVersion)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        welcome.delegate = self
        window.contentViewController = welcome
        window.setContentSize(NSSize(width: 900, height: 600))
        window.addTitlebarAccessoryViewController(makeToolbarAccessory())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    @objc func openDocument(_ sender: Any?) {
        welcomeOpenFile()
    }

    func welcomeOpenFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "編集するファイルまたはフォルダを選択してください"
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        openEditor(askSaveProject(Project(name: url.lastPathComponent, path: url.path)))
    }

    private func askSaveProject(_ project: Project) -> Project {
        if let saved = ProjectStore.all.first(where: { $0.path == project.path }) { return saved }
        switch Settings.projectAddMode {
        case .never:
            return project
        case .always:
            ProjectStore.touch(project)
            welcome.reload()
            return project
        case .ask:
            break
        }
        let alert = NSAlert()
        alert.messageText = "プロジェクトとして保存しますか？"
        alert.informativeText = "保存すると、次回から初期画面の左側から開けます。\n\(project.path)"
        alert.addButton(withTitle: "保存する")
        alert.addButton(withTitle: "保存しない")
        if alert.runModal() == .alertFirstButtonReturn {
            ProjectStore.touch(ProjectStore.all.first { $0.path == project.path } ?? project)
            welcome.reload()
        }
        return ProjectStore.all.first { $0.path == project.path } ?? project
    }

    func welcomeClone() {
        guard let window = mainWindow, cloneSheet == nil else { return }
        let sheet = CloneWindowController()
        sheet.onClone = { [weak self] request in self?.startClone(request) }
        cloneSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.cloneSheet = nil }
    }

    private func startClone(_ request: CloneRequest) {
        do {
            try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        openEditor(askSaveProject(Project(name: request.name, path: request.destination.path))).clone(request)
    }

    func welcomeOpen(_ project: Project) {
        guard FileManager.default.fileExists(atPath: project.path) else {
            let alert = NSAlert()
            alert.messageText = "「\(project.name)」が見つかりません"
            alert.informativeText = "\(project.path)\n一覧から削除しますか？"
            alert.addButton(withTitle: "削除")
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn {
                ProjectStore.remove(project)
                welcome.reload()
            }
            return
        }
        ProjectStore.touch(project)
        welcome.reload()
        openEditor(project)
    }

    @discardableResult
    private func openEditor(_ project: Project) -> EditorWindowController {
        if let existing = editors.first(where: { $0.project.path == project.path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            mainWindow?.orderOut(nil)
            return existing
        }
        let editor = EditorWindowController(project: project)
        editor.onClose = { [weak self, weak editor] in
            guard let self else { return }
            self.editors.removeAll { $0 === editor }
            if self.editors.isEmpty {
                self.welcome.reload()
                self.mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
        editor.onBack = { [weak self] in
            self?.welcome.reload()
            self?.mainWindow?.makeKeyAndOrderFront(nil)
        }
        editors.append(editor)
        editor.showWindow(nil)
        mainWindow?.orderOut(nil)
        return editor
    }

    private func makeToolbarAccessory() -> NSTitlebarAccessoryViewController {
        let update = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "アップデート")!,
                              target: self, action: #selector(updateClicked))
        update.bezelStyle = .texturedRounded
        update.isBordered = false
        update.toolTip = "アップデート"
        update.isHidden = latestRelease == nil
        updateButton = update

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "設定")!,
                            target: self, action: #selector(settingsClicked))
        gear.bezelStyle = .texturedRounded
        gear.isBordered = false
        gear.toolTip = "設定"

        let stack = NSStackView()
        stack.addView(update, in: .trailing)
        stack.addView(gear, in: .trailing)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.frame = NSRect(x: 0, y: 0, width: 150, height: 28)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = stack
        controller.layoutAttribute = .trailing
        return controller
    }

    @objc private func settingsClicked() {
        if settingsWindow == nil {
            let view = BaseSettingsView(version: currentVersion)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "設定"
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            settingsWindow = window
        }
        (settingsWindow?.contentView as? BaseSettingsView)?.load()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func updateClicked() {
        guard let release = latestRelease, let window = mainWindow else { return }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        text.textStorage?.setAttributedString(renderMarkdown(release.body ?? ""))
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "\(appName) \(release.tag_name) が利用可能です"
        alert.informativeText = "現在のバージョン: v\(currentVersion)"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "アップデートする")
        alert.addButton(withTitle: "しない")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.install(release) }
        }
    }

    private func install(_ release: Release) {
        guard let window = mainWindow else { return }
        updateButton?.isEnabled = false
        updateButton?.toolTip = "インストール中…"

        updater.install(release) { [weak self] error in
            guard let self else { return }
            let alert = NSAlert()
            if let error {
                self.updateButton?.isEnabled = true
                self.updateButton?.toolTip = "アップデート"
                alert.alertStyle = .warning
                alert.messageText = "アップデートに失敗しました"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
                return
            }
            self.updateButton?.isHidden = true
            alert.messageText = "\(release.tag_name) のインストールが完了しました"
            alert.informativeText = "今すぐ再起動しますか？"
            alert.addButton(withTitle: "再起動する")
            alert.addButton(withTitle: "しない")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { Updater.relaunch() }
            }
        }
    }
}

func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "\(appName) について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "\(appName) を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "\(appName) を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let fileMenu = NSMenu(title: "ファイル")
    fileMenu.addItem(withTitle: "開く…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
    fileMenu.addItem(withTitle: "保存", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    let editMenu = NSMenu(title: "編集")
    editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "検索…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)

    for (title, submenu) in [(appName, appMenu), ("ファイル", fileMenu), ("編集", editMenu)] {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = buildMainMenu()
app.setActivationPolicy(.regular)
app.run()
