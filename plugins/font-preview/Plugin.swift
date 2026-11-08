import AppKit
import CoreText
@testable import FlareStackIDE

final class FontPreviewPlugin: NativePlugin, FileViewing {
    static let pluginID = "font-preview"
    let id = FontPreviewPlugin.pluginID

    func viewer(for url: URL) -> EditorExtension? {
        guard PluginStore.installed(id)?.fileExtensions.contains(url.pathExtension.lowercased()) == true,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty
        else { return nil }
        return FontPreview(file: url, descriptors: descriptors)
    }
}

enum FontFacts {
    static func attribute(_ descriptor: CTFontDescriptor, _ key: CFString) -> String? {
        CTFontDescriptorCopyAttribute(descriptor, key) as? String
    }

    static func name(_ font: CTFont, _ key: CFString) -> String? {
        (CTFontCopyName(font, key) as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func title(_ descriptor: CTFontDescriptor) -> String {
        attribute(descriptor, kCTFontDisplayNameAttribute) ?? attribute(descriptor, kCTFontNameAttribute) ?? "?"
    }

    static func covers(_ font: CTFont, _ text: String) -> Bool {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}

final class FontCanvas: NSView {
    var font: CTFont? { didSet { relayout() } }
    var sample = "" { didSet { relayout() } }
    var sampleSize: CGFloat = 36 { didSet { relayout() } }
    private var blocks: [(y: CGFloat, height: CGFloat, draw: (CGFloat) -> Void)] = []
    private var gridTop: CGFloat = 0
    private let cell = NSSize(width: 64, height: 72)
    private let margin: CGFloat = 20

    override var isFlipped: Bool { true }

    private var columns: Int { max(Int((bounds.width - margin * 2) / cell.width), 1) }
    private var glyphCount: Int { font.map { CTFontGetGlyphCount($0) } ?? 0 }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    func relayout() {
        guard let font else { return }
        blocks = []
        let width = max((enclosingScrollView?.contentSize.width ?? bounds.width) - margin * 2, 100)
        var y: CGFloat = margin
        let fg = Settings.foreground
        let dim = fg.withAlphaComponent(0.5)
        func add(_ text: NSAttributedString, gap: CGFloat = 8, wrap: Bool = true) {
            let height = wrap ? ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                : ceil(text.size().height)
            let top = y
            blocks.append((top, height, { _ in
                if wrap {
                    text.draw(with: NSRect(x: self.margin, y: top, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
                } else {
                    text.draw(with: NSRect(x: self.margin, y: top, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }))
            y += height + gap
        }
        func label(_ text: String, size: CGFloat = 11, color: NSColor? = nil, weight: NSFont.Weight = .regular) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? dim])
        }
        func styled(_ text: String, size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: CTFontCreateCopyWithAttributes(font, size, nil, nil), .foregroundColor: fg])
        }
        add(styled(FontFacts.name(font, kCTFontFullNameKey) ?? FontFacts.name(font, kCTFontFamilyNameKey) ?? "", size: 40), gap: 6)
        let facts = [
            FontFacts.name(font, kCTFontFamilyNameKey).map { "ファミリー: \($0)" },
            FontFacts.name(font, kCTFontStyleNameKey).map { "スタイル: \($0)" },
            FontFacts.name(font, kCTFontPostScriptNameKey).map { "PostScript 名: \($0)" },
            FontFacts.name(font, kCTFontVersionNameKey).map { "版: \($0)" },
            FontFacts.name(font, kCTFontDesignerNameKey).map { "デザイナー: \($0)" },
            "グリフ数: \(glyphCount)",
        ].compactMap { $0 }
        add(label(facts.joined(separator: "　·　"), color: fg.withAlphaComponent(0.7)), gap: 4)
        if let copyright = FontFacts.name(font, kCTFontCopyrightNameKey) { add(label(copyright, size: 10), gap: 18) } else { y += 14 }
        add(label("見本", size: 12, color: fg, weight: .semibold))
        let sizes = Set([12, 18, 24, CGFloat(Int(sampleSize)), 48, 72]).sorted()
        for size in sizes {
            add(label("\(Int(size)) pt", size: 10), gap: 2)
            add(styled(sample, size: size), gap: 12, wrap: false)
        }
        y += 8
        add(label("文字", size: 12, color: fg, weight: .semibold))
        var sets = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"]
        if FontFacts.covers(font, "あア漢") { sets.append("あいうえお かきくけこ アイウエオ 日本語の漢字と仮名") }
        if FontFacts.covers(font, "ÀÉÎÕÜßÇ") { sets.append("ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝßàáâãäåæçèéêëñòóôõöøùúûüÿ") }
        for set in sets where FontFacts.covers(font, set.replacingOccurrences(of: " ", with: "")) || set.allSatisfy(\.isASCII) {
            add(styled(set, size: max(sampleSize * 0.6, 16)), gap: 10)
        }
        y += 8
        add(label("グリフ（\(glyphCount)）", size: 12, color: fg, weight: .semibold))
        gridTop = y
        let rows = (glyphCount + columns - 1) / columns
        let height = gridTop + CGFloat(rows) * cell.height + margin
        let target = NSSize(width: enclosingScrollView?.contentSize.width ?? frame.width, height: max(height, enclosingScrollView?.contentSize.height ?? 0))
        if frame.size != target { super.setFrameSize(target) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Settings.background.setFill()
        dirtyRect.fill()
        for block in blocks where block.y < dirtyRect.maxY && block.y + block.height > dirtyRect.minY { block.draw(block.y) }
        drawGrid(dirtyRect)
    }

    private func drawGrid(_ dirtyRect: NSRect) {
        guard let font, let context = NSGraphicsContext.current?.cgContext, glyphCount > 0 else { return }
        let glyphFont = CTFontCreateCopyWithAttributes(font, 30, nil, nil)
        let first = max(Int((dirtyRect.minY - gridTop) / cell.height), 0)
        let last = min(Int((dirtyRect.maxY - gridTop) / cell.height) + 1, (glyphCount + columns - 1) / columns)
        guard first < last else { return }
        let fg = Settings.foreground
        let line = fg.withAlphaComponent(0.12)
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                               .foregroundColor: fg.withAlphaComponent(0.45)]
        for row in first..<last {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < glyphCount else { break }
                let rect = NSRect(x: margin + CGFloat(column) * cell.width, y: gridTop + CGFloat(row) * cell.height, width: cell.width, height: cell.height)
                line.setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                var glyph = CGGlyph(index)
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(glyphFont, .horizontal, &glyph, &advance, 1)
                context.saveGState()
                context.translateBy(x: rect.midX - advance.width / 2, y: rect.minY + 44)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                context.setFillColor(fg.cgColor)
                var origin = CGPoint.zero
                CTFontDrawGlyphs(glyphFont, &glyph, &origin, 1, context)
                context.restoreGState()
                let number = String(index) as NSString
                let size = number.size(withAttributes: numberAttributes)
                number.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height - 4), withAttributes: numberAttributes)
            }
        }
    }
}

