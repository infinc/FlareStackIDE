import AppKit

extension Notification.Name {
    static let settingsChanged = Notification.Name("FlareStackIDE.settingsChanged")
}

enum ProjectAddMode: String, CaseIterable {
    case ask, always, never

    var title: String {
        switch self {
        case .ask: return "毎回確認する"
        case .always: return "自動で追加する"
        case .never: return "追加しない"
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static let backgrounds: [(name: String, hex: String)] = [
        ("システム", ""), ("ホワイト", "#FFFFFF"), ("ペーパー", "#F7F3E8"), ("ソラ", "#EEF4FB"),
        ("ダーク", "#1E1F22"), ("ミッドナイト", "#14182B"), ("フォレスト", "#18241E"), ("ブラック", "#000000"),
    ]
    static let foregrounds: [(name: String, hex: String)] = [
        ("自動", ""), ("ブラック", "#1D1D1F"), ("グレー", "#6E6E73"), ("ホワイト", "#F2F2F2"),
        ("グリーン", "#7FD28A"), ("アンバー", "#F0B35A"), ("シアン", "#6CC8E0"),
    ]
    static let fontSizes: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28]
    static let lineSpacings: [(name: String, value: CGFloat)] = [("標準", 0), ("やや広め", 3), ("広め", 6), ("とても広め", 10)]
    static let autosaveIntervals: [TimeInterval] = [3, 10, 30, 60]

    static var fontNames: [(name: String, postScript: String)] {
        let candidates = [("SF Mono", ""), ("Menlo", "Menlo-Regular"), ("Monaco", "Monaco"), ("Courier New", "CourierNewPSMT"),
                          ("Osaka 等幅", "Osaka-Mono"), ("ヒラギノ角ゴ", "HiraginoSans-W3"), ("Helvetica", "Helvetica")]
        return candidates.filter { $0.1.isEmpty || NSFont(name: $0.1, size: 12) != nil }
    }

    private static func changed() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    private static func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private static func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        changed()
    }

    static var backgroundHex: String {
        get { value("Editor.Background", "") }
        set { set(newValue, "Editor.Background") }
    }

    static var foregroundHex: String {
        get { value("Editor.Foreground", "") }
        set { set(newValue, "Editor.Foreground") }
    }

    static var fontName: String {
        get { value("Editor.Font", "") }
        set { set(newValue, "Editor.Font") }
    }

    static var fontSize: CGFloat {
        get { CGFloat(value("Editor.FontSize", 13.0)) }
        set { set(Double(min(max(newValue, 8), 40)), "Editor.FontSize") }
    }

    static var lineSpacing: CGFloat {
        get { CGFloat(value("Editor.LineSpacing", 0.0)) }
        set { set(Double(newValue), "Editor.LineSpacing") }
    }

    static var wrapLines: Bool {
        get { value("Editor.Wrap", false) }
        set { set(newValue, "Editor.Wrap") }
    }

    static var gitEnabled: Bool {
        get { value("Base.Git", true) }
        set { set(newValue, "Base.Git") }
    }

    static var projectAddMode: ProjectAddMode {
        get { ProjectAddMode(rawValue: value("Base.ProjectAdd", "ask")) ?? .ask }
        set { set(newValue.rawValue, "Base.ProjectAdd") }
    }

    static var autosaveEnabled: Bool {
        get { value("Base.Autosave", true) }
        set { set(newValue, "Base.Autosave") }
    }

    static var autosaveInterval: TimeInterval {
        get { value("Base.AutosaveInterval", 10.0) }
        set { set(newValue, "Base.AutosaveInterval") }
    }

    static func resetEditor() {
        ["Editor.Background", "Editor.Foreground", "Editor.Font", "Editor.FontSize", "Editor.LineSpacing", "Editor.Wrap"]
            .forEach { defaults.removeObject(forKey: $0) }
        changed()
    }

    static var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var background: NSColor { NSColor(hex: backgroundHex) ?? .textBackgroundColor }

    static var foreground: NSColor {
        if let color = NSColor(hex: foregroundHex) { return color }
        guard let bg = NSColor(hex: backgroundHex) else { return .textColor }
        return bg.isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.5
    }

    static func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            (NSColor(hex: hex) ?? .textBackgroundColor).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }
}

final class EditorSettingsMenu: NSObject {
    private let menu = NSMenu()

    func popUp(from button: NSButton) {
        build()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, _ action: Selector, _ value: Any? = nil, checked: Bool = false, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        item.image = image
        return item
    }

    private func submenu(_ title: String, symbol: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let sub = NSMenu()
        items.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }

