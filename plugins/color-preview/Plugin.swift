import AppKit
@testable import FlareStackIDE

final class ColorPreviewPlugin: NativePlugin {
    let id = "color-preview"
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { ColorPreviewAddon(editor: editor) }
}

struct RGB: Equatable {
    var red: Int, green: Int, blue: Int

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var color: NSColor { NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1) }

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        self.init(red: value >> 16 & 0xFF, green: value >> 8 & 0xFF, blue: value & 0xFF)
    }

    init(hue: CGFloat, saturation: CGFloat, value: CGFloat) {
        let color = NSColor(hue: min(hue, 0.9999), saturation: saturation, brightness: value, alpha: 1).usingColorSpace(.sRGB)!
        self.init(red: Int((color.redComponent * 255).rounded()), green: Int((color.greenComponent * 255).rounded()), blue: Int((color.blueComponent * 255).rounded()))
    }

    var hsv: (hue: CGFloat, saturation: CGFloat, value: CGFloat) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &value, alpha: nil)
        return (hue, saturation, value)
    }

    var hsl: String {
        let values = [red, green, blue].map { CGFloat($0) / 255 }
        let high = values.max()!, low = values.min()!, light = (high + low) / 2
        let saturation = high == low ? 0 : (high - low) / (1 - abs(2 * light - 1))
        return "hsl(\(Int((hsv.hue * 360).rounded())), \(Int((saturation * 100).rounded()))%, \(Int((light * 100).rounded()))%)"
    }

    var css: String { "rgb(\(red), \(green), \(blue))" }
}

final class ColorMap: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1 { didSet { needsDisplay = true } }
    var value: CGFloat = 1 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        bounds.fill()
        NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0))?.draw(in: bounds, angle: 0)
        NSGradient(starting: .black, ending: NSColor.black.withAlphaComponent(0))?.draw(in: bounds, angle: 90)
        let marker = NSBezierPath(ovalIn: NSRect(x: saturation * bounds.width - 5, y: value * bounds.height - 5, width: 10, height: 10))
        NSColor.white.setStroke()
        marker.lineWidth = 2
        marker.stroke()
    }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onChange?(min(max(point.x / bounds.width, 0), 1), min(max(point.y / bounds.height, 0), 1))
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

final class HueBar: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let colors = stride(from: CGFloat(0), through: 1, by: 1.0 / 6).map { NSColor(hue: min($0, 0.9999), saturation: 1, brightness: 1, alpha: 1) }
        NSGradient(colors: colors)?.draw(in: bounds, angle: 90)
        NSColor.white.setFill()
        NSRect(x: 0, y: hue * bounds.height - 1, width: bounds.width, height: 2).fill()
    }

    private func pick(_ event: NSEvent) { onChange?(min(max(convert(event.locationInWindow, from: nil).y / bounds.height, 0), 1)) }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

final class ColorPreviewView: NSView, NSTextFieldDelegate {
    private let map = ColorMap()
    private let hueBar = HueBar()
    private let swatch = NSView()
    private let sliders = [NSSlider(), NSSlider(), NSSlider()]
    private let fields = [NSTextField(), NSTextField(), NSTextField()]
    private let hexField = NSTextField()
    private let cssLabel = NSTextField(labelWithString: "")
    private let hslLabel = NSTextField(labelWithString: "")
    private var rgb = RGB(red: 255, green: 96, blue: 32)
    private var hue: CGFloat = 0

