import AppKit
@testable import FlareStackIDE

final class LineNumberRuler: NSRulerView {
    static let pluginID = "lines"
    private weak var textView: NSTextView?
    private var starts: [Int] = [0]
    private var startsLength = -1

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

    static var textColor: NSColor { PluginStore.color(pluginID, "textColor") ?? .secondaryLabelColor }

    static var backgroundColor: NSColor { PluginStore.color(pluginID, "background") ?? Settings.background }

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

    private var numberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(Settings.fontSize - 2, 9), weight: .regular)
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
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let starts = lineStarts()
        let digits = max(String(starts.count).count, 4)
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: Self.textColor]
        let width = ceil(("8" as NSString).size(withAttributes: attrs).width * CGFloat(digits)) + 16
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
        let lineHeight = Settings.paragraphStyle.maximumLineHeight
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
            if !(verticalRulerView is LineNumberRuler) { verticalRulerView = LineNumberRuler(textView: textView, scroll: self) }
            textView.clipsToBounds = true
            clipsToBounds = true
            hasVerticalRuler = true
            rulersVisible = true
            verticalRulerView?.needsDisplay = true
        } else {
            rulersVisible = false
            hasVerticalRuler = false
        }
    }
}