    private func build() {
        menu.removeAllItems()
        let header = NSMenuItem(title: "エディタ設定", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(submenu("背景色", symbol: "paintpalette", Settings.backgrounds.map {
            item($0.name, #selector(setBackground(_:)), $0.hex, checked: Settings.backgroundHex == $0.hex, image: NSColor.swatch($0.hex))
        }))
        menu.addItem(submenu("文字色", symbol: "character", Settings.foregrounds.map {
            item($0.name, #selector(setForeground(_:)), $0.hex, checked: Settings.foregroundHex == $0.hex, image: NSColor.swatch($0.hex))
        }))
        menu.addItem(submenu("フォント", symbol: "textformat", Settings.fontNames.map {
            let entry = item($0.name, #selector(setFont(_:)), $0.postScript, checked: Settings.fontName == $0.postScript)
            entry.attributedTitle = NSAttributedString(string: $0.name, attributes: [
                .font: NSFont(name: $0.postScript, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)])
            return entry
        }))
        var sizes = [item("大きく", #selector(growFont)), item("小さく", #selector(shrinkFont)), .separator()]
        sizes += Settings.fontSizes.map { item("\(Int($0)) pt", #selector(setFontSize(_:)), $0, checked: Settings.fontSize == $0) }
        menu.addItem(submenu("フォントサイズ（\(Int(Settings.fontSize)) pt）", symbol: "textformat.size", sizes))
        menu.addItem(submenu("行間", symbol: "line.3.horizontal", Settings.lineSpacings.map {
            item($0.name, #selector(setLineSpacing(_:)), $0.value, checked: Settings.lineSpacing == $0.value)
        }))
        menu.addItem(item("行を折り返す", #selector(toggleWrap), checked: Settings.wrapLines))
        menu.addItem(.separator())
        menu.addItem(item("初期値に戻す", #selector(reset)))
    }

    @objc private func setBackground(_ sender: NSMenuItem) { Settings.backgroundHex = sender.representedObject as? String ?? "" }
    @objc private func setForeground(_ sender: NSMenuItem) { Settings.foregroundHex = sender.representedObject as? String ?? "" }
    @objc private func setFont(_ sender: NSMenuItem) { Settings.fontName = sender.representedObject as? String ?? "" }
    @objc private func setFontSize(_ sender: NSMenuItem) { Settings.fontSize = sender.representedObject as? CGFloat ?? 13 }
    @objc private func setLineSpacing(_ sender: NSMenuItem) { Settings.lineSpacing = sender.representedObject as? CGFloat ?? 0 }
    @objc private func growFont() { Settings.fontSize += 1 }
    @objc private func shrinkFont() { Settings.fontSize -= 1 }
    @objc private func toggleWrap() { Settings.wrapLines.toggle() }
    @objc private func reset() { Settings.resetEditor() }
}

final class BaseSettingsView: NSView {
    private let git = NSButton(checkboxWithTitle: "Git連携を有効にする（ブランチ表示・ツリーの色分け・Gitパネル）", target: nil, action: nil)
    private let projectAdd = NSPopUpButton()
    private let autosave = NSButton(checkboxWithTitle: "自動保存する", target: nil, action: nil)
    private let interval = NSPopUpButton()
    private let account = NSTextField(labelWithString: "")
    private let unlink = NSButton(title: "連携を解除", target: nil, action: nil)

    init(version: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 330))
        git.target = self
        git.action = #selector(changed)
        projectAdd.addItems(withTitles: ProjectAddMode.allCases.map(\.title))
        projectAdd.target = self
        projectAdd.action = #selector(changed)
        autosave.target = self
        autosave.action = #selector(changed)
        interval.addItems(withTitles: Settings.autosaveIntervals.map { "\(Int($0)) 秒ごと" })
        interval.target = self
        interval.action = #selector(changed)
        account.textColor = .secondaryLabelColor
        unlink.bezelStyle = .rounded
        unlink.target = self
        unlink.action = #selector(unlinkClicked)

        func section(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            return label
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let versionLabel = NSTextField(labelWithString: "\(appName) v\(version)")
        versionLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            section("Git"), git, row([account, unlink]),
            section("プロジェクト"), row([NSTextField(labelWithString: "開いたファイル・フォルダを一覧に"), projectAdd]),
            section("保存"), row([autosave, interval]),
            versionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: stack.views[2])
        stack.setCustomSpacing(18, after: stack.views[4])
        stack.setCustomSpacing(24, after: stack.views[6])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    func load() {
        git.state = Settings.gitEnabled ? .on : .off
        projectAdd.selectItem(at: ProjectAddMode.allCases.firstIndex(of: Settings.projectAddMode) ?? 0)
        autosave.state = Settings.autosaveEnabled ? .on : .off
        interval.selectItem(at: Settings.autosaveIntervals.firstIndex(of: Settings.autosaveInterval) ?? 1)
        interval.isEnabled = Settings.autosaveEnabled
        loadAccount()
    }

    private func loadAccount() {
        let saved = GitHub.savedToken != nil
        unlink.isHidden = !saved
        account.stringValue = saved ? "GitHub: トークンで連携中" : "GitHub: 確認中…"
        guard !saved else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gh = GitHub.ghToken() != nil
            DispatchQueue.main.async {
                self?.account.stringValue = gh ? "GitHub: gh CLI のログインを使用中" : "GitHub: 未連携（クローン画面から連携できます）"
            }
        }
    }

    @objc private func changed() {
        Settings.gitEnabled = git.state == .on
        Settings.projectAddMode = ProjectAddMode.allCases[max(projectAdd.indexOfSelectedItem, 0)]
        Settings.autosaveEnabled = autosave.state == .on
        Settings.autosaveInterval = Settings.autosaveIntervals[max(interval.indexOfSelectedItem, 0)]
        interval.isEnabled = Settings.autosaveEnabled
    }

    @objc private func unlinkClicked() {
        GitHub.forget()
        loadAccount()
    }
}
