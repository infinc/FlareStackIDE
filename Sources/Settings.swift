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

enum Surface: String, CaseIterable {
    case editor, feed, midTab, bigTab

    var title: String {
        switch self {
        case .editor: return "コード編集画面"
        case .feed: return "フィード"
        case .midTab: return "中タブ"
        case .bigTab: return "大タブ"
        }
    }

    var detail: String {
        switch self {
        case .editor: return "コードを編集する領域の背景"
        case .feed: return "ディレクトリ・プラグイン・ターミナル・Git の中身"
        case .midTab: return "「ディレクトリ」「ターミナル」の見出しや、ファイルのタブ列"
        case .bigTab: return "一番上のバーと一番左のアイコン列"
        }
    }

    fileprivate var key: String { self == .editor ? "Editor.Background" : "Surface.\(rawValue)" }

    var systemColor: NSColor {
        switch self {
        case .editor: return .textBackgroundColor
        case .feed: return .controlBackgroundColor
        case .midTab, .bigTab: return .windowBackgroundColor
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static let themes: [(name: String, colors: [String])] = [
        ("システム", ["", "", "", ""]),
        ("ホワイト", ["#FFFFFF", "#F6F6F7", "#EDEDEF", "#E4E4E7"]),
        ("ペーパー", ["#F7F3E8", "#F0EBDD", "#E8E1CF", "#DFD7C1"]),
        ("ソラ", ["#EEF4FB", "#E6EEF8", "#DCE6F3", "#D1DDEE"]),
        ("ダーク", ["#1E1F22", "#232428", "#2B2D31", "#313338"]),
        ("ミッドナイト", ["#14182B", "#181D33", "#1E243D", "#252C48"]),
        ("フォレスト", ["#18241E", "#1C2A23", "#22332A", "#2A3D33"]),
        ("ブラック", ["#000000", "#0A0A0A", "#141414", "#1C1C1C"]),
    ]
    static let foregrounds: [(name: String, hex: String)] = [
        ("自動", ""), ("ブラック", "#1D1D1F"), ("グレー", "#6E6E73"), ("ホワイト", "#F2F2F2"),
        ("グリーン", "#7FD28A"), ("アンバー", "#F0B35A"), ("シアン", "#6CC8E0"),
    ]
    static let lineSpacings: [(name: String, value: CGFloat)] = [("標準", 0), ("やや広め", 3), ("広め", 6), ("とても広め", 10)]
    static let autosaveIntervals: [TimeInterval] = [0, 3, 10, 30, 60]

    static func intervalTitle(_ value: TimeInterval) -> String { value == 0 ? "即時" : "\(Int(value)) 秒ごと" }

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

    static func surfaceHex(_ surface: Surface) -> String { value(surface.key, "") }

    static func setSurfaceHex(_ hex: String, for surface: Surface) { set(hex, surface.key) }

    static func surfaceColor(_ surface: Surface) -> NSColor? { NSColor(hex: surfaceHex(surface)) }

    static var themeIndex: Int? {
        let current = Surface.allCases.map(surfaceHex)
        return themes.firstIndex { $0.colors == current }
    }

    static func applyTheme(_ index: Int) {
        guard themes.indices.contains(index) else { return }
        for (surface, hex) in zip(Surface.allCases, themes[index].colors) { defaults.set(hex, forKey: surface.key) }
        defaults.set("", forKey: "Editor.Foreground")
        changed()
    }

    static var backgroundHex: String {
        get { surfaceHex(.editor) }
        set { setSurfaceHex(newValue, for: .editor) }
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

    static var toastDuration: TimeInterval {
        get { value("Toast.Duration", 5.0) }
        set { set(min(max(newValue, 2), 30), "Toast.Duration") }
    }

    static var toastSize: ToastSize {
        get { ToastSize(rawValue: value("Toast.Size", "medium")) ?? .medium }
        set { set(newValue.rawValue, "Toast.Size") }
    }

    static var pluginAutoUpdate: Bool {
        get { value("Plugins.AutoUpdate", false) }
        set { set(newValue, "Plugins.AutoUpdate") }
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

    static var autosaveImmediate: Bool { autosaveEnabled && autosaveInterval == 0 }

    static var terminalCursorBlink: Bool {
        get { value("Terminal.CursorBlink", true) }
        set { set(newValue, "Terminal.CursorBlink") }
    }

    static var terminalCursorBar: Bool {
        get { value("Terminal.CursorBar", false) }
        set { set(newValue, "Terminal.CursorBar") }
    }

    static let bigTabHeightRange: ClosedRange<Double> = 24...56
    static let bigTabWidthRange: ClosedRange<Double> = 32...64

    static var bigTabHeight: CGFloat {
        get { CGFloat(value("BigTab.Height", 32.0)) }
        set { set(min(max(Double(newValue), bigTabHeightRange.lowerBound), bigTabHeightRange.upperBound), "BigTab.Height") }
    }

    static var bigTabWidth: CGFloat {
        get { CGFloat(value("BigTab.Width", 40.0)) }
        set { set(min(max(Double(newValue), bigTabWidthRange.lowerBound), bigTabWidthRange.upperBound), "BigTab.Width") }
    }

    static var bigTabIconSize: CGFloat { max(11, min(bigTabWidth * 0.38, 22)) }

    static func pluginValue(_ id: String, _ key: String) -> String? { defaults.string(forKey: "Plugin.\(id).\(key)") }

    static func setPluginValue(_ id: String, _ key: String, _ value: String?) { set(value, "Plugin.\(id).\(key)") }

    static func resetEditor() {
        (["Editor.Foreground", "Editor.Font", "Editor.FontSize", "Editor.LineSpacing", "Editor.Wrap", "Toast.Duration", "Toast.Size",
          "Terminal.CursorBlink", "Terminal.CursorBar", "BigTab.Height", "BigTab.Width"]
            + Surface.allCases.map(\.key)).forEach { defaults.removeObject(forKey: $0) }
        changed()
    }

    static var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var background: NSColor { surfaceColor(.editor) ?? .textBackgroundColor }

    static var editorIsDark: Bool {
        if let color = surfaceColor(.editor) { return color.isDark }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static var foreground: NSColor {
        if let color = NSColor(hex: foregroundHex) { return color }
        guard let bg = surfaceColor(.editor) else { return .textColor }
        return bg.isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }

    private static var lineHeightCache: (font: NSFont, height: CGFloat)?

    static var lineHeight: CGFloat {
        let font = font
        if let cache = lineHeightCache, cache.font == font { return cache.height }
        let layout = NSLayoutManager()
        let japanese = NSFont(name: "HiraginoSans-W3", size: font.pointSize).map(layout.defaultLineHeight) ?? 0
        let height = ceil(max(layout.defaultLineHeight(for: font), japanese))
        lineHeightCache = (font, height)
        return height
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight
        style.minimumLineHeight = height
        style.maximumLineHeight = height
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

    var hexString: String {
        var rgb = self
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { rgb = self.usingColorSpace(.sRGB) ?? self }
        let c = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c[0], c[1], c[2])
    }

    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.5
    }

    static func swatch(_ hexes: [String]) -> NSImage {
        NSImage(size: NSSize(width: 14 * CGFloat(max(hexes.count, 1)) - CGFloat(max(hexes.count - 1, 0)) * 4, height: 14), flipped: false) { rect in
            for (i, hex) in hexes.enumerated() {
                let path = NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * 10 + 1, y: 1, width: 12, height: 12), xRadius: 3, yRadius: 3)
                (NSColor(hex: hex) ?? .textBackgroundColor).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
            return true
        }
    }
}

extension NSView {
    func paint(_ surface: Surface) {
        wantsLayer = true
        let color = Settings.surfaceColor(surface)
        layer?.backgroundColor = color?.cgColor
        appearance = color.map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua)! }
    }
}

extension NSWindow {
    func paint(_ surface: Surface) {
        let color = Settings.surfaceColor(surface)
        backgroundColor = color ?? .windowBackgroundColor
        appearance = color.map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua)! }
    }
}