final class FontPreview: NSObject, EditorExtension, NSTextFieldDelegate {
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let descriptors: [CTFontDescriptor]
    private let scroll = NSScrollView()
    private let canvas = FontCanvas()
    private let facePopup = NSPopUpButton()
    private let sizeSlider = NSSlider(value: 36, minValue: 8, maxValue: 160, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "36 pt")
    private let sampleField = NSTextField()
    private let install = NSButton()
    private let file: URL
    var body: NSView { scroll }

    private static var defaultSample: String {
        PluginStore.setting(FontPreviewPlugin.pluginID, "sample") ?? "The quick brown fox jumps over the lazy dog. 0123456789"
    }

    init(file: URL, descriptors: [CTFontDescriptor]) {
        self.file = file
        self.descriptors = descriptors
        super.init()
        buildBar()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsFrameChangedNotifications = true
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.sample = Self.defaultSample
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        selectFace(0)
        applySettings()
    }

    private func buildBar() {
        facePopup.controlSize = .small
        facePopup.font = .systemFont(ofSize: 11)
        facePopup.addItems(withTitles: descriptors.map(FontFacts.title))
        facePopup.isHidden = descriptors.count < 2
        facePopup.target = self
        facePopup.action = #selector(faceChanged)
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.isContinuous = true
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sampleField.placeholderString = "見本の文字を入力"
        sampleField.controlSize = .small
        sampleField.font = .systemFont(ofSize: 11)
        sampleField.stringValue = Self.defaultSample
        sampleField.delegate = self
        sampleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        install.title = "Font Book で開く"
        install.bezelStyle = .rounded
        install.controlSize = .small
        install.font = .systemFont(ofSize: 11)
        install.target = self
        install.action = #selector(openFontBook)
        let stack = NSStackView(views: [facePopup, sampleField, sizeSlider, sizeLabel, install])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 120),
            sizeLabel.widthAnchor.constraint(equalToConstant: 46),
            facePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func selectFace(_ index: Int) {
        guard descriptors.indices.contains(index) else { return }
        canvas.font = CTFontCreateWithFontDescriptor(descriptors[index], 36, nil)
    }

    @objc private func faceChanged() { selectFace(facePopup.indexOfSelectedItem) }

    @objc private func sizeChanged() {
        let size = CGFloat(sizeSlider.doubleValue.rounded())
        sizeLabel.stringValue = "\(Int(size)) pt"
        canvas.sampleSize = size
    }

    func controlTextDidChange(_ obj: Notification) {
        canvas.sample = sampleField.stringValue.isEmpty ? Self.defaultSample : sampleField.stringValue
    }

    @objc private func openFontBook() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FontBook") else { return NSSound.beep() }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func resized() { canvas.relayout() }

    @objc private func settingsChanged() { applySettings() }

    func update(text: String) {}

    func applySettings() {
        scroll.backgroundColor = Settings.background
        canvas.relayout()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(FontPreviewPlugin()) }
