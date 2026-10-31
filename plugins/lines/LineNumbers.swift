import AppKit
@testable import FlareStackIDE

final class LineNumberRuler: NSRulerView {
    static let pluginID = "lines"
    private weak var textView: NSTextView?
    private var starts: [Int] = [0]
    private var startsLength = -1
    var keepVisible = true

    init(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: .settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil, keepVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keepVisible, let scroll = self.scrollView, scroll.verticalRulerView === self, !scroll.rulersVisible else { return }
            scroll.rulersVisible = true
            scroll.tile()
        }
    }

    static var textColor: NSColor { PluginStore.color(pluginID, "textColor") ?? .secondaryLabelColor }

    static var backgroundColor: NSColor { PluginStore.color(pluginID, "background") ?? Settings.background }

    static var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: max(Settings.fontSize - 2, 9), weight: .regular) }

    static var attributes: [NSAttributedString.Key: Any] { [.font: numberFont, .foregroundColor: textColor] }

    static func width(lines: Int) -> CGFloat {
        if let fixed = PluginStore.setting(pluginID, "width").flatMap(Double.init) { return CGFloat(fixed) }
        let digits = max(String(lines).count, 4)
        return ceil(("8" as NSString).size(withAttributes: attributes).width * CGFloat(digits)) + 16
    }

    static func drawSeparator(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    @objc func textChanged() {
        startsLength = -1
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    private func lineStarts() -> [Int] {
        guard let text = textView?.string as NSString? else { return [0] }
        if startsLength == text.length { return starts }
        var result = [0]
        var i = 0
        while i < text.length {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: text.length - i))
            if r.location == NSNotFound { break }
            result.append(r.location + 1)
            i = r.location + 1
        }
        starts = result
        startsLength = text.length
        return result
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.backgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        Self.backgroundColor.setFill()
        bounds.fill()
        Self.drawSeparator(in: bounds)

        let starts = lineStarts()
        let attrs = Self.attributes
        let width = Self.width(lines: starts.count)
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
            return
        }

        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
        }
        let lineHeight = Settings.lineHeight
        var line = lo
        while line < starts.count, starts[line] <= NSMaxRange(chars) {
            let start = starts[line]
            let fragment: NSRect
            if start < length {
                fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            } else if layout.extraLineFragmentTextContainer != nil {
                fragment = layout.extraLineFragmentRect
            } else {
                break
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = offset + fragment.minY + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
            line += 1
        }
    }
}

extension NSScrollView {
    func setLineNumbers(_ on: Bool, textView: NSTextView) {
        if on {
            if (verticalRulerView as? LineNumberRuler)?.clientView !== textView {
                verticalRulerView = LineNumberRuler(textView: textView, scroll: self)
            }
            (verticalRulerView as? LineNumberRuler)?.keepVisible = true
            textView.clipsToBounds = true
            clipsToBounds = true
            hasVerticalRuler = true
            rulersVisible = true
            tile()
            verticalRulerView?.needsDisplay = true
        } else {
            (verticalRulerView as? LineNumberRuler)?.keepVisible = false
            rulersVisible = false
            hasVerticalRuler = false
        }
    }
}

final class LinesPreview: NSView {
    private let sample = ["import AppKit", "", "func greet(_ name: String) {", "    print(\"Hello, \\(name)\")", "}"]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 320).isActive = true
        heightAnchor.constraint(equalToConstant: 110).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: .settingsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Settings.background.setFill()
        bounds.fill()
        let width = min(LineNumberRuler.width(lines: sample.count), bounds.width)
        let ruler = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        LineNumberRuler.backgroundColor.setFill()
        ruler.fill()
        LineNumberRuler.drawSeparator(in: ruler)
        let numbers = LineNumberRuler.attributes
        let code: [NSAttributedString.Key: Any] = [.font: Settings.font, .foregroundColor: Settings.foreground]
        let height = max(Settings.lineHeight, 14)
        for (i, text) in sample.enumerated() {
            let y = 8 + CGFloat(i) * height
            let label = "\(i + 1)" as NSString
            let size = label.size(withAttributes: numbers)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: ruler).addClip()
            label.draw(at: NSPoint(x: width - size.width - 8, y: y + (height - size.height) / 2), withAttributes: numbers)
            NSGraphicsContext.restoreGraphicsState()
            let line = text as NSString
            line.draw(at: NSPoint(x: width + 8, y: y + (height - line.size(withAttributes: code).height) / 2), withAttributes: code)
        }
    }
}