enum Popups {
    private static var windows: [String: NSWindow] = [:]
    private static let observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
        windows.values.forEach { $0.paint(.feed) }
    }

    static func show(_ key: String, title: String, over parent: NSWindow?, make: () -> NSView) {
        let window = windows[key] ?? {
            let view = make()
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = title
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = view
            windows[key] = panel
            _ = observer
            return panel
        }()
        window.paint(.feed)
        if !window.isVisible, let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }
}

final class EditorSettingsMenu: NSObject {
    private let menu = NSMenu()
    private weak var window: NSWindow?

    func popUp(from button: NSButton) {
        window = button.window
        build()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, _ action: Selector, _ value: Any? = nil, checked: Bool = false, symbol: String? = nil, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        item.image = image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        return item
    }

    private func build() {
        menu.removeAllItems()
        let header = NSMenuItem(title: "エディタ設定", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let release = AppUpdate.shared.latest {
            menu.addItem(item("アップデート \(release.tag_name)", #selector(updateClicked), symbol: "arrow.down.circle"))
            menu.addItem(.separator())
        }
        menu.addItem(item("プラグイン", #selector(pluginsClicked), symbol: "puzzlepiece.extension"))
        let theme = NSMenuItem(title: "テーマ", action: nil, keyEquivalent: "")
        theme.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "テーマ")
        let themes = NSMenu()
        for (i, entry) in Settings.themes.enumerated() {
            themes.addItem(item(entry.name, #selector(themeClicked(_:)), i, checked: Settings.themeIndex == i, image: NSColor.swatch(entry.colors)))
        }
        theme.submenu = themes
        menu.addItem(theme)
        let autosave = NSMenuItem(title: "自動保存: \(Settings.autosaveEnabled ? Settings.intervalTitle(Settings.autosaveInterval) : "オフ")",
                                  action: nil, keyEquivalent: "")
        autosave.image = NSImage(systemSymbolName: Settings.autosaveEnabled ? "checkmark.icloud" : "icloud.slash", accessibilityDescription: nil)
        let intervals = NSMenu()
        intervals.addItem(item("オフ", #selector(autosaveClicked(_:)), -1.0, checked: !Settings.autosaveEnabled))
        intervals.addItem(.separator())
        for value in Settings.autosaveIntervals {
            intervals.addItem(item(Settings.intervalTitle(value), #selector(autosaveClicked(_:)), value,
                                   checked: Settings.autosaveEnabled && Settings.autosaveInterval == value))
        }
        autosave.submenu = intervals
        menu.addItem(autosave)
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(preferencesClicked), symbol: "gearshape"))
    }

    @objc private func updateClicked() {
        guard let window else { return }
        AppUpdate.shared.present(in: window)
    }

    @objc private func pluginsClicked() {
        Popups.show("plugins", title: "プラグイン", over: window) { PluginManagerView() }
    }

    @objc private func themeClicked(_ sender: NSMenuItem) { Settings.applyTheme(sender.representedObject as? Int ?? 0) }

    @objc private func autosaveClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        if value < 0 {
            Settings.autosaveEnabled = false
        } else {
            Settings.autosaveInterval = value
            Settings.autosaveEnabled = true
        }
    }

    @objc private func preferencesClicked() {
        Popups.show("preferences", title: "設定", over: window) { PreferencesView() }
    }
}

final class LayoutPreview: NSView {
    var selected: Surface = .editor { didSet { needsDisplay = true } }
    var onSelect: ((Surface) -> Void)?

    override var isFlipped: Bool { true }

    private func regions() -> [(Surface, NSRect)] {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let top: CGFloat = 20, strip: CGFloat = 18, bar: CGFloat = 13
        let body = NSRect(x: b.minX + strip, y: b.minY + top, width: b.width - strip, height: b.height - top)
        let leftW = body.width * 0.3
        let editorH = (body.height - bar) * 0.66
        let rightX = body.minX + leftW + 1
        let rightW = body.maxX - rightX
        return [
            (.bigTab, NSRect(x: b.minX, y: b.minY, width: b.width, height: top)),
            (.bigTab, NSRect(x: b.minX, y: b.minY + top, width: strip, height: b.height - top)),
            (.midTab, NSRect(x: body.minX, y: body.minY, width: leftW, height: bar)),
            (.feed, NSRect(x: body.minX, y: body.minY + bar, width: leftW, height: body.height - bar)),
            (.midTab, NSRect(x: rightX, y: body.minY, width: rightW, height: bar)),
            (.editor, NSRect(x: rightX, y: body.minY + bar, width: rightW, height: editorH)),
            (.midTab, NSRect(x: rightX, y: body.minY + bar + editorH + 1, width: rightW, height: bar)),
            (.feed, NSRect(x: rightX, y: body.minY + bar * 2 + editorH + 1, width: rightW, height: body.maxY - (body.minY + bar * 2 + editorH + 1))),
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.separatorColor.setFill()
        bounds.fill()
        for (surface, rect) in regions() {
            let color = Settings.surfaceColor(surface) ?? surface.systemColor
            color.setFill()
            rect.fill()
            let ink = (color.usingColorSpace(.sRGB).map { $0.isDark } ?? false) ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.25)
            ink.setFill()
            switch surface {
            case .bigTab where rect.height < rect.width:
                for i in 0..<3 { NSBezierPath(ovalIn: NSRect(x: rect.minX + 8 + CGFloat(i) * 10, y: rect.midY - 3, width: 6, height: 6)).fill() }
                NSRect(x: rect.minX + 50, y: rect.midY - 2, width: 60, height: 4).fill()
            case .bigTab:
                for i in 0..<3 { NSRect(x: rect.midX - 4, y: rect.minY + 8 + CGFloat(i) * 14, width: 8, height: 8).fill() }
            case .midTab:
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 4, y: rect.minY + 3, width: min(42, rect.width - 8), height: rect.height - 6), xRadius: 2, yRadius: 2).fill()
            case .feed:
                var y = rect.minY + 7
                while y < rect.maxY - 6 {
                    NSRect(x: rect.minX + 8, y: y, width: min(rect.width * 0.55, 70), height: 3).fill()
                    y += 9
                }
            case .editor:
                let fg = Settings.surfaceColor(.editor) == nil ? NSColor.textColor : Settings.foreground
                let widths: [CGFloat] = [0.5, 0.7, 0.35, 0.6, 0.45, 0.8, 0.3, 0.55]
                var y = rect.minY + 8
                for (i, w) in widths.enumerated() where y < rect.maxY - 6 {
                    (i % 3 == 0 ? NSColor.systemPink : fg).withAlphaComponent(0.75).setFill()
                    NSRect(x: rect.minX + 10 + CGFloat(i % 2) * 10, y: y, width: (rect.width - 30) * w, height: 3).fill()
                    y += 10
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setStroke()
        for (surface, rect) in regions() where surface == selected {
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
        NSColor.separatorColor.setStroke()
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = regions().first(where: { $0.1.contains(point) })?.0 else { return }
        selected = hit
        onSelect?(hit)
    }
}

final class PreferencesView: NSView {
    private let preview = LayoutPreview()
    private let surfacePopup = NSPopUpButton()
    private let surfaceDetail = NSTextField(wrappingLabelWithString: "")
    private let well = NSColorWell()
    private let hexField = NSTextField()
    private let sliders = (0..<3).map { _ in NSSlider(value: 0, minValue: 0, maxValue: 255, target: nil, action: nil) }
    private let sliderValues = (0..<3).map { _ in NSTextField(labelWithString: "0") }
    private let systemButton = NSButton(title: "システム既定に戻す", target: nil, action: nil)
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let foregroundPopup = NSPopUpButton()
    private let spacingPopup = NSPopUpButton()
    private let wrap = NSButton(checkboxWithTitle: "行を折り返す", target: nil, action: nil)
    private let durationSlider = NSSlider(value: 5, minValue: 2, maxValue: 30, target: nil, action: nil)
    private let durationLabel = NSTextField(labelWithString: "")
    private let sizeControl = NSSegmentedControl(labels: ToastSize.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let cursorBlink = NSButton(checkboxWithTitle: "カーソルを点滅させる", target: nil, action: nil)
    private let cursorShape = NSSegmentedControl(labels: ["四角", "棒線"], trackingMode: .selectOne, target: nil, action: nil)
    private let heightSlider = NSSlider(value: 32, minValue: Settings.bigTabHeightRange.lowerBound, maxValue: Settings.bigTabHeightRange.upperBound, target: nil, action: nil)
    private let heightLabel = NSTextField(labelWithString: "")
    private let widthSlider = NSSlider(value: 40, minValue: Settings.bigTabWidthRange.lowerBound, maxValue: Settings.bigTabWidthRange.upperBound, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "")
    private var loading = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 660, height: 430))
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, view) in [("背景色", colorPane()), ("フォント", fontPane()), ("通知", toastPane()), ("ターミナル", terminalPane()), ("大タブ", bigTabPane())] {
            let item = NSTabViewItem()
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
        let reset = NSButton(title: "すべて初期値に戻す", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        addSubview(reset)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 660),
            heightAnchor.constraint(equalToConstant: 430),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            reset.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            reset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(load), name: .settingsChanged, object: nil)
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private static func pane(_ content: NSView, top: CGFloat = 16) -> NSView {
        let pane = NSView()
        pane.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pane.topAnchor, constant: top),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -16),
        ])
        return pane
    }

    private func colorPane() -> NSView {
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.onSelect = { [weak self] _ in self?.loadColor() }
        surfacePopup.addItems(withTitles: Surface.allCases.map(\.title))
        surfacePopup.target = self
        surfacePopup.action = #selector(surfaceChanged)
        surfaceDetail.font = .systemFont(ofSize: 11)
        surfaceDetail.textColor = .secondaryLabelColor
        surfaceDetail.preferredMaxLayoutWidth = 250
        well.target = self
        well.action = #selector(wellChanged)
        hexField.placeholderString = "#RRGGBB"
        hexField.target = self
        hexField.action = #selector(hexChanged)
        hexField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        systemButton.bezelStyle = .rounded
        systemButton.target = self
        systemButton.action = #selector(systemClicked)
        var rows: [[NSView]] = [
            [Self.label("場所"), surfacePopup],
            [NSGridCell.emptyContentView, surfaceDetail],
            [Self.label("色"), NSStackView(views: [well, hexField])],
        ]
        for (i, name) in ["R", "G", "B"].enumerated() {
            sliders[i].target = self
            sliders[i].action = #selector(sliderChanged)
            sliders[i].isContinuous = true
            sliders[i].widthAnchor.constraint(equalToConstant: 150).isActive = true
            sliderValues[i].font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            sliderValues[i].widthAnchor.constraint(equalToConstant: 28).isActive = true
            rows.append([Self.label(name), NSStackView(views: [sliders[i], sliderValues[i]])])
        }
        rows.append([NSGridCell.emptyContentView, systemButton])
        let grid = Self.grid(rows)
        let hint = NSTextField(wrappingLabelWithString: "プレビューの場所をクリックして選べます")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        let pane = NSView()
        [preview, hint, grid].forEach(pane.addSubview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            preview.widthAnchor.constraint(equalToConstant: 280),
            preview.heightAnchor.constraint(equalToConstant: 210),
            hint.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            hint.widthAnchor.constraint(equalTo: preview.widthAnchor),
            grid.topAnchor.constraint(equalTo: preview.topAnchor),
            grid.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -12),
        ])
        return pane
    }

    private func fontPane() -> NSView {
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        for entry in Settings.fontNames {
            fontPopup.addItem(withTitle: entry.name)
            fontPopup.lastItem?.representedObject = entry.postScript
            fontPopup.lastItem?.attributedTitle = NSAttributedString(string: entry.name, attributes: [
                .font: NSFont(name: entry.postScript, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)])
        }
        sizeField.formatter = {
            let f = NumberFormatter()
            f.minimum = 8
            f.maximum = 40
            f.maximumFractionDigits = 0
            return f
        }()
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        sizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 40
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(stepperChanged)
        for entry in Settings.foregrounds {
            foregroundPopup.addItem(withTitle: entry.name)
            foregroundPopup.lastItem?.image = entry.hex.isEmpty ? nil : NSColor.swatch([entry.hex])
        }
        foregroundPopup.target = self
        foregroundPopup.action = #selector(foregroundChanged)
        spacingPopup.addItems(withTitles: Settings.lineSpacings.map(\.name))
        spacingPopup.target = self
        spacingPopup.action = #selector(spacingChanged)
        wrap.target = self
        wrap.action = #selector(wrapChanged)
        return Self.pane(Self.grid([
            [Self.label("フォント"), fontPopup],
            [Self.label("フォントサイズ"), NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])],
            [Self.label("文字色"), foregroundPopup],
            [Self.label("行間"), spacingPopup],
            [NSGridCell.emptyContentView, wrap],
        ]))
    }

    private func toastPane() -> NSView {
        durationSlider.target = self
        durationSlider.action = #selector(durationChanged)
        durationSlider.numberOfTickMarks = 29
        durationSlider.allowsTickMarkValuesOnly = true
        durationSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeControl.target = self
        sizeControl.action = #selector(toastSizeChanged)
        let test = NSButton(title: "テスト通知を表示", target: self, action: #selector(testClicked))
        test.bezelStyle = .rounded
        let note = NSTextField(wrappingLabelWithString: "通知は右下に表示されます。× で閉じられ、下のバーが消えるまでの残り時間を表します（マウスを重ねている間は止まります）。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        return Self.pane(Self.grid([
            [Self.label("表示時間"), NSStackView(views: [durationSlider, durationLabel])],
            [Self.label("大きさ"), sizeControl],
            [NSGridCell.emptyContentView, test],
            [NSGridCell.emptyContentView, note],
        ]))
    }

    private func terminalPane() -> NSView {
        cursorBlink.target = self
        cursorBlink.action = #selector(terminalChanged)
        cursorShape.target = self
        cursorShape.action = #selector(terminalChanged)
        return Self.pane(Self.grid([
            [Self.label("カーソルの形"), cursorShape],
            [NSGridCell.emptyContentView, cursorBlink],
        ]))
    }

    private func bigTabPane() -> NSView {
        for (slider, label) in [(heightSlider, heightLabel), (widthSlider, widthLabel)] {
            slider.target = self
            slider.action = #selector(bigTabChanged)
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        let note = NSTextField(wrappingLabelWithString: "大タブは一番上のバー（太さ）と一番左のアイコン列（幅）です。アイコンの大きさは幅に合わせて変わります。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        return Self.pane(Self.grid([
            [Self.label("上のバーの太さ"), NSStackView(views: [heightSlider, heightLabel])],
            [Self.label("左のアイコン列の幅"), NSStackView(views: [widthSlider, widthLabel])],
            [NSGridCell.emptyContentView, note],
        ]))
    }

    private var surface: Surface { preview.selected }

    @objc private func load() {
        loading = true
        defer { loading = false }
        preview.needsDisplay = true
        loadColor()
        let fonts = Settings.fontNames
        fontPopup.selectItem(at: fonts.firstIndex { $0.postScript == Settings.fontName } ?? 0)
        sizeField.integerValue = Int(Settings.fontSize)
        sizeStepper.integerValue = Int(Settings.fontSize)
        foregroundPopup.selectItem(at: Settings.foregrounds.firstIndex { $0.hex == Settings.foregroundHex } ?? 0)
        spacingPopup.selectItem(at: Settings.lineSpacings.firstIndex { $0.value == Settings.lineSpacing } ?? 0)
        wrap.state = Settings.wrapLines ? .on : .off
        durationSlider.doubleValue = Settings.toastDuration
        durationLabel.stringValue = "\(Int(Settings.toastDuration)) 秒"
        sizeControl.selectedSegment = ToastSize.allCases.firstIndex(of: Settings.toastSize) ?? 1
        cursorBlink.state = Settings.terminalCursorBlink ? .on : .off
        cursorShape.selectedSegment = Settings.terminalCursorBar ? 1 : 0
        heightSlider.doubleValue = Double(Settings.bigTabHeight)
        heightLabel.stringValue = "\(Int(Settings.bigTabHeight)) pt"
        widthSlider.doubleValue = Double(Settings.bigTabWidth)
        widthLabel.stringValue = "\(Int(Settings.bigTabWidth)) pt"
    }

    private func loadColor() {
        let wasLoading = loading
        loading = true
        defer { loading = wasLoading }
        surfacePopup.selectItem(at: Surface.allCases.firstIndex(of: surface) ?? 0)
        surfaceDetail.stringValue = surface.detail
        let custom = Settings.surfaceColor(surface)
        var color = custom ?? surface.systemColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.sRGB) ?? color }
        well.color = color
        hexField.stringValue = custom == nil ? "" : Settings.surfaceHex(surface)
        hexField.placeholderString = custom == nil ? "システム既定" : "#RRGGBB"
        for (i, value) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
            sliders[i].doubleValue = Double(value * 255).rounded()
            sliderValues[i].stringValue = "\(Int(sliders[i].doubleValue))"
        }
        systemButton.isEnabled = custom != nil
    }

    private func setColor(_ hex: String) {
        guard !loading else { return }
        Settings.setSurfaceHex(hex, for: surface)
    }

    @objc private func surfaceChanged() {
        preview.selected = Surface.allCases[max(surfacePopup.indexOfSelectedItem, 0)]
        loadColor()
    }

    @objc private func wellChanged() { setColor(well.color.hexString) }

    @objc private func hexChanged() {
        let text = hexField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let color = NSColor(hex: text) else { return loadColor() }
        setColor(color.hexString)
    }

    @objc private func sliderChanged() {
        let c = sliders.map { Int($0.doubleValue.rounded()) }
        setColor(String(format: "#%02X%02X%02X", c[0], c[1], c[2]))
    }

    @objc private func systemClicked() { setColor("") }

    @objc private func fontChanged() { Settings.fontName = fontPopup.selectedItem?.representedObject as? String ?? "" }
    @objc private func sizeFieldChanged() { Settings.fontSize = CGFloat(sizeField.integerValue) }
    @objc private func stepperChanged() { Settings.fontSize = CGFloat(sizeStepper.integerValue) }
    @objc private func foregroundChanged() { Settings.foregroundHex = Settings.foregrounds[max(foregroundPopup.indexOfSelectedItem, 0)].hex }
    @objc private func spacingChanged() { Settings.lineSpacing = Settings.lineSpacings[max(spacingPopup.indexOfSelectedItem, 0)].value }
    @objc private func wrapChanged() { Settings.wrapLines = wrap.state == .on }
    @objc private func durationChanged() { Settings.toastDuration = durationSlider.doubleValue.rounded() }
    @objc private func toastSizeChanged() { Settings.toastSize = ToastSize.allCases[max(sizeControl.selectedSegment, 0)] }

    @objc private func terminalChanged() {
        guard !loading else { return }
        Settings.terminalCursorBlink = cursorBlink.state == .on
        Settings.terminalCursorBar = cursorShape.selectedSegment == 1
    }

    @objc private func bigTabChanged() {
        guard !loading else { return }
        Settings.bigTabHeight = CGFloat(heightSlider.doubleValue.rounded())
        Settings.bigTabWidth = CGFloat(widthSlider.doubleValue.rounded())
    }

    @objc private func testClicked() {
        Toasts.post("テスト通知", message: "\(Int(Settings.toastDuration)) 秒で消えます（大きさ: \(Settings.toastSize.title)）",
                    actions: [("OK", {})])
    }

    @objc private func resetClicked() { Settings.resetEditor() }
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
        interval.addItems(withTitles: Settings.autosaveIntervals.map(Settings.intervalTitle))
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
        interval.selectItem(at: Settings.autosaveIntervals.firstIndex(of: Settings.autosaveInterval) ?? 2)
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