    init() {
        super.init(frame: .zero)
        map.onChange = { [weak self] saturation, value in self?.pickMap(saturation, value) }
        hueBar.onChange = { [weak self] in self?.pickHue($0) }
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        var rows: [[NSView]] = []
        for (index, title) in ["R", "G", "B"].enumerated() {
            sliders[index].minValue = 0
            sliders[index].maxValue = 255
            sliders[index].target = self
            sliders[index].action = #selector(sliderMoved)
            sliders[index].widthAnchor.constraint(equalToConstant: 170).isActive = true
            fields[index].delegate = self
            fields[index].widthAnchor.constraint(equalToConstant: 44).isActive = true
            rows.append([NSTextField(labelWithString: title), sliders[index], fields[index]])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        hexField.delegate = self
        hexField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let hexRow = NSStackView(views: [NSTextField(labelWithString: "16進数"), hexField, copyButton(0)])
        let cssRow = NSStackView(views: [cssLabel, copyButton(1)])
        let hslRow = NSStackView(views: [hslLabel, copyButton(2)])
        [cssLabel, hslLabel].forEach {
            $0.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            $0.isSelectable = true
        }
        let values = NSStackView(views: [hexRow, cssRow, hslRow])
        values.orientation = .vertical
        values.alignment = .leading
        values.spacing = 6
        [map, hueBar, swatch, grid, values].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            map.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            map.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            map.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            map.widthAnchor.constraint(equalToConstant: 170),
            hueBar.leadingAnchor.constraint(equalTo: map.trailingAnchor, constant: 8),
            hueBar.topAnchor.constraint(equalTo: map.topAnchor),
            hueBar.bottomAnchor.constraint(equalTo: map.bottomAnchor),
            hueBar.widthAnchor.constraint(equalToConstant: 16),
            swatch.leadingAnchor.constraint(equalTo: hueBar.trailingAnchor, constant: 12),
            swatch.topAnchor.constraint(equalTo: map.topAnchor),
            swatch.bottomAnchor.constraint(equalTo: map.bottomAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 72),
            grid.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 14),
            grid.centerYAnchor.constraint(equalTo: centerYAnchor),
            values.leadingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 18),
            values.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        hue = rgb.hsv.hue
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func copyButton(_ tag: Int) -> NSButton {
        let button = FeedView.barButton(symbol: "doc.on.doc", tip: "コピー", target: self, action: #selector(copyClicked(_:)))
        button.tag = tag
        return button
    }

    private func refresh() {
        let values = [rgb.red, rgb.green, rgb.blue]
        let hsv = rgb.hsv
        for index in 0..<3 {
            sliders[index].integerValue = values[index]
            if fields[index].currentEditor() == nil { fields[index].integerValue = values[index] }
        }
        if hexField.currentEditor() == nil { hexField.stringValue = rgb.hex }
        cssLabel.stringValue = rgb.css
        hslLabel.stringValue = rgb.hsl
        swatch.layer?.backgroundColor = rgb.color.cgColor
        map.hue = hue
        map.saturation = hsv.saturation
        map.value = hsv.value
        hueBar.hue = hue
    }

    private func pickMap(_ saturation: CGFloat, _ value: CGFloat) {
        rgb = RGB(hue: hue, saturation: saturation, value: value)
        refresh()
        map.saturation = saturation
        map.value = value
    }

    private func pickHue(_ value: CGFloat) {
        hue = value
        let hsv = rgb.hsv
        rgb = RGB(hue: value, saturation: hsv.saturation, value: hsv.value)
        refresh()
    }

    private func setRGB(_ next: RGB) {
        rgb = next
        if next.hsv.saturation > 0 { hue = next.hsv.hue }
        refresh()
    }

    @objc private func sliderMoved() {
        setRGB(RGB(red: sliders[0].integerValue, green: sliders[1].integerValue, blue: sliders[2].integerValue))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === hexField {
            if let next = RGB(hex: field.stringValue) { setRGB(next) }
        } else {
            let values = fields.map { min(max($0.integerValue, 0), 255) }
            setRGB(RGB(red: values[0], green: values[1], blue: values[2]))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { DispatchQueue.main.async { [weak self] in self?.refresh() } }

    @objc private func copyClicked(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([rgb.hex, rgb.css, rgb.hsl][sender.tag], forType: .string)
        Toasts.hint("コピーしました", under: sender)
    }
}

final class ColorPreviewAddon: NSObject, WindowAddon {
    private static let height: CGFloat = 170
    private weak var editor: EditorWindowController?
    private let button = NSButton()
    private lazy var feed: FeedView = {
        let made = FeedView(title: "色", content: ColorPreviewView())
        made.onRemove = { [weak self] in self?.toggle() }
        return made
    }()

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        button.image = EditorWindowController.cloudImage("paintbrush.pointed")
        button.isBordered = false
        button.toolTip = "色"
        button.target = self
        button.action = #selector(toggle)
        editor.addTopButton(button)
    }

    @objc private func toggle() { editor?.toggleTopFeed(feed, height: Self.height) }

    func detach() {
        editor?.removeTopFeed(feed)
        button.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(ColorPreviewPlugin()) }
