import AppKit

protocol WelcomeDelegate: AnyObject {
    func welcomeOpenFile()
    func welcomeClone()
    func welcomeOpen(_ project: Project)
}

final class ProjectRow: NSView {
    let project: Project
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var onRename: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    init(project: Project) {
        self.project = project
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: (project.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [name, path])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "設定")!,
                            target: self, action: #selector(gearClicked(_:)))
        gear.isBordered = false
        gear.toolTip = "プロジェクト設定"
        gear.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [texts, gear])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    @objc private func gearClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "開く", action: #selector(openItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "名前を変更…", action: #selector(renameItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Finderで表示", action: #selector(revealItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "一覧から削除", action: #selector(removeItem), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openItem() { onOpen?() }
    @objc private func renameItem() { onRename?() }
    @objc private func removeItem() { onRemove?() }
    @objc private func revealItem() { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
}

final class WelcomeViewController: NSViewController {
    weak var delegate: WelcomeDelegate?
    private let list = NSStackView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "プロジェクト")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = clip
        scroll.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(header)
        sidebar.addSubview(scroll)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 34, weight: .bold)

        let open = Self.action(symbol: "doc", title: "ファイルを開く", target: self, action: #selector(openClicked))
        let clone = Self.action(symbol: "arrow.down.doc", title: "GitHubからクローン", target: self, action: #selector(cloneClicked))
        let actions = NSStackView(views: [open, clone])
        actions.orientation = .horizontal
        actions.alignment = .top
        actions.spacing = 56

        let center = NSStackView(views: [title, actions])
        center.orientation = .vertical
        center.spacing = 72
        center.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(center)
        let content = NSLayoutGuide()
        root.addLayoutGuide(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 260),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            clip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            center.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        view = root
        reload()
    }

    func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let projects = ProjectStore.all
        if projects.isEmpty {
            let empty = NSTextField(labelWithString: "プロジェクトなし")
            empty.textColor = .tertiaryLabelColor
            let wrap = NSStackView(views: [empty])
            wrap.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            list.addArrangedSubview(wrap)
            return
        }
        for project in projects {
            let row = ProjectRow(project: project)
            row.onOpen = { [weak self] in self?.delegate?.welcomeOpen(project) }
            row.onRemove = { [weak self] in self?.confirmRemove(project) }
            row.onRename = { [weak self] in self?.rename(project) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func openClicked() { delegate?.welcomeOpenFile() }

    @objc private func cloneClicked() { delegate?.welcomeClone() }

    private static func action(symbol: String, title: String, target: AnyObject, action: Selector) -> NSStackView {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
            .withSymbolConfiguration(config)!, target: target, action: action)
        button.isBordered = false
        button.toolTip = title
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [button, label])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func confirmRemove(_ project: Project) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "「\(project.name)」を一覧から削除しますか？"
        alert.informativeText = "ファイル自体は削除されません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            ProjectStore.remove(project)
            self?.reload()
        }
    }

    private func rename(_ project: Project) {
        guard let window = view.window else { return }
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = "プロジェクト名を変更"
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            ProjectStore.rename(project, to: name)
            self?.reload()
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
